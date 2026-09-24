require "json"

module RailsPulse
  module Mcp
    module Tools
      class RequestStats < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_request_stats"
        description "Aggregate request performance statistics for a week or month: volume, latency, error rate, " \
                    "with the change against the previous period. Needs Rails Pulse Pro in the application."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            period: {
              type: "string",
              description: "Summary period type: 'week' or 'month'",
              default: "week"
            },
            from: {
              type: "string",
              description: "Any date within the target period (YYYY-MM-DD). Defaults to the last completed period."
            }
          }
        )

        def self.call(period: "week", from: nil, server_context:)
          respond(server_context) do |client|
            params = { period: period }
            params[:from] = from if from

            format_response(client.get("/summary", params))
          end
        end

        private_class_method def self.format_response(data)
          overview = data["overview"] || {}
          prev_overview = data["prev_overview"] || {}
          period = data["period"] || {}

          response = {
            period: {
              type: period["type"],
              start: period["start"],
              end: period["end"],
              label: period["label"]
            },
            stats: {
              total_requests: overview["total_requests"],
              avg_duration_ms: overview["avg_duration"],
              p95_duration_ms: overview["p95_duration"],
              error_count: overview["error_count"],
              error_rate: overview["error_rate"]
            },
            slowest_routes: (data["slowest_routes"] || []).first(5).map do |route|
              {
                endpoint: route["label"],
                avg_duration_ms: route["avg_duration"],
                request_count: route["count"],
                error_count: route["error_count"],
                delta_pct: route["delta_pct"]
              }
            end
          }

          # Add comparison if previous period data exists
          if prev_overview && prev_overview["total_requests"]
            response[:previous_period] = {
              total_requests: prev_overview["total_requests"],
              avg_duration_ms: prev_overview["avg_duration"],
              error_rate: prev_overview["error_rate"]
            }
            response[:changes] = build_changes(overview, prev_overview)
          end

          response[:summary] = build_summary(response)
          response
        end

        private_class_method def self.build_changes(current, previous)
          changes = {}
          if current["avg_duration"] && previous["avg_duration"] && previous["avg_duration"] > 0
            delta = ((current["avg_duration"].to_f - previous["avg_duration"].to_f) / previous["avg_duration"].to_f * 100).round(1)
            changes[:avg_duration_change_pct] = delta
            changes[:avg_duration_trend] = delta > 5 ? "degrading" : delta < -5 ? "improving" : "stable"
          end
          if current["error_rate"] && previous["error_rate"]
            delta = (current["error_rate"].to_f - previous["error_rate"].to_f).round(2)
            changes[:error_rate_change] = delta
            changes[:error_rate_trend] = delta > 1 ? "degrading" : delta < -1 ? "improving" : "stable"
          end
          changes
        end

        private_class_method def self.build_summary(response)
          stats = response[:stats]
          parts = []
          parts << "#{stats[:total_requests]} requests"
          parts << "avg #{stats[:avg_duration_ms]}ms" if stats[:avg_duration_ms]
          parts << "#{stats[:error_rate]}% error rate" if stats[:error_rate]

          if response[:changes]
            trend = response[:changes][:avg_duration_trend]
            parts << "latency #{trend}" if trend
          end

          parts.join(", ") + "."
        end
      end
    end
  end
end
