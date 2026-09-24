require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Requests < BaseCommand
      COLUMNS = [
        [ "ID",         10, :id ],
        [ "Status",      6, :status ],
        [ "Duration",   10, :duration ],
        [ "Occurred",   25, :occurred_at ],
        [ "Controller", 35, :controller_action ]
      ].freeze

      desc "list", "List recorded HTTP requests"
      long_desc <<~DESC
        Returns HTTP requests ordered by most recent first.

        Filter by status code or class:
          --status 500      exact code
          --status 5xx      any 5xx response
          --status 4xx      any 4xx response

        Filter by time window (ISO 8601):
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Both --since and --until can be combined.
        Use --json to get the full response envelope including meta.total.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Return requests at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Return requests at or before this time (ISO 8601)"
      option :status, type: :string,                  desc: "Filter by status code or class (e.g. 500, 5xx, 4xx)"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since]  = options[:since]  if options[:since]
          params[:until]  = options[:until]  if options[:until]
          params[:status] = options[:status] if options[:status]
          result = client.get("/requests", params)
          Formatter.render(result, json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
