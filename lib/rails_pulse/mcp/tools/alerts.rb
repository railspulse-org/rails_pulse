module RailsPulse
  module Mcp
    module Tools
      class Alerts < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_alerts"
        description "Recent alert-rule triggers grouped by rule: how often each rule fired, when, and the latest value. " \
                    "Use this to see what alerting has been flagging. Provided by an extension; without it the tool says so."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            period: {
              type: "string",
              description: "Time period: 'last_hour', 'last_24_hours', 'last_7_days', or ISO 8601 timestamp for 'since'",
              default: "last_7_days"
            },
            rule: {
              type: "string",
              description: "Restrict to one rule by exact name"
            },
            limit: {
              type: "integer",
              description: "Maximum number of events to fetch (1-500)",
              default: 200
            }
          }
        )

        def self.call(period: "last_7_days", rule: nil, limit: 200, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 500)

            params = { since: resolve_since(period), limit: limit }
            params[:rule] = rule if rule
            result = client.get("/alerts", params)
            events = result["data"] || []

            rules = events.group_by { |e| e["rule_name"] || "unknown" }.map do |name, group|
              sorted = group.sort_by { |e| e["triggered_at"].to_s }
              latest = sorted.last
              {
                rule: name,
                count: group.size,
                first_triggered_at: sorted.first["triggered_at"],
                last_triggered_at: latest["triggered_at"],
                latest_value: latest["triggered_value"],
                latest_message: latest["message"]
              }
            end
            rules.sort_by! { |r| r[:last_triggered_at].to_s }.reverse!

            {
              period: period,
              total_events: result.dig("meta", "total") || events.size,
              events_analyzed: events.size,
              rules: rules,
              summary: build_summary(rules, events.size),
              next_steps: build_next_steps(rules)
            }
          end
        end

        private_class_method def self.build_summary(rules, event_count)
          return "No alerts fired in this period." if rules.empty?

          noisiest = rules.max_by { |r| r[:count] }
          "#{event_count} alert event(s) across #{rules.size} rule(s). " \
            "Most frequent: #{noisiest[:rule]} (#{noisiest[:count]} times, last at #{noisiest[:last_triggered_at]})."
        end

        private_class_method def self.build_next_steps(rules)
          steps = [ "Use rails_pulse_alert_rules to see each rule's threshold, cooldown, and whether it is enabled." ]
          if rules.any? { |r| r[:count] >= 10 }
            steps << "Rules firing 10+ times in the period are noisy — use rails_pulse_suggested_thresholds to re-tune them."
          end
          if rules.any?
            steps << "Investigate the route named in a rule's message with rails_pulse_endpoint, using the trigger time as the period."
          end
          steps
        end
      end
    end
  end
end
