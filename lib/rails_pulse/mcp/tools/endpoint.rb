require "json"

module RailsPulse
  module Mcp
    module Tools
      class Endpoint < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_endpoint"
        description "Detailed performance profile for a single endpoint. " \
                    "Combines request metrics, latency distribution, and error information. " \
                    "Use this to deep-dive into a specific route's performance."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            endpoint: {
              type: "string",
              description: "Controller action (e.g. 'CheckoutController#create') or path (e.g. '/checkout'). " \
                           "If unknown, use rails_pulse_routes first to find endpoint names."
            },
            period: {
              type: "string",
              description: "Time period: 'last_hour', 'last_24_hours', 'last_7_days', or ISO 8601 timestamp for 'since'",
              default: "last_7_days"
            },
            limit: {
              type: "integer",
              description: "Maximum requests to analyze (1-500). More data = more accurate percentiles.",
              default: 200
            }
          },
          required: [ "endpoint" ]
        )

        def self.call(endpoint:, period: "last_7_days", limit: 200, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 500)

            params = { limit: limit, offset: 0 }
            params[:since] = resolve_since(period)

            result = client.get("/requests", params)
            all_requests = result["data"] || []

            # Filter to matching endpoint (by controller_action or path-like match)
            matching = all_requests.select { |r| matches_endpoint?(r, endpoint) }

            if matching.empty?
              {
                endpoint: endpoint,
                period: period,
                error: "No requests found matching '#{endpoint}'. Use rails_pulse_routes to see available endpoints."
              }
            else
              build_profile(endpoint, period, matching)
            end
          end
        end

        private_class_method def self.matches_endpoint?(request, endpoint)
          action = request["controller_action"].to_s
          return true if action == endpoint
          return true if action.downcase.include?(endpoint.downcase)

          # Match path-like input against controller action
          path = request["path"].to_s
          return true if path == endpoint
          return true if path.downcase.include?(endpoint.downcase.delete_prefix("/"))

          false
        end

        private_class_method def self.build_profile(endpoint, period, requests)
          durations = requests.map { |r| r["duration"].to_f }.sort
          errors = requests.select { |r| r["is_error"] }
          statuses = requests.map { |r| r["status"] }.tally.sort_by { |_, c| -c }
          sorted_by_time = requests.sort_by { |r| r["occurred_at"].to_s }

          profile = {
            endpoint: requests.first["controller_action"] || endpoint,
            period: period,
            request_count: requests.size,
            latency: {
              avg_ms: (durations.sum / durations.size).round(1),
              min_ms: durations.first.round(1),
              max_ms: durations.last.round(1),
              p50_ms: percentile(durations, 50).round(1),
              p95_ms: percentile(durations, 95).round(1),
              p99_ms: percentile(durations, 99).round(1)
            },
            errors: {
              count: errors.size,
              rate: ((errors.size.to_f / requests.size) * 100).round(1)
            },
            status_distribution: statuses.map { |code, count| { status: code, count: count } },
            time_range: {
              first_request: sorted_by_time.first&.dig("occurred_at"),
              last_request: sorted_by_time.last&.dig("occurred_at")
            }
          }

          # Add recent errors detail if any
          if errors.any?
            profile[:recent_errors] = errors.sort_by { |r| r["occurred_at"].to_s }.reverse.first(5).map do |r|
              {
                status: r["status"],
                duration_ms: r["duration"].to_f.round(1),
                occurred_at: r["occurred_at"]
              }
            end
          end

          profile[:summary] = build_summary(profile)
          profile[:next_steps] = build_next_steps(profile)
          profile
        end

        private_class_method def self.build_summary(profile)
          parts = []
          parts << "#{profile[:request_count]} requests"
          parts << "avg #{profile[:latency][:avg_ms]}ms (p95: #{profile[:latency][:p95_ms]}ms)"
          parts << "#{profile[:errors][:rate]}% error rate" if profile[:errors][:count] > 0
          parts.join(", ") + "."
        end

        private_class_method def self.build_next_steps(profile)
          steps = []
          if profile[:latency][:p95_ms] > 1000
            steps << "P95 latency is over 1s — investigate slow database queries or N+1s in the controller."
          end
          if profile[:latency][:p95_ms] > profile[:latency][:avg_ms] * 3
            steps << "High p95/avg ratio suggests occasional very slow requests — look for intermittent issues."
          end
          if profile[:errors][:rate] > 5
            steps << "Error rate is above 5% — check recent_errors and investigate the failure pattern."
          end
          steps << "Use rails_pulse_errors to see error details for this endpoint." if profile[:errors][:count] > 0
          steps << "Inspect the controller source code and associated SQL queries for optimization opportunities."
          steps
        end
      end
    end
  end
end
