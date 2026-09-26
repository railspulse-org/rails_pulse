require "test_helper"

module RailsPulse
  module Api
    module V1
      class RoutesControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_routes_path

          assert_response :unauthorized
          assert_equal "Unauthorized", JSON.parse(response.body)["error"]
        end

        test "returns 401 with wrong token" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => "wrong" }

          assert_response :unauthorized
        end

        test "returns 401 when token is unconfigured" do
          RailsPulse.configuration.api_token = nil
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :unauthorized
        end

        # The schema report names missing tables and columns; the token
        # check must run before it.
        test "returns 401, not the schema report, to an anonymous caller when the schema is outdated" do
          RailsPulse::SchemaCheck.stubs(:current?).returns(false)
          RailsPulse::SchemaCheck.stubs(:missing).returns({ "rails_pulse_events" => [ "table" ] })
          RailsPulse::SchemaCheck.stubs(:warn_once!)

          get rails_pulse.api_v1_routes_path

          assert_response :unauthorized
          assert_equal({ "error" => "Unauthorized" }, JSON.parse(response.body))
        end

        test "returns the JSON schema report to an authenticated caller when the schema is outdated" do
          RailsPulse::SchemaCheck.stubs(:current?).returns(false)
          RailsPulse::SchemaCheck.stubs(:missing).returns({ "rails_pulse_events" => [ "table" ] })
          RailsPulse::SchemaCheck.stubs(:warn_once!)

          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :service_unavailable
          assert_match(/schema upgrade/, JSON.parse(response.body)["error"])
        end

        test "does not touch the session" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :success
          assert_nil session[:show_non_tagged]
        end

        test "returns 200 with correct token" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :success
        end

        test "returns expected JSON shape with data array and meta" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert body.key?("data")
          assert body.key?("meta")
          assert_equal %w[total limit offset], body["meta"].keys
        end

        test "serializes route fields" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)
          route = body["data"].first

          %w[id http_methods path controller_action tags created_at stats].each { |k| assert_includes route.keys, k }
          assert_nil route["stats"]
        end

        test "search filters by path or controller action" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { search: "USERS" }
          body = JSON.parse(response.body)

          assert_equal [ "/api/users" ], body["data"].map { |r| r["path"] }
          assert_equal 1, body["meta"]["total"]
        end

        test "returns 400 for invalid sort" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { sort: "bogus" }

          assert_response :bad_request
        end

        test "time range adds request stats ordered by request count" do
          get rails_pulse.api_v1_routes_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { since: 20.hours.ago.iso8601 }
          body = JSON.parse(response.body)

          assert_response :success
          assert_equal [ "/api/users", "/api/posts", "/api/other" ], body["data"].map { |r| r["path"] }
          assert_equal 3, body["meta"]["total"]

          users = body["data"].first

          assert_equal "api/users#index", users["controller_action"]
          assert_equal 5, users["stats"]["request_count"]
          assert_in_delta 1320.1, users["stats"]["avg_duration_ms"]
          assert_equal 1, users["stats"]["error_count"]
          assert_equal 0, body["data"].second["stats"]["error_count"]
        end

        test "sort by error_count without since defaults to the last 24 hours" do
          get rails_pulse.api_v1_routes_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { sort: "error_count" }
          body = JSON.parse(response.body)

          # /api/users and /api/other each had one error in the last 24 hours.
          assert_equal [ "/api/other", "/api/users" ], body["data"].first(2).map { |r| r["path"] }.sort
          assert_equal 1, body["data"].first["stats"]["error_count"]
        end

        test "search combines with stats and pagination" do
          get rails_pulse.api_v1_routes_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { since: 20.hours.ago.iso8601, search: "posts", limit: 1 }
          body = JSON.parse(response.body)

          assert_equal [ "/api/posts" ], body["data"].map { |r| r["path"] }
          assert_equal 1, body["meta"]["total"]
        end

        test "routes without traffic in the window are omitted" do
          get rails_pulse.api_v1_routes_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { since: 10.minutes.ago.iso8601 }
          body = JSON.parse(response.body)

          assert_empty body["data"]
          assert_equal 0, body["meta"]["total"]
        end

        test "meta total reflects all route records" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert_equal RailsPulse::Route.count, body["meta"]["total"]
        end

        test "respects limit parameter" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { limit: 1 }
          body = JSON.parse(response.body)

          assert_equal 1, body["data"].length
          assert_equal 1, body["meta"]["limit"]
        end

        test "respects offset parameter" do
          get rails_pulse.api_v1_routes_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { offset: 1000 }
          body = JSON.parse(response.body)

          assert_empty body["data"]
          assert_equal RailsPulse::Route.count, body["meta"]["total"]
        end
      end
    end
  end
end
