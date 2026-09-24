require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ToolsTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      # Stub client that returns canned API responses
      class StubClient
        def initialize(responses = {})
          @responses = responses
        end

        def get(path, _params = {})
          @responses[path] || { "data" => [], "meta" => { "total" => 0, "limit" => 25, "offset" => 0 } }
        end
      end

      REQUESTS_RESPONSE = {
        "data" => [
          {
            "id" => 1, "status" => 200, "duration" => 150.5,
            "controller_action" => "HomeController#index", "path" => "/",
            "is_error" => false, "occurred_at" => "2026-06-01T12:00:00Z"
          },
          {
            "id" => 2, "status" => 200, "duration" => 250.0,
            "controller_action" => "HomeController#index", "path" => "/",
            "is_error" => false, "occurred_at" => "2026-06-01T11:00:00Z"
          },
          {
            "id" => 3, "status" => 500, "duration" => 300.0,
            "controller_action" => "CheckoutController#create", "path" => "/checkout",
            "is_error" => true, "occurred_at" => "2026-06-01T12:30:00Z"
          }
        ],
        "meta" => { "total" => 3, "limit" => 25, "offset" => 0 }
      }.freeze

      SUMMARY_RESPONSE = {
        "overview" => {
          "total_requests" => 1000, "avg_duration" => 200.5,
          "p95_duration" => 800.0, "error_count" => 15, "error_rate" => 1.5
        },
        "prev_overview" => {
          "total_requests" => 900, "avg_duration" => 180.0,
          "error_count" => 10, "error_rate" => 1.1
        },
        "period" => {
          "type" => "week", "start" => "2026-05-26", "end" => "2026-06-01",
          "label" => "May 26 – Jun 1, 2026"
        },
        "slowest_routes" => [
          { "label" => "CheckoutController#create", "avg_duration" => 450, "count" => 50,
            "error_count" => 3, "delta_pct" => 12.5 }
        ]
      }.freeze

      def server_context(responses = {})
        { client: StubClient.new(responses) }
      end

      # --- SlowRequests ---

      test "slow_requests returns endpoints sorted by avg duration" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal 2, data["endpoints"].size
        assert_equal "CheckoutController#create", data["endpoints"].first["endpoint"]
        assert_in_delta(300.0, data["endpoints"].first["avg_duration_ms"])
      end

      test "slow_requests calculates error rate per endpoint" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        checkout = data["endpoints"].find { |e| e["endpoint"] == "CheckoutController#create" }

        assert_in_delta(100.0, checkout["error_rate"])
        assert_equal 1, checkout["error_count"]
      end

      test "slow_requests includes a summary" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "Slowest endpoint"
      end

      test "slow_requests handles empty data" do
        ctx = server_context
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 0, data["endpoints"].size
        assert_includes data["summary"], "No request data"
      end

      test "slow_requests clamps limit" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::SlowRequests.call(limit: 999, server_context: ctx)

        assert_not result.error?
      end

      test "slow_requests handles API error" do
        error_client = Object.new
        def error_client.get(*, **)
          raise CLI::Client::ApiError, "401 Unauthorized"
        end
        ctx = { client: error_client }
        result = Tools::SlowRequests.call(server_context: ctx)

        assert_predicate result, :error?
        assert_includes result.content.first[:text], "401 Unauthorized"
      end

      # --- RequestStats ---

      test "request_stats returns aggregate stats" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal 1000, data["stats"]["total_requests"]
        assert_in_delta(200.5, data["stats"]["avg_duration_ms"])
        assert_in_delta(1.5, data["stats"]["error_rate"])
      end

      test "request_stats includes period comparison" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert data["previous_period"]
        assert_equal 900, data["previous_period"]["total_requests"]
        assert data["changes"]
      end

      test "request_stats includes slowest routes" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 1, data["slowest_routes"].size
        assert_equal "CheckoutController#create", data["slowest_routes"].first["endpoint"]
      end

      test "request_stats includes summary text" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "1000 requests"
      end

      test "request_stats handles API error" do
        error_client = Object.new
        def error_client.get(*, **)
          raise CLI::Client::ApiError, "500 Internal Server Error"
        end
        ctx = { client: error_client }
        result = Tools::RequestStats.call(server_context: ctx)

        assert_predicate result, :error?
      end

      # --- Errors ---

      test "errors returns error requests grouped by endpoint" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Errors.call(server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal "5xx", data["status_filter"]
        assert_kind_of Array, data["by_endpoint"]
      end

      test "errors includes total error count" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Errors.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 3, data["total_errors"]
      end

      test "errors includes summary" do
        error_response = {
          "data" => [
            {
              "id" => 3, "status" => 500, "duration" => 300.0,
              "controller_action" => "CheckoutController#create",
              "is_error" => true, "occurred_at" => "2026-06-01T12:30:00Z"
            }
          ],
          "meta" => { "total" => 1, "limit" => 25, "offset" => 0 }
        }
        ctx = server_context("/requests" => error_response)
        result = Tools::Errors.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "1 total 5xx errors"
      end

      test "errors handles no errors" do
        empty = { "data" => [], "meta" => { "total" => 0, "limit" => 25, "offset" => 0 } }
        ctx = server_context("/requests" => empty)
        result = Tools::Errors.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "No 5xx errors found"
      end

      # --- Endpoint ---

      test "endpoint returns profile for matching controller action" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal "HomeController#index", data["endpoint"]
        assert_equal 2, data["request_count"]
        assert_operator data["latency"]["avg_ms"], :>, 0
      end

      test "endpoint matches by path" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "/checkout", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal "CheckoutController#create", data["endpoint"]
        assert_equal 1, data["request_count"]
      end

      test "endpoint includes latency percentiles" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        latency = data["latency"]

        assert latency.key?("avg_ms")
        assert latency.key?("p50_ms")
        assert latency.key?("p95_ms")
        assert latency.key?("p99_ms")
        assert latency.key?("min_ms")
        assert latency.key?("max_ms")
      end

      test "endpoint includes error information" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "CheckoutController#create", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 1, data["errors"]["count"]
        assert_in_delta(100.0, data["errors"]["rate"])
        assert_kind_of Array, data["recent_errors"]
      end

      test "endpoint includes next_steps" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_kind_of Array, data["next_steps"]
        assert data["next_steps"].any? { |s| s.include?("source code") }
      end

      test "endpoint next_steps flag high p95 latency and p95/avg ratio" do
        slow = {
          "data" => [ 100.0, 100.0, 100.0, 5000.0 ].each_with_index.map do |duration, i|
            { "id" => i, "status" => 200, "duration" => duration, "controller_action" => "ReportsController#show",
              "path" => "/reports", "is_error" => false, "occurred_at" => "2026-06-01T1#{i}:00:00Z" }
          end,
          "meta" => { "total" => 4 }
        }
        ctx = server_context("/requests" => slow)
        result = Tools::Endpoint.call(endpoint: "ReportsController#show", server_context: ctx)
        steps = JSON.parse(result.content.first[:text])["next_steps"].join("\n")

        assert_includes steps, "P95 latency is over 1s"
        assert_includes steps, "High p95/avg ratio"
      end

      test "endpoint returns helpful message for no match" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "NonexistentController#action", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["error"], "No requests found"
      end

      test "endpoint includes summary" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "2 requests"
      end
    end
  end
end
