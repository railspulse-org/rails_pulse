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

        # The summary endpoint (rails_pulse_pro's SummarySerializer) reports
        # the overview as p95_ms / avg_ms / total_requests / error_count /
        # error_rate_pct with the previous period under vs_previous, and each
        # slowest route as route / requests / avg_ms / p95_ms / error_count /
        # prev_p95_delta_pct.
        private_class_method def self.format_response(data)
          overview = data["overview"] || {}
          previous = overview["vs_previous"] || {}
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
              avg_duration_ms: overview["avg_ms"],
              p95_duration_ms: overview["p95_ms"],
              error_count: overview["error_count"],
              error_rate: overview["error_rate_pct"]
            },
            slowest_routes: (data["slowest_routes"] || []).first(5).map do |route|
              {
                endpoint: route["route"],
                avg_duration_ms: route["avg_ms"],
                p95_duration_ms: route["p95_ms"],
                request_count: route["requests"],
                error_count: route["error_count"],
                p95_delta_pct: route["prev_p95_delta_pct"]
              }
            end
          }

          if previous["total_requests"]
            response[:previous_period] = {
              total_requests: previous["total_requests"],
              p95_duration_ms: previous["p95_ms"],
              error_rate: previous["error_rate_pct"]
            }
            response[:changes] = build_changes(previous)
          end

          response[:summary] = build_summary(response)
          response
        end

        private_class_method def self.build_changes(previous)
          changes = {}
          if (delta = previous["p95_delta_pct"])
            changes[:p95_duration_change_pct] = delta
            changes[:p95_duration_trend] = delta > 5 ? "degrading" : delta < -5 ? "improving" : "stable"
          end
          if (delta = previous["total_delta_pct"])
            changes[:total_requests_change_pct] = delta
          end
          if (delta = previous["error_rate_delta_pct"])
            changes[:error_rate_change_pct] = delta
            changes[:error_rate_trend] = delta > 5 ? "degrading" : delta < -5 ? "improving" : "stable"
          end
          changes
        end

        private_class_method def self.build_summary(response)
          stats = response[:stats]
          if stats[:total_requests].nil?
            return "No summary data for #{response[:period][:label] || 'this period'}: no requests were tracked, " \
                   "or RailsPulse::SummaryJob has not run for it yet (rails rails_pulse:backfill_summaries builds " \
                   "summaries for past traffic). Use rails_pulse_routes or rails_pulse_slow_requests for live request data."
          end

          parts = []
          parts << "#{stats[:total_requests]} requests"
          parts << "avg #{stats[:avg_duration_ms]}ms" if stats[:avg_duration_ms]
          parts << "p95 #{stats[:p95_duration_ms]}ms" if stats[:p95_duration_ms]
          parts << "#{stats[:error_rate]}% error rate" if stats[:error_rate]

          if response[:changes]
            trend = response[:changes][:p95_duration_trend]
            parts << "p95 #{trend} vs previous period" if trend
          end

          parts.join(", ") + "."
        end
      end
    end
  end
end
