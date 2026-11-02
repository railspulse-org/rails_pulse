module RailsPulse
  module Mcp
    module Tools
      class Insights < ::MCP::Tool
        extend Helpers

        PERIODS = %w[hour day week month].freeze

        tool_name "rails_pulse_insights"
        description "What needs attention over one summary period, and whether the configured thresholds fit " \
                    "it. Lists the routes, queries and jobs past their slow or critical thresholds (critical " \
                    "first, ten at most), then checks route_thresholds, query_thresholds and job_thresholds " \
                    "against the period's slowest routes and jobs and most expensive queries and returns a config line to paste " \
                    "when one is too noisy or never fires. Use it for 'what should I look at' and 'are my " \
                    "thresholds right'. Reads whole periods, so the P95s are exact."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            period: {
              type: "string",
              enum: PERIODS,
              description: "Summary period to read: 'hour', 'day', 'week' or 'month'.",
              default: "week"
            },
            at: {
              type: "string",
              description: "A time inside the period, ISO 8601 (read as UTC with no zone). Omit for the last " \
                           "complete period; the current one has no summary until it ends."
            }
          }
        )

        def self.call(period: "week", at: nil, server_context:, **_options)
          respond(server_context) do |client|
            unless PERIODS.include?(period)
              raise Helpers::WindowError, "Unknown period #{period.inspect}. Use #{PERIODS.join(', ')}."
            end

            params = { period: period }
            params[:at] = parse_time(at, "at").iso8601 if at
            data = client.get("/insights", params)
            attention = data["needs_attention"] || {}
            recommendations = data["threshold_recommendations"] || []

            {
              period: data["period"],
              thresholds: data["thresholds"],
              needs_attention: attention,
              threshold_recommendations: recommendations,
              summary: build_summary(data["period"] || {}, attention, recommendations),
              next_steps: build_next_steps(data["period"] || {}, attention, recommendations)
            }
          end
        end

        private_class_method def self.build_summary(period, attention, recommendations)
          critical = Array(attention["critical"]).size
          warning = Array(attention["warning"]).size
          if !period["summarized"] && critical.zero? && warning.zero?
            return "The #{period['type']} starting #{period['start']} has not been summarized yet."
          end

          parts = [ "#{period['type'].to_s.capitalize} starting #{period['start']}: #{critical} critical, #{warning} warning." ]
          parts << "#{recommendations.size} threshold change(s) suggested." if recommendations.any?
          parts << "SummaryJob has not finished this period, so the list may be incomplete." unless period["summarized"]
          parts.join(" ")
        end

        private_class_method def self.build_next_steps(period, attention, recommendations)
          items = Array(attention["critical"]) + Array(attention["warning"])
          if !period["summarized"] && items.empty?
            return [ "Pass an earlier 'at', or call rails_pulse_coverage to see how far summaries reach." ]
          end

          steps = []
          if (route = items.find { |i| i["type"] == "route" })
            steps << "Profile #{route['name']} with rails_pulse_endpoint, and pass route: #{route['id']} to " \
                     "rails_pulse_queries for the SQL inside it."
          end
          if items.any? { |i| i["type"] == "job" }
            steps << "Call rails_pulse_jobs for the failing or slow jobs' recent runs and error classes."
          end
          if recommendations.any?
            steps << "Each config_snippet replaces the whole setting in config/initializers/rails_pulse.rb; " \
                     "check the period was typical before changing a threshold."
          end
          steps << "Nothing passed its thresholds; compare an earlier period to confirm." if items.empty? && recommendations.empty?
          steps
        end
      end
    end
  end
end
