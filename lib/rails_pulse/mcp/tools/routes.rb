module RailsPulse
  module Mcp
    module Tools
      class Routes < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_routes"
        description "List the application's tracked routes/endpoints with request volume, average latency, and error " \
                    "counts for a period. Use this to discover endpoint names before calling rails_pulse_endpoint."

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
            search: {
              type: "string",
              description: "Case-insensitive substring match on path or controller action (e.g. 'checkout')"
            },
            limit: {
              type: "integer",
              description: "Maximum number of routes (1-100)",
              default: 50
            },
            sort: {
              type: "string",
              description: "Order by 'request_count' (default), 'avg_duration', or 'error_count'",
              default: "request_count"
            }
          }
        )

        def self.call(period: "last_7_days", search: nil, limit: 50, sort: "request_count", server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 100)

            params = { since: resolve_since(period), sort: sort, limit: limit }
            params[:search] = search if search
            result = client.get("/routes", params)

            routes = (result["data"] || []).map { |r| format_route(r) }
            routes.select! { |r| matches?(r, search) } if search

            {
              period: period,
              sort: sort,
              total_routes: result.dig("meta", "total") || routes.size,
              routes: routes,
              summary: build_summary(routes, search),
              next_steps: [
                "Pass a route's controller_action (e.g. 'CheckoutController#create') to rails_pulse_endpoint for a full profile.",
                "Routes with traffic but no controller_action are usually engine or Rack endpoints."
              ]
            }
          end
        end

        private_class_method def self.format_route(route)
          stats = route["stats"] || {}
          {
            id: route["id"],
            http_methods: route["http_methods"],
            path: route["path"],
            controller_action: route["controller_action"],
            request_count: stats["request_count"],
            avg_duration_ms: stats["avg_duration_ms"],
            error_count: stats["error_count"],
            tags: route["tags"]
          }
        end

        private_class_method def self.matches?(route, search)
          term = search.downcase
          route[:path].to_s.downcase.include?(term) || route[:controller_action].to_s.downcase.include?(term)
        end

        private_class_method def self.build_summary(routes, search)
          if routes.empty?
            return search ? "No routes matching '#{search}' had traffic in this period." : "No routes had traffic in this period."
          end

          busiest = routes.max_by { |r| r[:request_count].to_i }
          parts = [ "#{routes.size} route(s) with traffic" ]
          parts << "Busiest: #{busiest[:controller_action] || busiest[:path]} (#{busiest[:request_count]} requests)"
          slowest = routes.max_by { |r| r[:avg_duration_ms].to_f }
          parts << "Slowest: #{slowest[:controller_action] || slowest[:path]} (avg #{slowest[:avg_duration_ms]}ms)" if slowest
          parts.join(". ") + "."
        end
      end
    end
  end
end
