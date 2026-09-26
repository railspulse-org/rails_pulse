require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ToolsSetupTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      class StubClient
        attr_reader :calls

        def initialize(response)
          @response = response
          @calls = []
        end

        def get(path, params = {})
          @calls << [ path, params ]
          @response
        end
      end

      TUNING_PLAN = {
        "phase" => "tuning",
        "window" => { "days" => 7, "hours_with_data" => 164, "expected_hours" => 168, "total_requests" => 41_203 },
        "status" => { "alert_rules" => 0 },
        "findings" => [
          { "key" => "request_data", "status" => "ok", "reason" => "41,203 requests recorded in the last 24 hours." },
          { "key" => "hourly_summaries", "status" => "ok", "reason" => "164 of 168 hours summarised." },
          { "key" => "pro_job", "status" => "ok", "reason" => "Last ran 3 minutes ago, 0 rules evaluated." },
          { "key" => "alert_rules", "status" => "missing", "reason" => "No alert rules configured.",
            "snippet" => "config.alerts = [ { delivery: { method: :email, to: \"REPLACE_WITH_EMAIL\" } } ]",
            "file" => "config/initializers/rails_pulse.rb" },
          { "key" => "quiet_hours", "status" => "suggested", "reason" => "Traffic drops overnight.",
            "snippet" => "config.quiet_hours = { from: \"01:00\", to: \"06:00\" }", "file" => "config/initializers/rails_pulse.rb" },
          { "key" => "from_email", "status" => "needs_attention", "reason" => "Still the default." },
          { "key" => "summary_email", "status" => "pending", "reason" => "Job has not run yet." }
        ],
        "next_check" => "Run again in 7 days to tune thresholds against real alert history.",
        "config_additions" => "RailsPulse.configure do |config|\nend"
      }.freeze

      INSTALL_PLAN = {
        "phase" => "install",
        "window" => { "days" => 7, "hours_with_data" => 3, "expected_hours" => 48 },
        "findings" => [
          { "key" => "request_data", "status" => "ok", "reason" => "12 requests." },
          { "key" => "hourly_summaries", "status" => "pending", "reason" => "3 hours so far." },
          { "key" => "alert_rules", "status" => "pending", "reason" => "Needs 24 hours." }
        ],
        "next_check" => "Run again once 24 hours of hourly summaries exist (about 21 hours)."
      }.freeze

      def call(client, **args)
        result = Tools::Setup.call(**args, server_context: { client: client })
        [ result, JSON.parse(result.content.first[:text]) ]
      end

      test "passes days through, clamped, and returns the plan with a summary and next steps" do
        client = StubClient.new(TUNING_PLAN)
        _, data = call(client, days: 90)

        assert_equal [ [ "/setup", { days: 30 } ] ], client.calls
        assert_equal "tuning", data["phase"]
        assert_equal 7, data["findings"].size
        assert_equal TUNING_PLAN["config_additions"], data["config_additions"]
        assert_equal "Phase: tuning. 7 checks: 3 ok, 1 pending, 3 need action (1 missing, 1 need attention, 1 suggested).", data["summary"]
      end

      test "next steps list actionable findings in order, the placeholder warning, pending keys, and the next check" do
        _, data = call(StubClient.new(TUNING_PLAN))
        steps = data["next_steps"]

        assert_includes steps[0], "Apply these in order: alert_rules (missing), quiet_hours (suggested), from_email (needs_attention)"
        assert_includes steps[0], "config_additions"
        assert_includes steps[1], "Replace REPLACE_WITH_EMAIL and REPLACE_WITH_HOST"
        assert_equal "Pending, not wrong: summary_email. Re-check later.", steps[2]
        assert_equal TUNING_PLAN["next_check"], steps[3]
      end

      test "install phase explains that thresholds cannot be suggested yet" do
        _, data = call(StubClient.new(INSTALL_PLAN), days: 7)
        steps = data["next_steps"]

        assert_equal "Phase: install. 3 checks: 1 ok, 2 pending, 0 need action (0 missing, 0 need attention, 0 suggested).", data["summary"]
        assert_includes steps[0], "Not enough hourly summaries yet"
        assert_equal "Nothing to change.", steps[1]
        assert_includes steps[2], "hourly_summaries, alert_rules"
        assert_equal INSTALL_PLAN["next_check"], steps.last
      end

      test "defaults to seven days and copes with an empty response" do
        client = StubClient.new({})
        _, data = call(client)

        assert_equal [ [ "/setup", { days: 7 } ] ], client.calls
        assert_equal "Phase: . 0 checks: 0 ok, 0 pending, 0 need action (0 missing, 0 need attention, 0 suggested).", data["summary"]
        assert_equal [ "Nothing to change." ], data["next_steps"]
      end

      test "API errors are returned as tool errors" do
        client = Object.new
        def client.get(*, **)
          raise CLI::Client::ApiError, "503 Service Unavailable"
        end

        result = Tools::Setup.call(server_context: { client: client })

        assert_predicate result, :error?
        assert_includes result.content.first[:text], "503 Service Unavailable"
      end

      test "tool is read-only and its description tells the agent to apply snippets itself" do
        assert Tools::Setup.annotations.read_only_hint
        assert_includes Tools::Setup.description, "changes nothing"
        assert_includes Tools::Setup.description, "the file named on each finding"
        assert_includes Tools::Setup.description, "never invent them"
      end
    end
  end
end
