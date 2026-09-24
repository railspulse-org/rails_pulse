require "test_helper"

module RailsPulse
  module Api
    module V1
      class JobsControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_jobs_path

          assert_response :unauthorized
        end

        test "returns 401 with wrong token" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => "wrong" }

          assert_response :unauthorized
        end

        test "returns 200 with correct token" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :success
        end

        test "returns expected JSON shape" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert body.key?("data")
          assert body.key?("meta")
          assert_equal %w[total limit offset], body["meta"].keys
        end

        test "serializes job fields" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)
          job = body["data"].first

          %w[id name queue_name runs_count failures_count avg_duration p95_duration p99_duration failure_rate].each do |k|
            assert_includes job.keys, k
          end
        end

        test "meta total reflects all job records" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert_equal RailsPulse::Job.count, body["meta"]["total"]
        end

        test "filters by failed status" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { status: "failed" }
          body = JSON.parse(response.body)

          assert_equal 1, body["data"].length
          body["data"].each { |j| assert_operator j["failures_count"], :>, 0 }
        end

        test "includes failure_rate computed field" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)
          failing = body["data"].find { |j| j["name"] == "GenerateReportJob" }

          assert_in_delta(50.0, failing["failure_rate"])
        end

        test "respects limit parameter" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { limit: 1 }
          body = JSON.parse(response.body)

          assert_equal 1, body["data"].length
        end

        test "respects offset parameter" do
          get rails_pulse.api_v1_jobs_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { offset: 1000 }
          body = JSON.parse(response.body)

          assert_empty body["data"]
        end
      end
    end
  end
end
