module RailsPulse
  module Mcp
    module Tools
      class Jobs < ::MCP::Tool
        extend Helpers

        ERROR_MESSAGE_LENGTH = 200

        tool_name "rails_pulse_jobs"
        description "Background job health: failure rates, slow jobs, and recent failures with error classes. " \
                    "Use this to find failing or slow background jobs."

        annotations(
          read_only_hint: true,
          destructive_hint: false,
          open_world_hint: false
        )

        input_schema(
          properties: {
            period: {
              type: "string",
              description: "Time period for recent failures: 'last_hour', 'last_24_hours', 'last_7_days', or ISO 8601 timestamp",
              default: "last_24_hours"
            },
            limit: {
              type: "integer",
              description: "Maximum number of jobs to return (1-50)",
              default: 10
            },
            job: {
              type: "string",
              description: "Restrict to one job class (e.g. 'GenerateReportJob')"
            }
          }
        )

        def self.call(period: "last_24_hours", limit: 10, job: nil, server_context:)
          respond(server_context) do |client|
            limit = limit.to_i.clamp(1, 50)

            job_params = { limit: 100 }
            job_params[:job] = job if job
            jobs = client.get("/jobs", job_params)["data"] || []

            run_params = { since: resolve_since(period), status: "failed", limit: 100 }
            run_params[:job] = job if job
            failed_runs = client.get("/job_runs", run_params)["data"] || []

            formatted = jobs.map { |j| format_job(j) }
              .sort_by { |j| [ -j[:failure_rate].to_f, -j[:p95_ms].to_f ] }
              .first(limit)

            {
              period: period,
              jobs: formatted,
              recent_failures: format_failures(failed_runs),
              note: "Job counts and durations are all-time aggregates; recent_failures is limited to the period.",
              summary: build_summary(formatted, failed_runs),
              next_steps: build_next_steps(formatted, failed_runs)
            }
          end
        end

        private_class_method def self.format_job(job)
          {
            name: job["name"],
            queue: job["queue_name"],
            runs: job["runs_count"],
            failures: job["failures_count"],
            failure_rate: job["failure_rate"].to_f.round(1),
            avg_ms: job["avg_duration"].to_f.round(1),
            p95_ms: job["p95_duration"].to_f.round(1),
            p99_ms: job["p99_duration"].to_f.round(1)
          }
        end

        private_class_method def self.format_failures(runs)
          runs.group_by { |r| r["job_name"] || "unknown" }.map do |name, group|
            latest = group.max_by { |r| r["occurred_at"].to_s }
            {
              job: name,
              count: group.size,
              error_classes: group.map { |r| r["error_class"] || "unknown" }.tally,
              latest: {
                occurred_at: latest["occurred_at"],
                error_class: latest["error_class"],
                error_message: truncate(latest["error_message"], ERROR_MESSAGE_LENGTH),
                attempts: latest["attempts"]
              }
            }
          end.sort_by { |f| -f[:count] }
        end

        private_class_method def self.build_summary(jobs, failed_runs)
          return "No background jobs recorded." if jobs.empty?

          parts = [ "#{jobs.size} job(s), #{failed_runs.size} failed run(s) in period" ]
          worst = jobs.max_by { |j| j[:failure_rate] }
          parts << "Highest failure rate: #{worst[:name]} (#{worst[:failure_rate]}%)" if worst[:failure_rate] > 0
          slowest = jobs.max_by { |j| j[:p95_ms] }
          parts << "Slowest: #{slowest[:name]} (p95 #{slowest[:p95_ms]}ms)" if slowest
          parts.join(". ") + "."
        end

        private_class_method def self.build_next_steps(jobs, failed_runs)
          steps = []
          if jobs.empty?
            steps << "No jobs tracked — confirm `config.track_jobs` is enabled in the Rails Pulse initializer."
          end
          if failed_runs.any?
            steps << "Group failures by error_class in recent_failures; a single class dominating usually points at one root cause."
          end
          if jobs.any? { |j| j[:failure_rate] > 5 }
            steps << "Jobs with failure rate above 5% need retry/discard handling reviewed."
          end
          if jobs.any? { |j| j[:p95_ms] > 60_000 }
            steps << "Jobs with p95 over 60s may be blocking queues — consider splitting or batching."
          end
          steps << "Use rails_pulse_queries to check whether slow jobs are dominated by SQL."
          steps
        end
      end
    end
  end
end
