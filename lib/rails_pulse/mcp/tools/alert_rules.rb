module RailsPulse
  module Mcp
    module Tools
      class AlertRules < ::MCP::Tool
        extend Helpers

        NOISY_TRIGGERS_7D = 20

        tool_name "rails_pulse_alert_rules"
        description "The configured alert rules (threshold and anomaly), their metrics and thresholds, whether each is " \
                    "enabled or in cooldown, and how often it fired in the last 7 days, plus quiet hours and " \
                    "deployment regression settings. Use this before proposing new alerts. Needs Rails Pulse Pro in the application."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(properties: {})

        def self.call(server_context:)
          respond(server_context) do |client|
            result = client.get("/alert_rules")
            rules = (result["data"] || []).map { |r| format_rule(r) }
            config = result["config"] || {}

            {
              rules: rules,
              quiet_hours: config["quiet_hours"],
              deployment_regression: config["deployment_regression"],
              summary: build_summary(rules),
              next_steps: build_next_steps(rules, config)
            }
          end
        end

        private_class_method def self.format_rule(rule)
          state = rule["state"] || {}
          {
            name: rule["name"],
            type: rule["type"],
            metric: rule["metric"],
            operator: rule["operator"],
            threshold: rule["threshold"],
            resource_identifier: rule["resource_identifier"],
            cooldown_minutes: rule["cooldown_minutes"],
            enabled: rule["enabled"],
            delivery_method: rule["delivery_method"],
            last_triggered_at: state["last_triggered_at"],
            trigger_count_7d: state["trigger_count_7d"].to_i,
            in_cooldown: state["in_cooldown"] == true
          }
        end

        private_class_method def self.build_summary(rules)
          return "No alert rules are configured." if rules.empty?

          enabled = rules.count { |r| r[:enabled] }
          cooling = rules.count { |r| r[:in_cooldown] }
          "#{rules.size} rule(s), #{enabled} enabled, #{cooling} in cooldown."
        end

        private_class_method def self.build_next_steps(rules, config)
          steps = []
          if rules.empty?
            steps << "Run rails_pulse_suggested_thresholds to get data-driven thresholds for a first set of rules."
            return steps
          end

          quiet = rules.select { |r| r[:enabled] && r[:type] == "threshold" && r[:trigger_count_7d].zero? }
          if quiet.any?
            steps << "Never fired in 7 days (may be too loose): #{quiet.map { |r| r[:name] }.join(', ')} — compare with rails_pulse_suggested_thresholds."
          end

          noisy = rules.select { |r| r[:trigger_count_7d] >= NOISY_TRIGGERS_7D }
          if noisy.any?
            steps << "Fired #{NOISY_TRIGGERS_7D}+ times in 7 days (noisy): #{noisy.map { |r| r[:name] }.join(', ')} — raise the threshold or cooldown."
          end

          disabled = rules.reject { |r| r[:enabled] }
          steps << "Disabled rules: #{disabled.map { |r| r[:name] }.join(', ')}." if disabled.any?

          steps << "Deployment regression detection is not configured — consider enabling it." if config["deployment_regression"].nil?
          steps << "Use rails_pulse_alerts to see the trigger history for any rule."
          steps
        end
      end
    end
  end
end
