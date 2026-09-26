require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Jobs < BaseCommand
      COLUMNS = [
        [ "Name",     35, :name ],
        [ "Queue",    15, :queue_name ],
        [ "Runs",      8, :runs_count ],
        [ "Failures",  8, :failures_count ],
        [ "Fail %",    8, :failure_rate ],
        [ "Avg (ms)", 10, :avg_duration ]
      ].freeze

      desc "list", "List background jobs with run counts and duration stats"
      long_desc <<~DESC
        Returns all tracked background jobs ordered by name.

        Each row shows lifetime stats: total runs, failure count, failure rate (%),
        and average duration in milliseconds.

        Filter to only jobs that have failed at least once:
          --status failed

        Use --json to also see p95 and p99 duration percentiles.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :status, type: :string,                  desc: "Filter by status — 'failed' returns only jobs with failures"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope and p95/p99 durations"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:status] = options[:status] if options[:status]
          result = client.get("/jobs", params)
          Formatter.render(result, json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
