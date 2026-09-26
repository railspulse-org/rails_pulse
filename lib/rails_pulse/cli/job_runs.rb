require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class JobRuns < BaseCommand
      COLUMNS = [
        [ "ID",       8, :id ],
        [ "Job",     35, :job_name ],
        [ "Status",  10, :status ],
        [ "Occurred", 25, :occurred_at ],
        [ "Duration", 10, :duration ],
        [ "Error",   35, :error_class ]
      ].freeze

      desc "list", "List individual background job runs"
      long_desc <<~DESC
        Returns job runs ordered by most recent first.

        Filter by status:
          --status failed     failed and discarded runs
          --status success    exact status (enqueued, running, success, failed, discarded, retried)

        Filter by job class:
          --job GenerateReportJob

        Filter by time window (ISO 8601):
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Use --json to get error messages and the full response envelope.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Return runs at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Return runs at or before this time (ISO 8601)"
      option :status, type: :string,                  desc: "Filter by status (failed, success, discarded, ...)"
      option :job,    type: :string,                  desc: "Filter by job class name"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since]  = options[:since]  if options[:since]
          params[:until]  = options[:until]  if options[:until]
          params[:status] = options[:status] if options[:status]
          params[:job]    = options[:job]    if options[:job]
          result = client.get("/job_runs", params)
          Formatter.render(result, json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
