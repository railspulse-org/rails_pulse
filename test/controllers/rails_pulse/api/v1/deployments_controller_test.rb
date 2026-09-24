require "test_helper"

module RailsPulse
  module Api
    module V1
      class DeploymentsControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"
        HEADERS = { "X-Rails-Pulse-Token" => VALID_TOKEN }.freeze

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
          RailsPulse::Deployment.delete_all

          @old     = RailsPulse::Deployment.create!(revision: "a" * 40, started_at: 3.days.ago, finished_at: 3.days.ago + 90,
                                                    metadata: { "branch" => "main" }.to_json)
          @middle  = RailsPulse::Deployment.create!(revision: "bbb222", started_at: 2.hours.ago, finished_at: 2.hours.ago + 60)
          @running = RailsPulse::Deployment.create!(revision: "ccc333", started_at: 10.minutes.ago)
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_deployments_path

          assert_response :unauthorized
        end

        test "lists deployments newest first" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS
          body = JSON.parse(response.body)

          assert_response :success
          assert_equal %w[ccc333 bbb222 aaaaaaaaaaaa], body["data"].map { |d| d["short_revision"] }
          assert_equal 3, body["meta"]["total"]
          assert_equal({ "branch" => "main" }, body["data"].last["metadata"])
        end

        test "regression is nil for every deployment without Rails Pulse Pro" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS
          body = JSON.parse(response.body)

          assert body["data"].all? { |d| d.key?("regression") && d["regression"].nil? }
        end

        test "serializes in-progress deployments" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS
          running = JSON.parse(response.body)["data"].first

          assert running["in_progress"]
          assert_nil running["finished_at"]
          assert_nil running["duration_seconds"]
        end

        test "filters by since and until" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS,
              params: { since: 1.day.ago.iso8601, until: 1.hour.ago.iso8601 }
          body = JSON.parse(response.body)

          assert_equal [ "bbb222" ], body["data"].map { |d| d["revision"] }
        end

        test "returns 400 for invalid until" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS, params: { until: "bad" }

          assert_response :bad_request
        end

        test "respects limit and offset" do
          get rails_pulse.api_v1_deployments_path, headers: HEADERS, params: { limit: 1, offset: 2 }
          body = JSON.parse(response.body)

          assert_equal [ "a" * 40 ], body["data"].map { |d| d["revision"] }
        end

        test "returns empty data when there are no deployments" do
          RailsPulse::Deployment.delete_all

          get rails_pulse.api_v1_deployments_path, headers: HEADERS
          body = JSON.parse(response.body)

          assert_empty body["data"]
          assert_equal 0, body["meta"]["total"]
        end
      end
    end
  end
end
