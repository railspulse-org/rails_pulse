require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Routes < BaseCommand
      COLUMNS = [
        [ "Method",   8, :http_methods ],
        [ "Path",    40, :path ],
        [ "Action",  35, :controller_action ],
        [ "Created", 25, :created_at ]
      ].freeze

      STATS_COLUMNS = [
        [ "Method",    8, :http_methods ],
        [ "Path",     40, :path ],
        [ "Action",   35, :controller_action ],
        [ "Requests",  8, :request_count ],
        [ "Avg ms",    8, :avg_duration_ms ],
        [ "Errors",    6, :error_count ]
      ].freeze

      desc "list", "List all tracked HTTP routes"
      long_desc <<~DESC
        Returns every route Rails Pulse has recorded, ordered by path.

        Search by path or controller action (case-insensitive substring):
          --search checkout

        Add request stats for a time window (ISO 8601). Only routes with traffic
        in the window are returned, ordered by request count:
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Order stats by another column (defaults the window to the last 24 hours when --since is omitted):
          --sort request_count | avg_duration | error_count

        Use --limit and --offset to paginate through large route sets.
        Use --json to get the full response envelope including meta.total.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Include request stats at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Include request stats at or before this time (ISO 8601)"
      option :search, type: :string,                  desc: "Filter by path or controller action substring"
      option :sort,   type: :string,                  desc: "Order stats by request_count, avg_duration, or error_count"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since]  = options[:since]  if options[:since]
          params[:until]  = options[:until]  if options[:until]
          params[:search] = options[:search] if options[:search]
          params[:sort]   = options[:sort]   if options[:sort]
          result = client.get("/routes", params)

          rows = result["data"].map do |route|
            route.merge("http_methods" => Array(route["http_methods"]).join("|")).merge(route["stats"] || {})
          end
          columns = result["data"].any? { |r| r["stats"] } ? STATS_COLUMNS : COLUMNS
          Formatter.render(result.merge("data" => rows), json: options[:json], columns: columns)
        end
      end
    end
  end
end
