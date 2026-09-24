require "test_helper"
require "rails_pulse/cli/setup"

module RailsPulse
  module CLI
    class SetupTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      PLAN = {
        "phase" => "tuning",
        "window" => { "days" => 7, "hours_with_data" => 164, "expected_hours" => 168, "total_requests" => 41_203 },
        "findings" => [
          { "key" => "request_data", "status" => "ok", "reason" => "41,203 requests recorded in the last 24 hours." },
          { "key" => "alert_rules", "status" => "missing", "reason" => "No alert rules configured.",
            "snippet" => "config.alerts = [\n  { name: \"P95\" }\n]", "file" => "config/initializers/rails_pulse_pro.rb" },
          { "key" => "summary_email", "status" => "pending", "reason" => "Job has not run yet." }
        ],
        "next_check" => "Run again in 7 days to tune thresholds against real alert history."
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

      def run_check(options = {})
        stub_http_response(200, PLAN.to_json) do |_req, uri|
          @captured_uri = uri
          @captured_params = URI.decode_www_form(uri.query.to_s).to_h
        end
        cmd = Setup.new([], { "days" => 7, "json" => false }.merge(options.transform_keys(&:to_s)))
        capture_io { cmd.check }
      end

      test "calls the setup endpoint with days" do
        run_check(days: 14)

        assert_includes @captured_uri.path, "/setup"
        assert_equal "14", @captured_params["days"]
      end

      test "renders findings, snippets with their file, and the next check" do
        out, _err = run_check

        assert_includes out, "setup check — phase: tuning"
        assert_includes out, "164 of 168 hours of summaries, 41203 requests"
        assert_includes out, "ok               request_data"
        assert_includes out, "missing          alert_rules"
        assert_includes out, "No alert rules configured."
        assert_includes out, "SNIPPETS"
        assert_includes out, "# alert_rules → config/initializers/rails_pulse_pro.rb"
        assert_includes out, "  config.alerts = ["
        assert_includes out, "    { name: \"P95\" }"
        assert_includes out, PLAN["next_check"]
      end

      test "renders raw JSON with --json" do
        out, _err = run_check(json: true)

        assert_equal PLAN, JSON.parse(out)
      end

      test "reports API errors and exits" do
        stub_http_response(500, { "error" => "boom" }.to_json)
        cmd = Setup.new([], { "days" => 7, "json" => false })

        _out, err = capture_io do
          assert_raises(SystemExit) { cmd.check }
        end

        assert_includes err + _out, "API error"
      end
    end
  end
end
