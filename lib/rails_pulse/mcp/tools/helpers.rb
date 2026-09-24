require "json"
require "time"

module RailsPulse
  module Mcp
    module Tools
      module Helpers
        PERIODS = {
          "last_hour" => 3600,
          "last_24_hours" => 86_400,
          "last_7_days" => 604_800
        }.freeze

        FREE_TOOLS = %w[
          rails_pulse_routes rails_pulse_slow_requests rails_pulse_errors rails_pulse_endpoint
          rails_pulse_queries rails_pulse_jobs rails_pulse_deployments
        ].freeze

        def resolve_since(period)
          seconds = PERIODS[period]
          seconds ? (Time.now - seconds).iso8601 : period
        end

        def percentile(sorted, pct)
          return 0 if sorted.empty?
          k = ((pct / 100.0) * (sorted.size - 1)).ceil
          sorted[k]
        end

        def truncate(str, length)
          str = str.to_s
          str.length > length ? "#{str[0, length]}..." : str
        end

        def respond(server_context)
          payload = yield server_context[:client]
          ::MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
        rescue CLI::Client::ProRequiredError => e
          # Not an error from the agent's point of view: the answer is "this
          # needs Pro", which it should relay rather than retry.
          ::MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(pro_required_payload(e)) } ])
        rescue CLI::Client::ApiError => e
          ::MCP::Tool::Response.new([ { type: "text", text: "Error querying Rails Pulse: #{e.message}" } ], error: true)
        end

        def pro_required_payload(error)
          {
            requires_pro: true,
            feature: error.feature,
            message: error.message,
            url: error.url,
            next_steps: [
              "This tool needs Rails Pulse Pro installed in the application. Tell the user what it would have provided and where to read more; do not retry.",
              "Continue with the tools that work without Pro: #{FREE_TOOLS.join(', ')}."
            ]
          }
        end
      end
    end
  end
end
