require "json"

module RailsPulse
  module Mcp
    module Tools
      class SlowRequests < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_slow_requests"
        description "Return the slowest endpoints/requests for a time period. " \
                    "Use this to identify which routes are taking the longest to respond."

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
              default: "last_24_hours"
            },
            limit: {
              type: "integer",
              description: "Maximum number of results (1-100)",
              default: 10
            },
            status: {
              type: "string",
              description: "Filter by HTTP status class: '2xx', '3xx', '4xx', '5xx', or an exact code like '500'"
            }
          }
        )

        def self.call(period: "last_24_hours", limit: 10, status: nil, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 100)

            params = { limit: limit, offset: 0 }
            params[:since] = resolve_since(period)
            params[:status] = status if status

            result = client.get("/requests", params)
            requests = result["data"] || []

            # Group by controller_action to find the slowest endpoints
            by_endpoint = requests.group_by { |r| r["controller_action"] || "unknown" }

            endpoints = by_endpoint.map do |action, reqs|
              durations = reqs.map { |r| r["duration"].to_f }.sort
              error_count = reqs.count { |r| r["is_error"] }

              {
                endpoint: action,
                request_count: reqs.size,
                avg_duration_ms: (durations.sum / durations.size).round(1),
                max_duration_ms: durations.last.round(1),
                p95_duration_ms: percentile(durations, 95).round(1),
                error_count: error_count,
                error_rate: reqs.size > 0 ? ((error_count.to_f / reqs.size) * 100).round(1) : 0
              }
            end

            endpoints.sort_by! { |e| -e[:avg_duration_ms] }

            {
              period: period,
              total_requests: requests.size,
              endpoints: endpoints,
              summary: build_summary(endpoints)
            }
          end
        end

        private_class_method def self.build_summary(endpoints)
          return "No request data found for this period." if endpoints.empty?

          slowest = endpoints.first
          parts = [ "Slowest endpoint: #{slowest[:endpoint]} (avg #{slowest[:avg_duration_ms]}ms, p95 #{slowest[:p95_duration_ms]}ms)" ]

          error_endpoints = endpoints.select { |e| e[:error_rate] > 0 }
          if error_endpoints.any?
            worst = error_endpoints.max_by { |e| e[:error_rate] }
            parts << "Highest error rate: #{worst[:endpoint]} (#{worst[:error_rate]}%)"
          end

          parts.join(". ") + "."
        end
      end
    end
  end
end
