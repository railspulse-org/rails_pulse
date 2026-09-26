require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ToolsAlertingTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

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

      ALERTS_RESPONSE = {
        "data" => [
          { "id" => 1, "rule_name" => "High P95", "triggered_value" => 900.0, "triggered_at" => "2026-06-02T10:00:00Z", "message" => "High P95: p95 was 900ms" },
          { "id" => 2, "rule_name" => "High P95", "triggered_value" => 850.0, "triggered_at" => "2026-06-01T10:00:00Z", "message" => "High P95: p95 was 850ms" },
          { "id" => 3, "rule_name" => "Checkout Errors", "triggered_value" => 6.0, "triggered_at" => "2026-06-03T10:00:00Z", "message" => "Checkout Errors: error_rate was 6%" }
        ],
        "meta" => { "total" => 3, "limit" => 200, "offset" => 0 }
      }.freeze

      ALERT_RULES_RESPONSE = {
        "data" => [
          { "name" => "High P95", "type" => "threshold", "metric" => "p95_response_time", "operator" => "gt", "threshold" => 800.0,
            "resource_identifier" => nil, "cooldown_minutes" => 60, "enabled" => true, "delivery_method" => "email",
            "state" => { "last_triggered_at" => "2026-06-02T10:00:00Z", "trigger_count_7d" => 25, "in_cooldown" => true } },
          { "name" => "Quiet Rule", "type" => "threshold", "metric" => "error_rate", "operator" => "gt", "threshold" => 50.0,
            "resource_identifier" => "POST /checkout", "cooldown_minutes" => 60, "enabled" => true, "delivery_method" => "webhook",
            "state" => { "last_triggered_at" => nil, "trigger_count_7d" => 0, "in_cooldown" => false } },
          { "name" => "Old Rule", "type" => "anomaly", "metric" => "avg_response_time", "operator" => "gt", "threshold" => 2.0,
            "resource_identifier" => nil, "cooldown_minutes" => 60, "enabled" => false, "delivery_method" => "email",
            "state" => { "last_triggered_at" => nil, "trigger_count_7d" => 0, "in_cooldown" => false } }
        ],
        "config" => { "quiet_hours" => { "from" => "22:00", "to" => "08:00" }, "deployment_regression" => nil },
        "meta" => { "total" => 3 }
      }.freeze

      DEPLOYMENTS_RESPONSE = {
        "data" => [
          { "id" => 3, "revision" => "ccc333", "short_revision" => "ccc333", "started_at" => "2026-06-03T09:00:00Z", "finished_at" => nil,
            "duration_seconds" => nil, "in_progress" => true, "metadata" => {}, "regression" => nil },
          { "id" => 2, "revision" => "bbb222", "short_revision" => "bbb222", "started_at" => "2026-06-02T09:00:00Z", "finished_at" => "2026-06-02T09:01:00Z",
            "duration_seconds" => 60.0, "in_progress" => false, "metadata" => { "branch" => "main" },
            "regression" => { "outcome" => "triggered", "evaluated_at" => "2026-06-02T09:35:00Z", "message" => "regression",
                              "results" => [ { "metric" => "avg_response_time", "outcome" => "triggered", "pre" => 100.0, "post" => 200.0, "ratio" => 2.0 },
                                             { "metric" => "error_rate", "outcome" => "clean", "pre" => 1.0, "post" => 1.0, "ratio" => 1.0 } ] } },
          { "id" => 1, "revision" => "aaa111", "short_revision" => "aaa111", "started_at" => "2026-06-01T09:00:00Z", "finished_at" => "2026-06-01T09:01:00Z",
            "duration_seconds" => 60.0, "in_progress" => false, "metadata" => {},
            "regression" => { "outcome" => "insufficient_data", "evaluated_at" => "2026-06-01T09:35:00Z", "message" => nil, "results" => [] } }
        ],
        "meta" => { "total" => 3, "limit" => 10, "offset" => 0 }
      }.freeze

      THRESHOLDS_RESPONSE = {
        "window" => { "days" => 7, "since" => "2026-05-25T00:00:00Z", "until" => "2026-06-01T00:00:00Z", "hours_with_data" => 160, "expected_hours" => 168, "total_requests" => 90_000 },
        "scope" => { "resource_identifier" => nil, "route_count" => 12 },
        "metrics" => [
          { "metric" => "p95_response_time", "unit" => "ms", "insufficient_data" => false, "hours_with_data" => 160,
            "observed" => { "min" => 200.0, "median" => 400.0, "p90" => 700.0, "p95" => 820.0, "p99" => 1400.0, "max" => 2000.0 },
            "tiers" => [
              { "name" => "strict", "threshold" => 700, "would_have_fired" => 16, "fires_per_week" => 16.0, "rule" => {} },
              { "name" => "balanced", "threshold" => 850, "would_have_fired" => 8, "fires_per_week" => 8.0, "rule" => {} },
              { "name" => "relaxed", "threshold" => 1400, "would_have_fired" => 2, "fires_per_week" => 2.0, "rule" => {} }
            ] },
          { "metric" => "error_rate", "unit" => "%", "insufficient_data" => true, "hours_with_data" => 10, "observed" => nil, "tiers" => [] }
        ]
      }.freeze

      def client(responses = {})
        StubClient.new(responses)
      end

      def call(tool, client, **args)
        result = tool.call(**args, server_context: { client: client })
        [ result, JSON.parse(result.content.first[:text]) ]
      end

      def error_client
        Object.new.tap do |c|
          def c.get(*, **)
            raise CLI::Client::ApiError, "503 Service Unavailable"
          end
        end
      end

      # --- Alerts ---

      test "alerts groups events by rule, most recent first" do
        c = client("/alerts" => ALERTS_RESPONSE)
        _, data = call(Tools::Alerts, c, limit: 9999)

        assert_equal 500, c.calls.first[1][:limit]
        assert_equal 3, data["total_events"]
        assert_equal [ "Checkout Errors", "High P95" ], data["rules"].map { |r| r["rule"] }

        p95 = data["rules"].last

        assert_equal 2, p95["count"]
        assert_equal "2026-06-01T10:00:00Z", p95["first_triggered_at"]
        assert_equal "2026-06-02T10:00:00Z", p95["last_triggered_at"]
        assert_in_delta 900.0, p95["latest_value"]
        assert_includes data["summary"], "3 alert event(s) across 2 rule(s)"
        assert_includes data["summary"], "Most frequent: High P95 (2 times"
      end

      test "alerts passes rule filter and flags noisy rules" do
        noisy = { "data" => Array.new(12) { |i| { "rule_name" => "Flappy", "triggered_value" => 1, "triggered_at" => "2026-06-01T#{format('%02d', i)}:00:00Z", "message" => "m" } },
                  "meta" => { "total" => 12 } }
        c = client("/alerts" => noisy)
        _, data = call(Tools::Alerts, c, rule: "Flappy")

        assert_equal "Flappy", c.calls.first[1][:rule]
        assert data["next_steps"].any? { |s| s.include?("noisy") }
        assert data["next_steps"].any? { |s| s.include?("rails_pulse_endpoint") }
      end

      test "alerts handles no events" do
        _, data = call(Tools::Alerts, client)

        assert_empty data["rules"]
        assert_includes data["summary"], "No alerts fired"
        assert_equal 1, data["next_steps"].size
      end

      test "alerts handles API error" do
        result = Tools::Alerts.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end

      # --- AlertRules ---

      test "alert_rules lists rules with state and config" do
        _, data = call(Tools::AlertRules, client("/alert_rules" => ALERT_RULES_RESPONSE))

        assert_equal 3, data["rules"].size
        high = data["rules"].first

        assert_equal "p95_response_time", high["metric"]
        assert_equal 25, high["trigger_count_7d"]
        assert high["in_cooldown"]
        assert_equal({ "from" => "22:00", "to" => "08:00" }, data["quiet_hours"])
        assert_nil data["deployment_regression"]
        assert_equal "3 rule(s), 2 enabled, 1 in cooldown.", data["summary"]
      end

      test "alert_rules next_steps flag quiet, noisy, disabled rules and missing regression config" do
        _, data = call(Tools::AlertRules, client("/alert_rules" => ALERT_RULES_RESPONSE))
        steps = data["next_steps"].join("\n")

        assert_includes steps, "Never fired in 7 days (may be too loose): Quiet Rule"
        assert_includes steps, "(noisy): High P95"
        assert_includes steps, "Disabled rules: Old Rule"
        assert_includes steps, "Deployment regression detection is not configured"
      end

      test "alert_rules suggests thresholds when nothing is configured" do
        _, data = call(Tools::AlertRules, client)

        assert_includes data["summary"], "No alert rules"
        assert_equal 1, data["next_steps"].size
        assert_includes data["next_steps"].first, "rails_pulse_suggested_thresholds"
      end

      test "alert_rules handles API error" do
        result = Tools::AlertRules.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end

      # --- Deployments ---

      test "deployments reports outcomes including unchecked" do
        c = client("/deployments" => DEPLOYMENTS_RESPONSE)
        _, data = call(Tools::Deployments, c, limit: 1000)

        assert_equal 100, c.calls.first[1][:limit]
        assert_equal %w[unchecked triggered insufficient_data], data["deployments"].map { |d| d["regression_outcome"] }
        assert data["deployments"].first["in_progress"]
        assert_equal({ "branch" => "main" }, data["deployments"][1]["metadata"])
        assert_includes data["summary"], "3 deployment(s), 1 with a detected regression"
        assert_includes data["summary"], "Latest: ccc333"
      end

      test "deployments next_steps point at the regressed deploy time" do
        _, data = call(Tools::Deployments, client("/deployments" => DEPLOYMENTS_RESPONSE))
        steps = data["next_steps"].join("\n")

        assert_includes steps, "bbb222 regressed (avg_response_time)"
        assert_includes steps, 'period: "2026-06-02T09:00:00Z"'
        assert_includes steps, "insufficient traffic"
        assert_includes steps, "Unchecked deploys"
      end

      test "deployments explains how to record deployments when none exist" do
        _, data = call(Tools::Deployments, client)

        assert_includes data["summary"], "No deployments"
        assert_includes data["next_steps"].first, "record_deployment"
      end

      test "deployments handles API error" do
        result = Tools::Deployments.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end

      # --- SuggestedThresholds ---

      test "suggested_thresholds passes params and merges existing rules" do
        c = client("/threshold_suggestions" => THRESHOLDS_RESPONSE, "/alert_rules" => ALERT_RULES_RESPONSE)
        _, data = call(Tools::SuggestedThresholds, c, days: 90, metric: "p95_response_time")

        suggestion_call = c.calls.find { |path, _| path == "/threshold_suggestions" }

        assert_equal({ days: 30, metric: "p95_response_time" }, suggestion_call[1])
        assert_equal 160, data["window"]["hours_with_data"]

        p95 = data["metrics"].first

        assert_equal [ "High P95" ], p95["existing_rules"]
        assert_equal 3, p95["tiers"].size
        assert_includes p95["config_snippet"], "metric: :p95_response_time"
        assert_includes p95["config_snippet"], "threshold: 850"
        assert_not_includes p95["config_snippet"], "resource_identifier"

        error = data["metrics"].last

        assert error["insufficient_data"]
        assert_empty error["existing_rules"]
        assert_nil error["config_snippet"]
      end

      test "suggested_thresholds summary and next_steps" do
        _, data = call(Tools::SuggestedThresholds, client("/threshold_suggestions" => THRESHOLDS_RESPONSE, "/alert_rules" => ALERT_RULES_RESPONSE))
        steps = data["next_steps"].join("\n")

        assert_includes data["summary"], "Based on 160 hours: p95_response_time balanced 850ms (~8.0 fires/week)"
        assert_includes steps, "Fewer than 24 hours"
        assert_includes steps, "Already covered by rules: p95_response_time (High P95)"
        assert_includes steps, "config_snippet"
      end

      test "suggested_thresholds scopes existing rules and snippet to the route" do
        c = client("/threshold_suggestions" => THRESHOLDS_RESPONSE, "/alert_rules" => ALERT_RULES_RESPONSE)
        _, data = call(Tools::SuggestedThresholds, c, route: "POST /checkout")

        assert_equal "POST /checkout", c.calls.first[1][:route]
        p95 = data["metrics"].first

        assert_empty p95["existing_rules"]
        assert_includes p95["config_snippet"], 'resource_identifier: "POST /checkout"'
        assert_includes p95["config_snippet"], 'name: "P95 response time on POST /checkout"'
      end

      test "suggested_thresholds reports insufficient data overall" do
        insufficient = { "window" => { "hours_with_data" => 3, "expected_hours" => 168 },
                         "metrics" => [ { "metric" => "avg_response_time", "unit" => "ms", "insufficient_data" => true, "tiers" => [] } ] }
        _, data = call(Tools::SuggestedThresholds, client("/threshold_suggestions" => insufficient))

        assert_equal "Insufficient data: 3 of 168 hours have summaries.", data["summary"]
      end

      test "suggested_thresholds handles empty metrics and API error" do
        _, data = call(Tools::SuggestedThresholds, client("/threshold_suggestions" => { "window" => {}, "metrics" => [] }))

        assert_equal "No metrics returned.", data["summary"]
        assert_predicate Tools::SuggestedThresholds.call(server_context: { client: error_client }), :error?
      end
    end
  end
end
