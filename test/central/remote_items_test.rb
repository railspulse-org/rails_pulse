require_relative "test_helper"

module RailsPulse
  # Job runs, exceptions, writer heartbeats and deployments arriving from
  # remote applications, recorded with the code that records them locally.
  class CentralRemoteItemsTest < CentralIntegrationTest
    # Job Run Tests

    test "a job run is recorded with its job, its outcome and its operations" do
      post_batch([ job_run_item(run_id: "run-1", status: "success", duration: 250.0) ])

      assert_response 202
      in_application(:alpha) do
        job = RailsPulse::Job.find_by!(name: "ReportJob")
        run = job.runs.sole

        assert_equal "reports", job.queue_name
        assert_equal "success", run.status
        assert_in_delta 250.0, run.duration
        assert_equal 1, job.reload.runs_count
        assert_in_delta 250.0, job.avg_duration
        assert_equal [ "sql" ], run.operations.pluck(:operation_type)
      end
      in_application(:beta) { assert_equal 0, RailsPulse::JobRun.count }
    end

    test "a failed job run counts as a failure of its job" do
      post_batch([ job_run_item(run_id: "run-2", status: "failed", duration: 10.0,
                                error_class: "ReportJob::Timeout", error_message: "took too long") ])

      in_application(:alpha) do
        run = RailsPulse::JobRun.find_by!(run_id: "run-2")

        assert_equal "failed", run.status
        assert_equal "ReportJob::Timeout", run.error_class
        assert_equal 1, run.job.failures_count
      end
    end

    test "a retried run with the same id updates the run and counts the attempt" do
      post_batch([ job_run_item(run_id: "run-3", status: "failed", duration: 10.0) ])
      post_batch([ job_run_item(run_id: "run-3", status: "success", duration: 12.0, attempts: 2) ])

      in_application(:alpha) do
        run = RailsPulse::JobRun.find_by!(run_id: "run-3")

        assert_equal "success", run.status
        assert_equal 2, run.attempts
        assert_equal 1, run.job.failures_count
      end
    end

    test "a job run with a status outside the contract is rejected" do
      post_batch([ job_run_item(run_id: "run-4", status: "exploded") ])

      assert_equal 1, response.parsed_body["rejected"]
      assert_match(/status must be one of/, response.parsed_body["errors"].first)
    end

    # Exception Tests

    test "an exception is grouped by its class and location and recorded with its occurrence" do
      post_batch([ exception_item, exception_item(message: "second time") ])

      in_application(:alpha) do
        group = RailsPulse::ExceptionGroup.sole

        assert_equal "PaymentError", group.exception_class
        assert_equal "app/services/payment.rb#charge", group.location
        assert_equal Digest::SHA256.hexdigest("PaymentError:app/services/payment.rb#charge"), group.fingerprint
        assert_equal 2, group.occurrence_count
        assert_equal 2, group.occurrences.count
        assert_equal "/charges", group.occurrences.first.request_url
        assert_equal({ "amount" => "[FILTERED]" }, group.occurrences.first.request_params)
        assert_equal "app/services/payment.rb", group.occurrences.first.backtrace.first["file"]
      end
      in_application(:beta) { assert_equal 0, RailsPulse::ExceptionGroup.count }
    end

    test "an exception is stamped with its application's latest deployment" do
      in_application(:alpha) { RailsPulse::Deployment.create!(revision: "alpha-rev", started_at: 1.hour.ago) }
      in_application(:beta) { RailsPulse::Deployment.create!(revision: "beta-rev", started_at: 1.minute.ago) }

      post_batch([ exception_item ], token: ALPHA_TOKEN)
      post_batch([ exception_item ], token: BETA_TOKEN)

      in_application(:alpha) { assert_equal "alpha-rev", RailsPulse::ExceptionOccurrence.sole.deploy_sha }
      in_application(:beta) { assert_equal "beta-rev", RailsPulse::ExceptionOccurrence.sole.deploy_sha }
    end

    test "an ignored group keeps counting without storing occurrences" do
      post_batch([ exception_item ])
      in_application(:alpha) { RailsPulse::ExceptionGroup.sole.update!(status: "ignored") }

      post_batch([ exception_item ])

      assert_equal 1, response.parsed_body["accepted"]
      in_application(:alpha) do
        assert_equal 2, RailsPulse::ExceptionGroup.sole.occurrence_count
        assert_equal 1, RailsPulse::ExceptionOccurrence.count
      end
    end

    # Heartbeat Tests

    test "a writer heartbeat is recorded for the remote process it describes" do
      post_batch([ item("writer_heartbeat", { hostname: "web-1", pid: 42, host_label: "shop-web", queue_size: 1000,
                                              queue_depth: 3, dropped: 7, dropped_total: 9, sampled_at: Time.current }) ])

      in_application(:alpha) do
        event = RailsPulse::WriterHeartbeat.events.sole

        assert_equal "web-1:42", event.subject
        assert_in_delta 7, event.value
        assert_equal "shop-web", event.metadata_hash["host_label"]
        assert_equal 1, RailsPulse::WriterHeartbeat.summary[:processes]
      end
    end

    # Deployment Tests

    test "a deployment is recorded and then finished" do
      post_batch([ item("deployment", { action: "record", revision: "abc123", started_at: 2.minutes.ago,
                                        metadata: { "environment" => "production" } }) ])
      post_batch([ item("deployment", { action: "finish", revision: "abc123", finished_at: Time.current }) ])

      in_application(:alpha) do
        deployment = RailsPulse::Deployment.sole

        assert_equal "abc123", deployment.revision
        assert_not_nil deployment.finished_at
        assert_equal "production", deployment.metadata_hash["environment"]
      end
    end

    test "finishing a revision that was never recorded is rejected" do
      post_batch([ item("deployment", { action: "finish", revision: "never", finished_at: Time.current }) ])

      assert_equal 1, response.parsed_body["rejected"]
      assert_match(/no deployment recorded for revision never/, response.parsed_body["errors"].first)
    end

    private

    def job_run_item(run_id:, status:, duration: nil, error_class: nil, error_message: nil, attempts: 1)
      item("job_run", {
        job_class: "ReportJob", queue_name: "reports", run_id: run_id, initial_status: "enqueued", status: status,
        enqueued_at: 1.minute.ago, occurred_at: Time.current, attempts: attempts, adapter: "solid_queue", arguments: "[1]",
        duration: duration, error_class: error_class, error_message: error_message,
        operations: [ { operation_type: "sql", label: nil, actual_sql: "SELECT * FROM reports WHERE id = 1", duration: 2.0,
                        codebase_location: "app/jobs/report_job.rb", start_time: Time.current.to_f, occurred_at: Time.current } ]
      })
    end

    def exception_item(message: "card declined")
      item("exception", {
        exception_class: "PaymentError", location: "app/services/payment.rb#charge", message: message,
        backtrace: [ { file: "app/services/payment.rb", line: 12, method: "charge" } ],
        request_url: "/charges", request_method: "POST", request_params: { "amount" => "[FILTERED]" },
        environment: "production", deploy_sha: nil, occurred_at: Time.current
      })
    end
  end
end
