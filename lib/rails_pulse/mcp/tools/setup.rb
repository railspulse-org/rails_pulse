module RailsPulse
  module Mcp
    module Tools
      class Setup < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_setup"
        description "Check what still needs configuring in Rails Pulse Pro and get data-driven suggestions: alert " \
                    "thresholds backtested against real traffic, a route-scoped rule for the worst outlier, deployment " \
                    "regression detection, quiet hours, sender address, weekly summary email, and whether the scheduled " \
                    "jobs are actually running. Returns an ordered list of findings, each with a status (ok, pending, " \
                    "suggested, missing, needs_attention), a reason, and a paste-ready snippet with the file it belongs " \
                    "in. This tool changes nothing: apply the snippets yourself to config/initializers/rails_pulse_pro.rb " \
                    "(or the file named on the finding), then deploy. Snippets use REPLACE_WITH_EMAIL and " \
                    "REPLACE_WITH_HOST placeholders; ask the user for real values, never invent them. Run it a week " \
                    "after install and again every few months to retune. Needs Rails Pulse Pro in the application."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            days: {
              type: "integer",
              description: "Days of history to analyse (1-30)",
              default: 7
            }
          }
        )

        def self.call(days: 7, server_context:)
          respond(server_context) do |client|
            result = client.get("/setup", { days: days.to_i.clamp(1, 30) })
            findings = result["findings"] || []

            result.merge(
              "summary"    => build_summary(result["phase"], findings),
              "next_steps" => build_next_steps(result["phase"], findings, result["next_check"])
            )
          end
        end

        private_class_method def self.build_summary(phase, findings)
          counts = findings.group_by { |f| f["status"] }.transform_values(&:size)
          actionable = counts.values_at("missing", "needs_attention", "suggested").compact.sum
          "Phase: #{phase}. #{findings.size} checks: #{counts.fetch('ok', 0)} ok, #{counts.fetch('pending', 0)} pending, " \
            "#{actionable} need action (#{counts.fetch('missing', 0)} missing, #{counts.fetch('needs_attention', 0)} need attention, " \
            "#{counts.fetch('suggested', 0)} suggested)."
        end

        private_class_method def self.build_next_steps(phase, findings, next_check)
          steps = []
          if phase == "install"
            steps << "Not enough hourly summaries yet to suggest thresholds. Fix any missing data-flow findings, then re-run later."
          end

          actionable = findings.select { |f| %w[missing needs_attention suggested].include?(f["status"]) }
          if actionable.any?
            steps << "Apply these in order: #{actionable.map { |f| "#{f['key']} (#{f['status']})" }.join(', ')}. " \
                     "Each finding names the file its snippet belongs in; config_additions collects the Pro initializer ones."
            steps << "Replace REPLACE_WITH_EMAIL and REPLACE_WITH_HOST with values from the user before applying." if actionable.any? { |f| f["snippet"].to_s.include?("REPLACE_WITH") }
          else
            steps << "Nothing to change."
          end

          pending = findings.select { |f| f["status"] == "pending" }
          steps << "Pending, not wrong: #{pending.map { |f| f['key'] }.join(', ')}. Re-check later." if pending.any?
          steps << next_check if next_check
          steps
        end
      end
    end
  end
end
