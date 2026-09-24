require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Deployments < BaseCommand
      COLUMNS = [
        [ "Revision",   14, :short_revision ],
        [ "Started",    25, :started_at ],
        [ "Finished",   25, :finished_at ],
        [ "Regression", 18, :regression_outcome ]
      ].freeze

      desc "list", "List recorded deployments"
      long_desc <<~DESC
        Returns deployments ordered by most recent first. With Rails Pulse Pro each row
        also shows the outcome of the automatic regression check: triggered, clean,
        insufficient_data, or unchecked (not evaluated yet, or Pro not installed).

        Filter by time window (ISO 8601):
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Use --json to get per-metric regression results and deployment metadata.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Return deployments started at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Return deployments started at or before this time (ISO 8601)"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since] = options[:since] if options[:since]
          params[:until] = options[:until] if options[:until]
          result = client.get("/deployments", params)
          rows = result["data"].map do |d|
            d.merge("regression_outcome" => d["regression"] ? d["regression"]["outcome"] : "unchecked")
          end
          Formatter.render(result.merge("data" => rows), json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
