require "test_helper"
require "rails_pulse/cli/routes"
require "rails_pulse/cli/requests"
require "rails_pulse/cli/queries"
require "rails_pulse/cli/jobs"
require "rails_pulse/cli/alerts"
require "rails_pulse/cli/job_runs"
require "rails_pulse/cli/alert_rules"
require "rails_pulse/cli/deployments"
require "rails_pulse/cli/thresholds"

module RailsPulse
  module CLI
    # Shared behaviour for all simple list commands (routes, requests, queries, jobs, alerts).
    # Each command calls client.get(endpoint, params) and renders via Formatter.render.
    class ListCommandsTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      LIST_RESPONSE = {
        "data" => [],
        "meta" => { "total" => 0, "limit" => 25, "offset" => 0 }
      }.freeze

      def setup
        ENV["RAILS_PULSE_URL"]   = "https://example.com"
        ENV["RAILS_PULSE_TOKEN"] = "test-token"
      end

      def teardown
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")
        restore_net_http_start
      end

      def captured_params
        @captured_params ||= {}
      end

      def stub_list(response = LIST_RESPONSE)
        stub_http_response(200, response.to_json) do |_req, uri|
          @captured_uri    = uri
          @captured_params = URI.decode_www_form(uri.query.to_s).to_h
        end
      end

      def run_cmd(klass, options = {})
        defaults = { "limit" => 25, "offset" => 0, "json" => false }
        cmd = klass.new([], defaults.merge(options.transform_keys(&:to_s)))
        capture_io { cmd.list }
      end

      # --- Routes ---

      test "routes list calls /routes endpoint" do
        stub_list
        run_cmd(Routes)

        assert_includes @captured_uri.path, "/routes"
      end

      test "routes list passes limit and offset" do
        stub_list
        run_cmd(Routes, limit: 10, offset: 5)

        assert_equal "10", captured_params["limit"]
        assert_equal "5",  captured_params["offset"]
      end

      test "routes list renders JSON when json: true" do
        stub_list
        out, _err = run_cmd(Routes, json: true)

        assert_nothing_raised { JSON.parse(out) }
      end

      test "routes list passes since, until, search, and sort when provided" do
        stub_list
        run_cmd(Routes, since: "2026-06-01T00:00:00Z", until: "2026-06-02T00:00:00Z", search: "checkout", sort: "avg_duration")

        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-02T00:00:00Z", captured_params["until"]
        assert_equal "checkout", captured_params["search"]
        assert_equal "avg_duration", captured_params["sort"]
      end

      test "routes list renders methods and action, switching to stats columns when present" do
        plain = { "data" => [ { "http_methods" => %w[GET POST], "path" => "/x", "controller_action" => "XController#show", "created_at" => "t", "stats" => nil } ], "meta" => {} }
        out, _err = (stub_list(plain); run_cmd(Routes))

        assert_match(/GET\|POST\s+\/x\s+XController#show/, out)
        refute_includes out, "REQUESTS"

        with_stats = { "data" => [ { "http_methods" => [ "GET" ], "path" => "/x", "controller_action" => nil, "created_at" => "t",
                                     "stats" => { "request_count" => 42, "avg_duration_ms" => 12.5, "error_count" => 3 } } ], "meta" => {} }
        out, _err = (stub_list(with_stats); run_cmd(Routes, since: "2026-06-01T00:00:00Z"))

        assert_includes out, "REQUESTS"
        assert_match(/42\s+12\.5\s+3/, out)
      end

      test "routes list exits with error message on API error" do
        stub_http_response(401, '{"error":"Unauthorized"}')

        err = assert_raises(SystemExit) { run_cmd(Routes) }

        assert_equal 1, err.status
      end

      # --- Requests ---

      test "requests list calls /requests endpoint" do
        stub_list
        run_cmd(Requests)

        assert_includes @captured_uri.path, "/requests"
      end

      test "requests list passes since and until when provided" do
        stub_list
        run_cmd(Requests, since: "2026-06-01T00:00:00Z", until: "2026-06-07T23:59:59Z")

        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-07T23:59:59Z", captured_params["until"]
      end

      test "requests list omits since and until when not provided" do
        stub_list
        run_cmd(Requests)

        refute_includes captured_params.keys, "since"
        refute_includes captured_params.keys, "until"
      end

      test "requests list passes status when provided" do
        stub_list
        run_cmd(Requests, status: "5xx")

        assert_equal "5xx", captured_params["status"]
      end

      # --- Queries ---

      test "queries list calls /queries endpoint" do
        stub_list
        run_cmd(Queries)

        assert_includes @captured_uri.path, "/queries"
      end

      test "queries list passes since and until when provided" do
        stub_list
        run_cmd(Queries, since: "2026-06-01T00:00:00Z", until: "2026-06-07T23:59:59Z")

        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-07T23:59:59Z", captured_params["until"]
      end

      test "queries list omits since and until when not provided" do
        stub_list
        run_cmd(Queries)

        refute_includes captured_params.keys, "since"
        refute_includes captured_params.keys, "until"
        refute_includes captured_params.keys, "sort"
      end

      test "queries list passes sort and renders stats columns when present" do
        with_stats = { "data" => [ { "id" => 7, "normalized_sql" => "SELECT 1", "analyzed_at" => nil,
                                     "stats" => { "executions" => 90, "avg_duration_ms" => 2.5, "max_duration_ms" => 9.0, "total_duration_ms" => 225.0, "max_repetition_count" => 12 } } ],
                       "meta" => {} }
        stub_list(with_stats)
        out, _err = run_cmd(Queries, sort: "total_duration")

        assert_equal "total_duration", captured_params["sort"]
        assert_includes out, "EXECS"
        assert_match(/SELECT 1\s+90\s+2\.5\s+9\.0\s+225\.0\s+12/, out)
      end

      test "queries list keeps the plain columns without stats" do
        stub_list("data" => [ { "id" => 7, "normalized_sql" => "SELECT 1", "analyzed_at" => "t", "stats" => nil } ], "meta" => {})
        out, _err = run_cmd(Queries)

        refute_includes out, "EXECS"
        assert_includes out, "ANALYZED"
      end

      # --- Jobs ---

      test "jobs list calls /jobs endpoint" do
        stub_list
        run_cmd(Jobs)

        assert_includes @captured_uri.path, "/jobs"
      end

      test "jobs list passes status when provided" do
        stub_list
        run_cmd(Jobs, status: "failed")

        assert_equal "failed", captured_params["status"]
      end

      test "jobs list omits status when not provided" do
        stub_list
        run_cmd(Jobs)

        refute_includes captured_params.keys, "status"
      end

      # --- Alerts ---

      test "alerts list calls /alerts endpoint" do
        stub_list
        run_cmd(Alerts)

        assert_includes @captured_uri.path, "/alerts"
      end

      test "alerts list passes rule when provided" do
        stub_list
        run_cmd(Alerts, rule: "High P95")

        assert_equal "High P95", captured_params["rule"]
      end

      test "alerts list omits rule when not provided" do
        stub_list
        run_cmd(Alerts)

        refute_includes captured_params.keys, "rule"
      end

      test "alerts list passes since and until when provided" do
        stub_list
        run_cmd(Alerts, since: "2026-06-01T00:00:00Z", until: "2026-06-07T23:59:59Z")

        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-07T23:59:59Z", captured_params["until"]
      end

      # --- JobRuns ---

      test "job_runs list calls /job_runs with status, job, and time filters" do
        stub_list
        run_cmd(JobRuns, status: "failed", job: "ReportJob", since: "2026-06-01T00:00:00Z", until: "2026-06-02T00:00:00Z")

        assert_includes @captured_uri.path, "/job_runs"
        assert_equal "failed", captured_params["status"]
        assert_equal "ReportJob", captured_params["job"]
        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-02T00:00:00Z", captured_params["until"]
      end

      test "job_runs list omits optional filters and renders a table" do
        stub_list("data" => [ { "id" => 1, "job_name" => "ReportJob", "status" => "failed", "occurred_at" => "t", "duration" => 1.5, "error_class" => "Boom" } ],
                  "meta" => { "total" => 1 })
        out, _err = run_cmd(JobRuns)

        assert_equal %w[limit offset], captured_params.keys
        assert_includes out, "ReportJob"
        assert_includes out, "Boom"
      end

      # --- AlertRules ---

      test "alert_rules list calls /alert_rules and flattens state into the table" do
        stub_list("data" => [ { "name" => "High P95", "type" => "threshold", "metric" => "p95_response_time", "operator" => "gt",
                                "threshold" => 800.0, "enabled" => true, "state" => { "trigger_count_7d" => 4, "in_cooldown" => true } } ],
                  "config" => {}, "meta" => { "total" => 1 })
        out, _err = run_cmd(AlertRules)

        assert_includes @captured_uri.path, "/alert_rules"
        assert_includes out, "High P95"
        assert_match(/4\s+true/, out)
      end

      test "alert_rules list renders JSON with config when json: true" do
        stub_list("data" => [], "config" => { "quiet_hours" => nil }, "meta" => { "total" => 0 })
        out, _err = run_cmd(AlertRules, json: true)

        assert_includes JSON.parse(out).keys, "config"
      end

      # --- Deployments ---

      test "deployments list calls /deployments with time filters and shows regression outcome" do
        stub_list("data" => [
          { "short_revision" => "abc123", "started_at" => "t1", "finished_at" => "t2", "regression" => { "outcome" => "triggered" } },
          { "short_revision" => "def456", "started_at" => "t3", "finished_at" => nil, "regression" => nil }
        ], "meta" => { "total" => 2 })
        out, _err = run_cmd(Deployments, since: "2026-06-01T00:00:00Z", until: "2026-06-07T23:59:59Z")

        assert_includes @captured_uri.path, "/deployments"
        assert_equal "2026-06-01T00:00:00Z", captured_params["since"]
        assert_equal "2026-06-07T23:59:59Z", captured_params["until"]
        assert_match(/abc123.*triggered/, out)
        assert_match(/def456.*unchecked/, out)
      end

      test "a Pro command explains what is missing when the app answers 402" do
        stub_http_response(402, { "error" => "requires_pro", "feature" => "alerts",
                                  "message" => "Alert history needs Rails Pulse Pro, which is not installed in this application.",
                                  "url" => "https://railspulse.com/pro" }.to_json)

        cmd = Alerts.new([], { "limit" => 25, "offset" => 0, "json" => false })
        out, _err = capture_io do
          err = assert_raises(SystemExit) { cmd.list }
          assert_equal 1, err.status
        end

        assert_includes out, "needs Rails Pulse Pro"
        assert_includes out, "https://railspulse.com/pro"
        assert_not_includes out, "API error"
      end

      test "deployments list omits since and until when not provided" do
        stub_list
        run_cmd(Deployments)

        assert_equal %w[limit offset], captured_params.keys
      end

      # --- Thresholds ---

      THRESHOLDS_RESPONSE = {
        "window" => { "days" => 7, "hours_with_data" => 100, "expected_hours" => 168, "total_requests" => 5000 },
        "scope" => { "resource_identifier" => "POST /checkout", "route_count" => 1 },
        "metrics" => [
          { "metric" => "p95_response_time", "unit" => "ms", "insufficient_data" => false, "hours_with_data" => 100,
            "observed" => { "median" => 400.0, "p95" => 800.0, "max" => 1500.0 },
            "tiers" => [ { "name" => "balanced", "threshold" => 850, "would_have_fired" => 5, "fires_per_week" => 5.0 } ] },
          { "metric" => "error_rate", "unit" => "%", "insufficient_data" => true, "hours_with_data" => 3, "observed" => nil, "tiers" => [] }
        ]
      }.freeze

      def run_thresholds(options = {})
        cmd = Thresholds.new([], { "days" => 7, "json" => false }.merge(options.transform_keys(&:to_s)))
        capture_io { cmd.show }
      end

      test "thresholds show calls /threshold_suggestions with days, route, and metric" do
        stub_list(THRESHOLDS_RESPONSE)
        out, _err = run_thresholds(days: 14, route: "POST /checkout", metric: "p95_response_time")

        assert_includes @captured_uri.path, "/threshold_suggestions"
        assert_equal "14", captured_params["days"]
        assert_equal "POST /checkout", captured_params["route"]
        assert_equal "p95_response_time", captured_params["metric"]
        assert_includes out, "for POST /checkout"
        assert_includes out, "P95_RESPONSE_TIME"
        assert_includes out, "balanced  > 850"
        assert_includes out, "would have fired 5 times"
        assert_includes out, "insufficient data (3 hours)"
      end

      test "thresholds show omits optional params and renders JSON when json: true" do
        stub_list(THRESHOLDS_RESPONSE)
        out, _err = run_thresholds(json: true)

        assert_equal [ "days" ], captured_params.keys
        assert_equal 7, JSON.parse(out)["window"]["days"]
      end

      test "thresholds show exits with error on API error" do
        stub_http_response(500, '{"error":"boom"}')

        err = assert_raises(SystemExit) { run_thresholds }

        assert_equal 1, err.status
      end
    end
  end
end
