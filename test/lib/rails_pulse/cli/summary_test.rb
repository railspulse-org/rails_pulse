require "test_helper"
require "rails_pulse/cli/summary"
require "rails_pulse/cli/client"
require "rails_pulse/cli/config"

module RailsPulse
  module CLI
    class SummaryTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      FAKE_RESPONSE = {
        "period" => {
          "type"  => "week",
          "label" => "Jun 8 – Jun 14, 2026",
          "start" => "2026-06-08T00:00:00.000Z",
          "end"   => "2026-06-14T23:59:59.999Z"
        },
        "overview" => {
          "p95_ms"         => 450,
          "avg_ms"         => 210,
          "total_requests" => 1000,
          "error_count"    => 5,
          "error_rate_pct" => 0.5,
          "vs_previous" => {
            "p95_ms"               => 400,
            "total_requests"       => 900,
            "error_rate_pct"       => 0.3,
            "p95_delta_pct"        => 12.5,
            "total_delta_pct"      => 11.1,
            "error_rate_delta_pct" => 66.7
          }
        },
        "slowest_routes" => [
          {
            "route"              => "GET /api/orders",
            "requests"           => 100,
            "avg_ms"             => 380,
            "p95_ms"             => 750,
            "error_count"        => 2,
            "prev_p95_delta_pct" => 15.0
          }
        ],
        "slowest_queries" => [
          {
            "sql"        => "SELECT * FROM orders WHERE user_id = ?",
            "executions" => 500,
            "avg_ms"     => 45,
            "p95_ms"     => 120,
            "total_ms"   => 22_500
          }
        ],
        "job_summaries" => [
          {
            "name"     => "UserMailerJob",
            "runs"     => 200,
            "failures" => 5,
            "avg_ms"   => 150,
            "p95_ms"   => 300
          }
        ],
        "insights" => {
          "total"    => 1,
          "critical" => [],
          "warning"  => [
            {
              "type"   => "ROUTE",
              "name"   => "GET /api/slow",
              "reason" => "750ms P95 · above slow threshold"
            }
          ]
        },
        "alert_events" => [
          {
            "rule"         => "High Latency",
            "value"        => 600.0,
            "triggered_at" => "2026-06-10T14:30:00Z",
            "message"      => "P95 exceeded threshold"
          }
        ],
        "recommendations" => [
          {
            "title"          => "Route slow threshold may be too low",
            "detail"         => "3 of 5 sampled routes exceeded the 500ms threshold.",
            "config_snippet" => "config.route_thresholds = { slow: 750, critical: 3000 }"
          }
        ]
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

      def run_show(**options)
        response = options.delete(:response) || FAKE_RESPONSE
        stub_http_response(200, response.to_json) do |_req, uri|
          @captured_uri    = uri
          @captured_params = URI.decode_www_form(uri.query.to_s).to_h
        end
        defaults = { "period" => "week", "json" => false }
        cmd = Summary.new([], defaults.merge(options.transform_keys(&:to_s)))
        capture_io { cmd.show }
      end

      # --- API routing ---

      test "calls /summary endpoint" do
        run_show

        assert_includes @captured_uri.path, "/summary"
      end

      test "passes period param to API" do
        run_show(period: "month")

        assert_equal "month", @captured_params["period"]
      end

      test "passes from param to API when provided" do
        run_show(from: "2026-06-08")

        assert_equal "2026-06-08", @captured_params["from"]
      end

      test "omits from param when not provided" do
        run_show

        refute_includes @captured_params.keys, "from"
      end

      # --- JSON output ---

      test "outputs pretty JSON when --json flag is set" do
        out, _err = run_show(json: true)

        parsed = JSON.parse(out)

        assert parsed.key?("period")
        assert parsed.key?("overview")
      end

      # --- Human-readable output structure ---

      test "outputs the period label" do
        out, _err = run_show

        assert_includes out, "Jun 8"
        assert_includes out, "Jun 14, 2026"
      end

      test "outputs OVERVIEW section header" do
        out, _err = run_show

        assert_includes out, "OVERVIEW"
      end

      test "explains an empty period instead of printing blank numbers" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["overview"] = {
          "p95_ms" => nil, "avg_ms" => nil, "total_requests" => nil, "error_count" => 0, "error_rate_pct" => nil,
          "vs_previous" => { "p95_ms" => nil, "total_requests" => nil, "error_rate_pct" => nil,
                             "p95_delta_pct" => nil, "total_delta_pct" => nil, "error_rate_delta_pct" => nil }
        }
        out, _err = run_show(response: response)

        assert_includes out, "No summary data for this period"
        assert_includes out, "rails_pulse:backfill_summaries"
        refute_includes out, " ms"
      end

      test "outputs P95 stat with trend arrow for positive delta" do
        out, _err = run_show

        assert_includes out, "P95 Response Time"
        assert_includes out, "450 ms"
        assert_includes out, "↑"
        assert_includes out, "12.5%"
      end

      test "outputs trend arrow down for negative delta" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["overview"]["vs_previous"]["p95_delta_pct"] = -8.0

        out, _err = run_show(response: response)

        assert_includes out, "↓"
        assert_includes out, "8.0%"
      end

      test "outputs NEEDS ATTENTION section when insights total > 0" do
        out, _err = run_show

        assert_includes out, "NEEDS ATTENTION"
        assert_includes out, "1 issues"
      end

      test "omits NEEDS ATTENTION section when insights total is 0" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["insights"]["total"]   = 0
        response["insights"]["warning"] = []

        out, _err = run_show(response: response)

        refute_includes out, "NEEDS ATTENTION"
      end

      test "outputs SLOWEST ROUTES section with route data" do
        out, _err = run_show

        assert_includes out, "SLOWEST ROUTES"
        assert_includes out, "GET /api/orders"
        assert_includes out, "P95 750ms"
      end

      test "outputs trend arrow on route row for positive delta" do
        out, _err = run_show

        assert_includes out, "↑"
        assert_includes out, "15.0%"
      end

      test "outputs SLOWEST QUERIES section with query data" do
        out, _err = run_show

        assert_includes out, "SLOWEST QUERIES"
        assert_includes out, "SELECT"
        assert_includes out, "500 exec"
      end

      test "outputs BACKGROUND JOBS section with failure indicator" do
        out, _err = run_show

        assert_includes out, "BACKGROUND JOBS"
        assert_includes out, "UserMailerJob"
        assert_includes out, "✗ 5 failures"
      end

      test "omits failure indicator when job has no failures" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["job_summaries"][0]["failures"] = 0

        out, _err = run_show(response: response)

        refute_includes out, "✗"
      end

      test "outputs ALERTS section with fired event" do
        out, _err = run_show

        assert_includes out, "ALERTS"
        assert_includes out, "High Latency"
      end

      test "outputs overflow indicator when more than 5 alerts" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["alert_events"] = 7.times.map { |i|
          { "rule" => "Alert #{i}", "value" => 500, "triggered_at" => "2026-06-10T#{i.to_s.rjust(2, "0")}:00:00Z" }
        }

        out, _err = run_show(response: response)

        assert_includes out, "… and 2 more"
      end

      test "outputs 'All clear' when no alerts fired" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["alert_events"] = []

        out, _err = run_show(response: response)

        assert_includes out, "All clear"
      end

      test "outputs CONFIG RECOMMENDATIONS section" do
        out, _err = run_show

        assert_includes out, "CONFIG RECOMMENDATIONS"
        assert_includes out, "Route slow threshold may be too low"
        assert_includes out, "config.route_thresholds"
      end

      test "omits CONFIG RECOMMENDATIONS when no recommendations" do
        response = Marshal.load(Marshal.dump(FAKE_RESPONSE))
        response["recommendations"] = []

        out, _err = run_show(response: response)

        refute_includes out, "CONFIG RECOMMENDATIONS"
      end

      # --- error handling ---

      test "exits 1 and prints error message on API error" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        cmd = Summary.new([], { "period" => "week", "json" => false })

        err = assert_raises(SystemExit) { capture_io { cmd.show } }

        assert_equal 1, err.status
      end

      test "exits 1 and prints error message on config error" do
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")
        cmd = Summary.new([], { "period" => "week", "json" => false })

        err = assert_raises(SystemExit) { capture_io { cmd.show } }

        assert_equal 1, err.status
      end

      # --- trend_arrow helper ---

      test "trend_arrow returns up arrow for positive delta" do
        cmd = Summary.new([], {})

        assert_equal "↑", cmd.send(:trend_arrow, 5.0)
      end

      test "trend_arrow returns down arrow for negative delta" do
        cmd = Summary.new([], {})

        assert_equal "↓", cmd.send(:trend_arrow, -3.0)
      end

      test "trend_arrow returns empty string for nil" do
        cmd = Summary.new([], {})

        assert_equal "", cmd.send(:trend_arrow, nil)
      end
    end
  end
end
