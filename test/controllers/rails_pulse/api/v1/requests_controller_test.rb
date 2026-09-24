require "test_helper"

module RailsPulse
  module Api
    module V1
      class RequestsControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_requests_path

          assert_response :unauthorized
        end

        test "returns 401 with wrong token" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => "wrong" }

          assert_response :unauthorized
        end

        test "returns 200 with correct token" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :success
        end

        test "returns expected JSON shape" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert body.key?("data")
          assert body.key?("meta")
        end

        test "serializes request fields" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)
          req = body["data"].first

          %w[id route_id occurred_at duration status is_error request_uuid controller_action response_size_bytes].each do |k|
            assert_includes req.keys, k
          end
        end

        test "meta total reflects all request records" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert_equal RailsPulse::Request.count, body["meta"]["total"]
        end

        test "filters by exact status code" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { status: 500 }
          body = JSON.parse(response.body)

          assert_equal 2, body["data"].length
          assert_equal [ 500, 500 ], body["data"].map { |r| r["status"] }
        end

        test "filters by 5xx status class" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { status: "5xx" }
          body = JSON.parse(response.body)

          assert_equal 2, body["data"].length
          body["data"].each { |r| assert r["status"] >= 500 && r["status"] < 600 }
        end

        test "filters by 2xx status class" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { status: "2xx" }
          body = JSON.parse(response.body)

          refute_empty body["data"]
          body["data"].each { |r| assert r["status"] >= 200 && r["status"] < 300 }
        end

        test "filters by since time" do
          cutoff = 100.minutes.ago.iso8601
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { since: cutoff }
          body = JSON.parse(response.body)

          body["data"].each { |r| assert_operator Time.parse(r["occurred_at"]), :>=, 100.minutes.ago }
        end

        test "filters by until time" do
          cutoff = 100.minutes.ago.iso8601
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { until: cutoff }
          body = JSON.parse(response.body)

          body["data"].each { |r| assert_operator Time.parse(r["occurred_at"]), :<=, 100.minutes.ago }
        end

        test "returns 400 for invalid since time" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { since: "not-a-date" }

          assert_response :bad_request
          assert_equal "Invalid time format for 'since'", JSON.parse(response.body)["error"]
        end

        test "returns 400 for invalid until time" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { until: "not-a-date" }

          assert_response :bad_request
          assert_equal "Invalid time format for 'until'", JSON.parse(response.body)["error"]
        end

        test "respects limit parameter" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { limit: 1 }
          body = JSON.parse(response.body)

          assert_equal 1, body["data"].length
        end

        test "respects offset parameter" do
          get rails_pulse.api_v1_requests_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { offset: 1000 }
          body = JSON.parse(response.body)

          assert_empty body["data"]
        end
      end
    end
  end
end
