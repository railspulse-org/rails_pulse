require "test_helper"

module RailsPulse
  module Central
    # The contract both ways in one process: what remote mode sends, decoded
    # and recorded by Ingest into this suite's database, comes out as the
    # rows local tracking would have written. The sharded central, its
    # endpoint and its dashboards are covered by test/central.
    class IngestTest < ActiveSupport::TestCase
      include ApiClientTestHelpers
      include RemoteTestHelpers

      class FakeJob
        attr_reader :job_id, :queue_name, :executions

        def initialize(job_id:)
          @job_id = job_id
          @queue_name = "mailers"
          @executions = 1
        end

        def self.name
          "IngestRoundTripJob"
        end

        def arguments
          []
        end

        def enqueued_at
          Time.current
        end
      end

      setup do
        RailsPulse::Current.reset
        RailsPulse::Tracker.reset_rollups!
        RailsPulse::ExceptionCaptureService.reset_deploy_sha_cache!
      end

      teardown do
        RailsPulse::Current.reset
        RailsPulse::Tracker.reset_rollups!
      end

      # Round Trip Tests

      test "a request sent by remote mode is recorded as the writer records one" do
        payloads = sent_by_remote_mode do
          RailsPulse::Tracker.track_request(request_data(path: "/round-trip"))
        end

        result = ingest(payloads)

        assert_equal 1, result.accepted
        request = RailsPulse::Request.joins(:route).find_by!(rails_pulse_routes: { path: "/round-trip" })

        assert_equal "posts#index", request.controller_action
        assert_equal [ "SELECT * FROM posts WHERE id = ?" ], request.operations.map { |op| op.query.normalized_sql }
      end

      test "a job run and the exception it raised arrive as the job and its failure" do
        payloads = sent_by_remote_mode do
          assert_raises(KeyError) do
            RailsPulse::JobRunCollector.track(FakeJob.new(job_id: "round-trip-run")) do
              ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM mails WHERE id = 3") { sleep(0.001) }
              raise KeyError, "key not found: :recipient"
            end
          end
        end

        result = ingest(payloads)

        assert_equal 2, result.accepted
        run = RailsPulse::JobRun.find_by!(run_id: "round-trip-run")

        assert_equal "IngestRoundTripJob", run.job.name
        assert_equal "failed", run.status
        assert_equal "KeyError", run.error_class
        assert_equal 1, run.job.failures_count
        assert_equal [ "sql" ], run.operations.pluck(:operation_type)
        assert_equal "KeyError", RailsPulse::ExceptionOccurrence.order(:created_at).last.exception_class
      end

      test "a heartbeat and a deployment arrive as their events and rows" do
        payloads = sent_by_remote_mode do
          RailsPulse::Tracker.record_heartbeat(queue_size: 1000, queue_depth: 0, dropped: 0, dropped_total: 0)
          RailsPulse::Remote.track(:deployment, action: "record", revision: "rt-1", started_at: Time.current, metadata: nil)
        end

        ingest(payloads)

        assert RailsPulse::WriterHeartbeat.events.exists?(subject: "#{Socket.gethostname}:#{Process.pid}")
        assert RailsPulse::Deployment.exists?(revision: "rt-1")
      end

      # Edge Cases

      test "a batch already recorded is acknowledged without recording it again" do
        payloads = sent_by_remote_mode { RailsPulse::Tracker.track_request(request_data(path: "/once")) }

        ingest(payloads)
        repeat = Ingest.new(payloads.first).perform

        assert repeat.duplicate
        assert_equal 1, RailsPulse::Request.joins(:route).where(rails_pulse_routes: { path: "/once" }).count
      end

      test "an envelope that does not match the contract raises Invalid" do
        assert_raises(Ingest::Invalid) { Ingest.new([]).perform }
        assert_raises(Ingest::Invalid) { Ingest.new({ "version" => 2, "batch_id" => "x", "items" => [] }).perform }
        assert_raises(Ingest::Invalid) { Ingest.new({ "version" => 1, "batch_id" => "x", "items" => "all" }).perform }
      end

      test "an item with a field of the wrong type is rejected with its name" do
        result = Ingest.new({ "version" => 1, "batch_id" => SecureRandom.uuid, "items" => [
          { "type" => "writer_heartbeat", "hostname" => "web-1", "pid" => "12", "queue_size" => 1, "queue_depth" => 0,
            "dropped" => 0, "dropped_total" => 0, "sampled_at" => Time.current.utc.iso8601(6) }
        ] }).perform

        assert_equal 1, result.rejected
        assert_equal [ "items[0] (writer_heartbeat): pid must be a whole number" ], result.errors
      end

      test "a time that is not ISO 8601 is rejected" do
        result = Ingest.new({ "version" => 1, "batch_id" => SecureRandom.uuid, "items" => [
          { "type" => "deployment", "action" => "record", "revision" => "x", "started_at" => "yesterday" }
        ] }).perform

        assert_equal [ "items[0] (deployment): started_at must be an ISO 8601 time" ], result.errors
      end

      private

      # The payloads remote mode posts while the block runs, decoded.
      def sent_by_remote_mode(&block)
        posts = capture_remote_posts
        with_remote_mode(&block)
        posts.map { |post| JSON.parse(Zlib.gunzip(post[:request].body)) }
      end

      def ingest(payloads)
        results = payloads.map { |payload| Ingest.new(payload).perform }
        Ingest::Result.new(accepted: results.sum(&:accepted), rejected: results.sum(&:rejected), errors: results.flat_map(&:errors))
      end

      def request_data(path:)
        {
          method: "GET", path: path, duration: 42.0, status: 200, controller_action: "posts#index", occurred_at: Time.current,
          is_error: false, request_uuid: SecureRandom.uuid, response_size_bytes: 100,
          operations: [ { request_id: SecureRandom.uuid, job_run_id: nil, operation_type: "sql", label: nil,
                          actual_sql: "SELECT * FROM posts WHERE id = 1", duration: 2.0, codebase_location: "app/models/post.rb",
                          start_time: Time.current.to_f, occurred_at: Time.current, row_count: 1 } ]
        }
      end
    end
  end
end
