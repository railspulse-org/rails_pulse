require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ToolsTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      # Stub client that returns canned API responses and remembers what
      # each tool asked for.
      class StubClient
        attr_reader :calls

        def initialize(responses = {})
          @responses = responses
          @calls = []
        end

        def get(path, params = {})
          @calls << [ path, params ]
          @responses[path] || { "data" => [], "meta" => { "total" => 0, "limit" => 25, "offset" => 0 } }
        end
      end

      REQUESTS_RESPONSE = {
        "data" => [
          {
            "id" => 1, "status" => 200, "duration" => 150.5,
            "controller_action" => "HomeController#index",
            "is_error" => false, "occurred_at" => "2026-06-01T12:00:00Z"
          },
          {
            "id" => 2, "status" => 200, "duration" => 250.0,
            "controller_action" => "HomeController#index",
            "is_error" => false, "occurred_at" => "2026-06-01T11:00:00Z"
          },
          {
            "id" => 3, "status" => 500, "duration" => 300.0,
            "controller_action" => "CheckoutController#create",
            "is_error" => true, "occurred_at" => "2026-06-01T12:30:00Z"
          }
        ],
        "meta" => { "total" => 3, "limit" => 25, "offset" => 0 }
      }.freeze

      # The routes endpoint with a time window: per-route stats, ordered by
      # the requested sort.
      ROUTES_RESPONSE = {
        "data" => [
          {
            "id" => 2, "http_methods" => [ "POST" ], "path" => "/checkout", "controller_action" => "CheckoutController#create",
            "tags" => [], "stats" => { "request_count" => 2, "avg_duration_ms" => 300.0, "error_count" => 1 }
          },
          {
            "id" => 1, "http_methods" => [ "GET" ], "path" => "/", "controller_action" => "HomeController#index",
            "tags" => [], "stats" => { "request_count" => 40, "avg_duration_ms" => 200.0, "error_count" => 0 }
          }
        ],
        "meta" => { "total" => 2, "limit" => 10, "offset" => 0 }
      }.freeze

      # The shape the extension's summary endpoint returns from GET summary.
      SUMMARY_RESPONSE = {
        "period" => {
          "type" => "week", "start" => "2026-05-26", "end" => "2026-06-01",
          "label" => "May 26 – Jun 1, 2026"
        },
        "overview" => {
          "p95_ms" => 800, "avg_ms" => 200, "total_requests" => 1000, "error_count" => 15, "error_rate_pct" => 1.5,
          "vs_previous" => {
            "p95_ms" => 700, "total_requests" => 900, "error_rate_pct" => 1.1,
            "p95_delta_pct" => 14.3, "total_delta_pct" => 11.1, "error_rate_delta_pct" => 36.4
          }
        },
        "slowest_routes" => [
          { "route" => "CheckoutController#create", "requests" => 50, "avg_ms" => 450, "p95_ms" => 900,
            "error_count" => 3, "prev_p95_delta_pct" => 12.5 }
        ],
        "slowest_queries" => [],
        "job_summaries" => [],
        "insights" => [],
        "alert_events" => [],
        "recommendations" => []
      }.freeze

      def server_context(responses = {})
        { client: StubClient.new(responses) }
      end

      # --- SlowRequests ---

      test "slow_requests asks the routes endpoint for the window sorted by average duration" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        Tools::SlowRequests.call(period: "last_hour", limit: 5, server_context: ctx)

        path, params = ctx[:client].calls.first

        assert_equal "/routes", path
        assert_equal "avg_duration", params[:sort]
        assert_equal 5, params[:limit]
        assert_operator Time.parse(params[:since]), :>, 2.hours.ago
      end

      test "slow_requests returns endpoints in the order the API ranked them" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal 2, data["endpoints"].size
        assert_equal "CheckoutController#create", data["endpoints"].first["endpoint"]
        assert_equal "/checkout", data["endpoints"].first["path"]
        assert_in_delta(300.0, data["endpoints"].first["avg_duration_ms"])
        assert_equal 2, data["routes_with_traffic"]
      end

      test "slow_requests calculates error rate per endpoint" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        checkout = data["endpoints"].find { |e| e["endpoint"] == "CheckoutController#create" }

        assert_in_delta(50.0, checkout["error_rate"])
        assert_equal 1, checkout["error_count"]
      end

      test "slow_requests drops endpoints below min_requests" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        result = Tools::SlowRequests.call(min_requests: 10, server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal [ "HomeController#index" ], data["endpoints"].map { |e| e["endpoint"] }
      end

      test "slow_requests includes a summary" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "Slowest endpoint: CheckoutController#create"
        assert_includes data["summary"], "Highest error rate"
      end

      test "slow_requests handles empty data" do
        ctx = server_context
        result = Tools::SlowRequests.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 0, data["endpoints"].size
        assert_includes data["summary"], "No request data"
        assert_includes data["next_steps"].first, "Widen the period"
      end

      test "slow_requests clamps limit" do
        ctx = server_context("/routes" => ROUTES_RESPONSE)
        result = Tools::SlowRequests.call(limit: 999, server_context: ctx)

        assert_not result.error?
        assert_equal 100, ctx[:client].calls.first.last[:limit]
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
        assert_equal 200, data["stats"]["avg_duration_ms"]
        assert_equal 800, data["stats"]["p95_duration_ms"]
        assert_equal 15, data["stats"]["error_count"]
        assert_in_delta(1.5, data["stats"]["error_rate"])
      end

      test "request_stats includes period comparison" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 900, data["previous_period"]["total_requests"]
        assert_equal 700, data["previous_period"]["p95_duration_ms"]
        assert_in_delta(14.3, data["changes"]["p95_duration_change_pct"])
        assert_equal "degrading", data["changes"]["p95_duration_trend"]
        assert_in_delta(11.1, data["changes"]["total_requests_change_pct"])
        assert_equal "degrading", data["changes"]["error_rate_trend"]
      end

      test "request_stats explains a period with no summaries instead of returning blank numbers" do
        empty = SUMMARY_RESPONSE.deep_dup
        empty["overview"] = {
          "p95_ms" => nil, "avg_ms" => nil, "total_requests" => nil, "error_count" => 0, "error_rate_pct" => nil,
          "vs_previous" => { "p95_ms" => nil, "total_requests" => nil, "error_rate_pct" => nil,
                             "p95_delta_pct" => nil, "total_delta_pct" => nil, "error_rate_delta_pct" => nil }
        }
        empty["slowest_routes"] = []
        ctx = server_context("/summary" => empty)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_not result.error?
        assert_includes data["summary"], "No summary data for May 26 – Jun 1, 2026"
        assert_includes data["summary"], "rails_pulse_slow_requests"
        assert_nil data["changes"]
      end

      test "request_stats omits the comparison when there is no previous period" do
        first_week = SUMMARY_RESPONSE.deep_dup
        first_week["overview"]["vs_previous"] = { "p95_ms" => nil, "total_requests" => nil, "error_rate_pct" => nil,
                                                  "p95_delta_pct" => nil, "total_delta_pct" => nil, "error_rate_delta_pct" => nil }
        ctx = server_context("/summary" => first_week)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_nil data["previous_period"]
        assert_nil data["changes"]
      end

      test "request_stats includes slowest routes" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_equal 1, data["slowest_routes"].size
        route = data["slowest_routes"].first

        assert_equal "CheckoutController#create", route["endpoint"]
        assert_equal 450, route["avg_duration_ms"]
        assert_equal 900, route["p95_duration_ms"]
        assert_equal 50, route["request_count"]
        assert_in_delta(12.5, route["p95_delta_pct"])
      end

      test "request_stats includes summary text" do
        ctx = server_context("/summary" => SUMMARY_RESPONSE)
        result = Tools::RequestStats.call(server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "1000 requests"
        assert_includes data["summary"], "p95 800ms"
        assert_includes data["summary"], "p95 degrading vs previous period"
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

      test "endpoint asks the requests endpoint for that route only" do
        ctx = server_context("/requests" => REQUESTS_RESPONSE)
        Tools::Endpoint.call(endpoint: "/checkout", period: "last_hour", limit: 50, server_context: ctx)

        path, params = ctx[:client].calls.first

        assert_equal "/requests", path
        assert_equal "/checkout", params[:route]
        assert_equal 50, params[:limit]
        assert_operator Time.parse(params[:since]), :>, 2.hours.ago
      end

      test "endpoint returns a profile of the requests the API matched" do
        home_only = { "data" => REQUESTS_RESPONSE["data"].first(2), "meta" => { "total" => 120, "limit" => 200, "offset" => 0 } }
        ctx = server_context("/requests" => home_only)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert_equal "HomeController#index", data["endpoint"]
        assert_equal 120, data["request_count"]
        assert_equal 2, data["sampled_requests"]
        assert_operator data["latency"]["avg_ms"], :>, 0
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
        checkout_only = { "data" => REQUESTS_RESPONSE["data"].last(1), "meta" => { "total" => 1 } }
        ctx = server_context("/requests" => checkout_only)
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
              "is_error" => false, "occurred_at" => "2026-06-01T1#{i}:00:00Z" }
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
        ctx = server_context
        result = Tools::Endpoint.call(endpoint: "NonexistentController#action", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["error"], "No requests found"
      end

      test "endpoint includes summary" do
        home_only = { "data" => REQUESTS_RESPONSE["data"].first(2), "meta" => { "total" => 2 } }
        ctx = server_context("/requests" => home_only)
        result = Tools::Endpoint.call(endpoint: "HomeController#index", server_context: ctx)
        data = JSON.parse(result.content.first[:text])

        assert_includes data["summary"], "2 requests (2 most recent analyzed)"
      end
    end
  end
end
