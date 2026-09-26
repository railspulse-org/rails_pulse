module RailsPulse
  module Mcp
    module Tools
      class Deployments < ::MCP::Tool
        extend Helpers

        tool_name "rails_pulse_deployments"
        description "Recent deployments, with the automatic regression-check outcome (triggered, clean, " \
                    "insufficient_data, or unchecked) when the regression extension is installed. Use this to pin an " \
                    "investigation to a deploy time or to see whether a release made things worse."

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
            limit: {
              type: "integer",
              description: "Maximum number of deployments (1-100)",
              default: 10
            }
          }
        )

        def self.call(period: "last_7_days", limit: 10, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 100)
            result = client.get("/deployments", { since: resolve_since(period), limit: limit })
            deployments = (result["data"] || []).map { |d| format_deployment(d) }

            {
              period: period,
              total_deployments: result.dig("meta", "total") || deployments.size,
              deployments: deployments,
              summary: build_summary(deployments),
              next_steps: build_next_steps(deployments)
            }
          end
        end

        private_class_method def self.format_deployment(deployment)
          regression = deployment["regression"]
          {
            revision: deployment["revision"],
            short_revision: deployment["short_revision"],
            started_at: deployment["started_at"],
            finished_at: deployment["finished_at"],
            duration_seconds: deployment["duration_seconds"],
            in_progress: deployment["in_progress"] == true,
            regression_outcome: regression ? regression["outcome"] : "unchecked",
            regression: regression,
            metadata: deployment["metadata"]
          }
        end

        private_class_method def self.build_summary(deployments)
          return "No deployments recorded in this period." if deployments.empty?

          regressed = deployments.count { |d| d[:regression_outcome] == "triggered" }
          latest = deployments.first
          parts = [ "#{deployments.size} deployment(s), #{regressed} with a detected regression" ]
          parts << "Latest: #{latest[:short_revision]} at #{latest[:started_at]} (#{latest[:regression_outcome]})"
          parts.join(". ") + "."
        end

        private_class_method def self.build_next_steps(deployments)
          steps = []
          if deployments.empty?
            steps << "Record deployments via `rails_pulse:record_deployment` or POST /deployments so regressions can be checked."
            return steps
          end

          deployments.select { |d| d[:regression_outcome] == "triggered" }.each do |d|
            metrics = Array(d.dig(:regression, "results")).select { |r| r["outcome"] == "triggered" }.map { |r| r["metric"] }
            steps << "#{d[:short_revision]} regressed (#{metrics.join(', ')}): call rails_pulse_slow_requests and rails_pulse_errors " \
                     "with period: \"#{d[:started_at]}\" and compare against the previous deploy."
          end
          if deployments.any? { |d| d[:regression_outcome] == "insufficient_data" }
            steps << "Some deploys had insufficient traffic for a regression check — compare manually with rails_pulse_request_stats."
          end
          if deployments.all? { |d| d[:regression_outcome] == "unchecked" }
            steps << "No regression checks recorded: deployment regression detection comes from an extension. " \
                     "Compare rails_pulse_slow_requests and rails_pulse_errors before and after a deploy's started_at instead."
          elsif deployments.any? { |d| d[:regression_outcome] == "unchecked" }
            steps << "Unchecked deploys are evaluated by RailsPulseProJob once the post-deploy window elapses."
          end
          steps
        end
      end
    end
  end
end
