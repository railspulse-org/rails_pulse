require "test_helper"

module RailsPulse
  module Api
    module V1
      class JobRunsControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"
        HEADERS = { "X-Rails-Pulse-Token" => VALID_TOKEN }.freeze

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
          RailsPulse::Operation.where.not(job_run_id: nil).delete_all
          RailsPulse::JobRun.delete_all

          @mailer_job  = rails_pulse_jobs(:mailer_job)
          @report_job  = rails_pulse_jobs(:report_job)

          @success_run = create_run(@mailer_job, "run-1", status: "success", occurred_at: 3.hours.ago)
          @failed_run  = create_run(@report_job, "run-2", status: "failed", occurred_at: 2.hours.ago,
                                    error_class: "Timeout::Error", error_message: "execution expired")
          @discarded   = create_run(@report_job, "run-3", status: "discarded", occurred_at: 1.hour.ago,
                                    error_class: "ActiveRecord::RecordNotFound", error_message: "gone")
        end

        teardown do
          RailsPulse.configuration.api_token = nil
          RailsPulse::JobRun.delete_all
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_job_runs_path

          assert_response :unauthorized
        end

        test "returns runs newest first with data and meta" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS
          body = JSON.parse(response.body)

          assert_response :success
          assert_equal %w[run-3 run-2 run-1], body["data"].map { |r| r["run_id"] }
          assert_equal 3, body["meta"]["total"]
        end

        test "serializes run fields without arguments" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS
          run = JSON.parse(response.body)["data"].find { |r| r["run_id"] == "run-2" }

          assert_equal "GenerateReportJob", run["job_name"]
          assert_equal "default", run["queue_name"]
          assert_equal "Timeout::Error", run["error_class"]
          assert_equal "execution expired", run["error_message"]
          assert_not run.key?("arguments")
        end

        test "status=failed includes failed and discarded runs" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { status: "failed" }
          body = JSON.parse(response.body)

          assert_equal %w[discarded failed], body["data"].map { |r| r["status"] }.sort
        end

        test "exact status filters to that status only" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { status: "success" }
          body = JSON.parse(response.body)

          assert_equal [ "run-1" ], body["data"].map { |r| r["run_id"] }
        end

        test "returns 400 for unknown status" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { status: "bogus" }

          assert_response :bad_request
        end

        test "filters by job name" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { job: "UserMailerJob" }
          body = JSON.parse(response.body)

          assert_equal [ "run-1" ], body["data"].map { |r| r["run_id"] }
          assert_equal 1, body["meta"]["total"]
        end

        test "filters by since and until" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS,
              params: { since: 150.minutes.ago.iso8601, until: 90.minutes.ago.iso8601 }
          body = JSON.parse(response.body)

          assert_equal [ "run-2" ], body["data"].map { |r| r["run_id"] }
        end

        test "returns 400 for invalid since" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { since: "bad" }

          assert_response :bad_request
        end

        test "respects limit and offset" do
          get rails_pulse.api_v1_job_runs_path, headers: HEADERS, params: { limit: 1, offset: 1 }
          body = JSON.parse(response.body)

          assert_equal [ "run-2" ], body["data"].map { |r| r["run_id"] }
          assert_equal 3, body["meta"]["total"]
        end

        private

        def create_run(job, run_id, status:, occurred_at:, error_class: nil, error_message: nil)
          RailsPulse::JobRun.create!(
            job: job, run_id: run_id, status: status, occurred_at: occurred_at,
            duration: 120.0, attempts: 1, adapter: "sidekiq",
            error_class: error_class, error_message: error_message,
            arguments: '["secret-arg"]'
          )
        end
      end
    end
  end
end
