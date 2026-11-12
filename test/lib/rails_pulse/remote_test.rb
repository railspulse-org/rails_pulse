require "test_helper"
require "rake"

module RailsPulse
  # What remote mode sends for each thing it collects, and what it leaves
  # alone: no Rails Pulse table is read or written, nothing is raised to the
  # host, and the dashboard, the jobs and the schema check stand down.
  class RemoteTest < ActiveSupport::TestCase
    include ApiClientTestHelpers
    include RemoteTestHelpers

    class FakeJob
      attr_reader :job_id, :queue_name, :executions

      def initialize(job_id: SecureRandom.uuid, queue_name: "reports", executions: 1)
        @job_id = job_id
        @queue_name = queue_name
        @executions = executions
      end

      def self.name
        "RemoteFakeJob"
      end

      def arguments
        [ 7 ]
      end

      def enqueued_at
        Time.current
      end
    end

    setup do
      RailsPulse::Current.reset
      RailsPulse::SchemaCheck.reset!
    end

    teardown do
      RailsPulse::Current.reset
      RailsPulse::SchemaCheck.reset!
    end

    # Job Run Tests

    test "a job run is sent with its outcome and operations, and nothing is written here" do
      posts = capture_remote_posts

      with_remote_mode do
        assert_no_difference -> { RailsPulse::JobRun.count + RailsPulse::Job.count + RailsPulse::Operation.count } do
          RailsPulse::JobRunCollector.track(FakeJob.new(job_id: "run-ok")) do
            ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM reports WHERE id = 7") { sleep(0.001) }
          end
        end
      end

      run = remote_items(posts).sole

      assert_equal "job_run", run["type"]
      assert_equal "RemoteFakeJob", run["job_class"]
      assert_equal "reports", run["queue_name"]
      assert_equal "run-ok", run["run_id"]
      assert_equal "running", run["initial_status"]
      assert_equal "success", run["status"]
      assert_operator run["duration"], :>, 0
      assert_equal 1, run["attempts"]
      assert_equal [ "sql" ], run["operations"].map { |op| op["operation_type"] }
      assert_equal "SELECT * FROM reports WHERE id = 7", run["operations"].first["actual_sql"]
    end

    test "a failed job sends its run and its exception, and the job's error still reaches the host" do
      posts = capture_remote_posts

      with_remote_mode do
        error = assert_raises(ArgumentError) do
          RailsPulse::JobRunCollector.track(FakeJob.new(job_id: "run-failed")) { raise ArgumentError, "bad input token=abc123" }
        end

        assert_equal "bad input token=abc123", error.message
      end

      items = remote_items(posts).index_by { |item| item["type"] }
      run = items.fetch("job_run")
      exception = items.fetch("exception")

      assert_equal "failed", run["status"]
      assert_equal "ArgumentError", run["error_class"]
      assert_equal "bad input token=[FILTERED]", run["error_message"]
      assert_equal "ArgumentError", exception["exception_class"]
      assert_equal "bad input token=[FILTERED]", exception["message"]
      assert_equal Rails.env.to_s, exception["environment"]
    end

    # Exception Tests

    test "an exception is sent with this host's redaction applied and its parameters filtered" do
      posts = capture_remote_posts
      exception = RuntimeError.new("lookup failed")
      exception.set_backtrace([ "#{Rails.root}/app/models/user.rb:10:in 'find_by_token'" ])

      with_remote_mode do
        assert_no_difference -> { RailsPulse::ExceptionGroup.count } do
          RailsPulse::ExceptionCaptureService.capture(exception, request_url: "/users", request_method: "GET",
                                                                 request_params: { "token" => "s3cret", "page" => "2" })
        end
      end

      item = remote_items(posts).sole

      assert_equal "app/models/user.rb#find_by_token", item["location"]
      assert_equal({ "token" => "[FILTERED]", "page" => "2" }, item["request_params"])
      assert_equal [ { "file" => "#{Rails.root}/app/models/user.rb", "line" => 10, "method" => "find_by_token" } ], item["backtrace"]
      assert_nil item["deploy_sha"], "the central stamps the revision it knows"
    end

    # Heartbeat Tests

    test "the writer heartbeat is sent with this process's identity and the sender's drops" do
      posts = capture_remote_posts

      with_remote_mode do
        RailsPulse::Remote.sender.stubs(:take_dropped).returns(3)
        RailsPulse::Remote.sender.stubs(:dropped_total).returns(5)

        assert RailsPulse::Tracker.record_heartbeat(queue_size: 1000, queue_depth: 2, dropped: 1, dropped_total: 4)
      end

      heartbeat = remote_items(posts).sole

      assert_equal "writer_heartbeat", heartbeat["type"]
      assert_equal Socket.gethostname, heartbeat["hostname"]
      assert_equal Process.pid, heartbeat["pid"]
      assert_equal 2, heartbeat["queue_depth"]
      assert_equal 4, heartbeat["dropped"]
      assert_equal 9, heartbeat["dropped_total"]
      assert_predicate heartbeat["sampled_at"], :present?
    end

    # Queue Tests

    test "a full queue drops the newest item at once instead of blocking the caller" do
      release = Queue.new
      posting = Queue.new
      posts = 0
      stub_http_response(202, { accepted: 1 }.to_json) do
        posts += 1
        next unless posts == 1

        posting << true
        release.pop
      end
      original_size = RailsPulse.configuration.async_queue_size
      RailsPulse.configuration.async_queue_size = 1

      with_remote_mode(async: true) do
        RailsPulse::Remote.track(:request, request_data)
        posting.pop # the writer is now stuck posting the first item

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        3.times { RailsPulse::Remote.track(:request, request_data) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :<, 0.5
        assert_equal 2, RailsPulse::Tracker.stats[:dropped]
        release << true
      end
    ensure
      RailsPulse.configuration.async_queue_size = original_size
    end

    # Standing Down Tests

    test "the schema check is off and touches no database" do
      with_remote_mode do
        RailsPulse::ApplicationRecord.expects(:connection).never

        assert_empty RailsPulse::SchemaCheck.missing
        assert RailsPulse::SchemaCheck.tracking_allowed?
      end
    end

    test "Rails Pulse jobs do nothing, since the central summarizes and cleans up" do
      with_remote_mode do
        RailsPulse::SummaryService.expects(:new).never
        RailsPulse::CleanupService.expects(:perform).never

        RailsPulse::SummaryJob.perform_now
        RailsPulse::CleanupJob.perform_now
      end
    end

    test "rails_pulse:status reports where the data goes without touching tables" do
      output = StringIO.new

      with_remote_mode do
        RailsPulse::ApplicationRecord.expects(:connection).never

        assert RailsPulse::Tasks::StatusReporter.report(output: output)
      end

      assert_includes output.string, "remote, sending to #{RemoteTestHelpers::REMOTE_URL}"
    end

    # Deployment Tests

    test "rails_pulse:record_deployment sends the deployment to the central" do
      posts = capture_remote_posts(body: { accepted: 1, rejected: 0, errors: [] }.to_json)

      output = with_remote_mode { run_task("rails_pulse:record_deployment", "abc123", metadata: '{"by":"ci"}') }

      # Other task tests in this process may have loaded the rake tasks too,
      # which repeats each task's actions; every post is the same deployment.
      items = remote_items(posts)
      deployment = items.first

      assert_equal [ "deployment" ], items.map { |item| item["type"] }.uniq

      assert_equal({ "type" => "deployment", "action" => "record", "revision" => "abc123", "metadata" => { "by" => "ci" } },
                   deployment.except("started_at"))
      assert_predicate deployment["started_at"], :present?
      assert_includes output, "Deployment start sent to the central: abc123"
    end

    test "rails_pulse:finish_deployment fails when the central rejects it" do
      capture_remote_posts(body: { accepted: 0, rejected: 1, errors: [ "deployment: no deployment recorded for revision abc123" ] }.to_json)

      error = assert_raises(SystemExit) do
        with_remote_mode { run_task("rails_pulse:finish_deployment", "abc123") }
      end

      assert_not error.success?
    end

    test "a deployment task fails when the central cannot be reached" do
      stub_http_failure(Errno::ECONNREFUSED)

      assert_raises(SystemExit) do
        with_remote_mode { run_task("rails_pulse:record_deployment", "abc123") }
      end
    end

    private

    def request_data
      { method: "GET", path: "/queued", duration: 5.0, status: 200, controller_action: "pages#show", occurred_at: Time.current,
        is_error: false, request_uuid: SecureRandom.uuid, response_size_bytes: 10, operations: [] }
    end

    def run_task(name, revision, metadata: nil)
      Rails.application.load_tasks unless Rake::Task.task_defined?(name)
      Rake::Task[name].reenable
      ENV["RAILS_PULSE_DEPLOYMENT_METADATA"] = metadata
      output = StringIO.new
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = output
      $stderr = output
      Rake::Task[name].invoke(revision)
      output.string
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
      ENV.delete("RAILS_PULSE_DEPLOYMENT_METADATA")
    end
  end
end
