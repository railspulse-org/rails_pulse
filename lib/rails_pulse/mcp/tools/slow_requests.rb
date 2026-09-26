require "json"

module RailsPulse
  module Mcp
    module Tools
      class SlowRequests < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_slow_requests"
        description "The slowest endpoints for a time period, ranked by average response time over every " \
                    "request in the window, with request volume and error counts. " \
                    "Use this to find which routes are taking the longest to respond."

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
              description: "Maximum number of endpoints (1-100)",
              default: 10
            },
            min_requests: {
              type: "integer",
              description: "Skip endpoints with fewer requests than this in the period, so a single slow hit does not top the list",
              default: 1
            }
          }
        )

        # The routes endpoint aggregates every request in the window on the
        # server, so the ranking covers the whole period rather than a page
        # of the most recent requests.
        def self.call(period: "last_24_hours", limit: 10, min_requests: 1, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 100)
            min_requests = min_requests.to_i.clamp(1, 1_000_000)

            result = client.get("/routes", { since: resolve_since(period), sort: "avg_duration", limit: limit })
            routes = result["data"] || []

            endpoints = routes.filter_map do |route|
              stats = route["stats"] || {}
              request_count = stats["request_count"].to_i
              next if request_count < min_requests

              error_count = stats["error_count"].to_i
              {
                endpoint: route["controller_action"] || route["path"],
                path: route["path"],
                http_methods: route["http_methods"],
                request_count: request_count,
                avg_duration_ms: stats["avg_duration_ms"].to_f.round(1),
                error_count: error_count,
                error_rate: request_count > 0 ? ((error_count.to_f / request_count) * 100).round(1) : 0
              }
            end

            {
              period: period,
              routes_with_traffic: result.dig("meta", "total") || endpoints.size,
              endpoints: endpoints,
              summary: build_summary(endpoints),
              next_steps: build_next_steps(endpoints)
            }
          end
        end

        private_class_method def self.build_summary(endpoints)
          return "No request data found for this period." if endpoints.empty?

          slowest = endpoints.first
          parts = [ "Slowest endpoint: #{slowest[:endpoint]} (avg #{slowest[:avg_duration_ms]}ms over #{slowest[:request_count]} requests)" ]

          error_endpoints = endpoints.select { |e| e[:error_rate] > 0 }
          if error_endpoints.any?
            worst = error_endpoints.max_by { |e| e[:error_rate] }
            parts << "Highest error rate: #{worst[:endpoint]} (#{worst[:error_rate]}%)"
          end

          parts.join(". ") + "."
        end

        private_class_method def self.build_next_steps(endpoints)
          return [ "Widen the period or confirm requests are being recorded (rails_pulse_routes with period: \"last_7_days\")." ] if endpoints.empty?

          steps = [ "Pass an endpoint's controller_action to rails_pulse_endpoint for percentiles and recent errors." ]
          steps << "Low-volume endpoints at the top may be one slow hit; raise min_requests to rank by sustained latency." if endpoints.any? { |e| e[:request_count] < 5 }
          steps << "Use rails_pulse_queries with the same period to see whether SQL accounts for the time."
          steps
        end
      end
    end
  end
end
