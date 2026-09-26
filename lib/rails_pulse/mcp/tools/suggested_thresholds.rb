module RailsPulse
  module Mcp
    module Tools
      class SuggestedThresholds < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_suggested_thresholds"
        description "Suggest alert-rule thresholds from the app's real performance history, backtested so you can see " \
                    "how many times each would have fired. Returns strict/balanced/relaxed tiers per metric and " \
                    "flags metrics already covered by an existing rule. Use this to configure alerts that are not noisy. " \
                    "Provided by an extension; without it the tool says so."

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
            },
            route: {
              type: "string",
              description: "Scope to one route as 'METHOD /path' (e.g. 'POST /checkout'). Omit for all routes."
            },
            metric: {
              type: "string",
              description: "Restrict to 'avg_response_time', 'p95_response_time', or 'error_rate'"
            }
          }
        )

        def self.call(days: 7, route: nil, metric: nil, server_context:)
          respond(server_context) do |client|
            params = { days: days.to_i.clamp(1, 30) }
            params[:route] = route if route
            params[:metric] = metric if metric

            result = client.get("/threshold_suggestions", params)
            existing = client.get("/alert_rules")["data"] || []

            metrics = (result["metrics"] || []).map { |m| format_metric(m, existing, route) }

            {
              window: result["window"],
              scope: result["scope"],
              metrics: metrics,
              summary: build_summary(result["window"] || {}, metrics),
              next_steps: build_next_steps(result["window"] || {}, metrics)
            }
          end
        end

        private_class_method def self.format_metric(metric, existing, route)
          covered = existing.select do |rule|
            rule["type"] == "threshold" && rule["metric"] == metric["metric"] && rule["resource_identifier"] == route
          end
          balanced = (metric["tiers"] || []).find { |t| t["name"] == "balanced" }

          {
            metric: metric["metric"],
            unit: metric["unit"],
            insufficient_data: metric["insufficient_data"] == true,
            hours_with_data: metric["hours_with_data"],
            observed: metric["observed"],
            tiers: metric["tiers"],
            existing_rules: covered.map { |r| r["name"] },
            config_snippet: balanced && config_snippet(metric["metric"], balanced["threshold"], route)
          }
        end

        private_class_method def self.config_snippet(metric, threshold, route)
          lines = [ "{" ]
          label = metric.to_s.tr("_", " ").capitalize
          lines << "  name: #{"#{label}#{route ? " on #{route}" : ''}".inspect},"
          lines << "  metric: :#{metric},"
          lines << "  operator: :gt,"
          lines << "  threshold: #{threshold},"
          lines << "  resource_identifier: #{route.inspect}," if route
          lines << "  delivery: { method: :email, to: \"ops@example.com\" }"
          lines << "}"
          lines.join("\n")
        end

        private_class_method def self.build_summary(window, metrics)
          return "No metrics returned." if metrics.empty?

          usable = metrics.reject { |m| m[:insufficient_data] }
          if usable.empty?
            return "Insufficient data: #{window['hours_with_data']} of #{window['expected_hours']} hours have summaries."
          end

          parts = usable.map do |m|
            balanced = Array(m[:tiers]).find { |t| t["name"] == "balanced" }
            "#{m[:metric]} balanced #{balanced['threshold']}#{m[:unit]} (~#{balanced['fires_per_week']} fires/week)"
          end
          "Based on #{window['hours_with_data']} hours: " + parts.join("; ") + "."
        end

        private_class_method def self.build_next_steps(window, metrics)
          steps = []
          if metrics.any? { |m| m[:insufficient_data] }
            steps << "Fewer than 24 hours of hourly summaries — make sure the Rails Pulse summary job is running, then re-run with a longer window."
          end
          covered = metrics.select { |m| m[:existing_rules].any? }
          if covered.any?
            steps << "Already covered by rules: #{covered.map { |m| "#{m[:metric]} (#{m[:existing_rules].join(', ')})" }.join('; ')} — compare their thresholds with the tiers before adding more."
          end
          steps << "Pick a tier by tolerance: 'strict' catches more but fires more often; 'relaxed' only fires on outliers. would_have_fired is the count over the analysed window."
          steps << "Add the chosen rule to `config.alerts` in the alerting initializer (see config_snippet), then watch rails_pulse_alerts for a week."
          steps
        end
      end
    end
  end
end
