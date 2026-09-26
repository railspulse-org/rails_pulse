require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Queries < BaseCommand
      COLUMNS = [
        [ "ID",       10, :id ],
        [ "SQL",      60, :normalized_sql ],
        [ "Analyzed", 25, :analyzed_at ]
      ].freeze

      STATS_COLUMNS = [
        [ "ID",     8, :id ],
        [ "SQL",   50, :normalized_sql ],
        [ "Execs",  7, :executions ],
        [ "Avg ms", 8, :avg_duration_ms ],
        [ "Max ms", 8, :max_duration_ms ],
        [ "Total ms", 10, :total_duration_ms ],
        [ "N+1",    5, :max_repetition_count ]
      ].freeze

      desc "list", "List tracked SQL queries"
      long_desc <<~DESC
        Returns normalized SQL queries Rails Pulse has observed, ordered by ID.

        Filter by the time window in which the query was executed (ISO 8601).
        The filter matches against operation timestamps, not the query creation time,
        and adds per-query timing stats for the window:
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Order by a stat (defaults the window to the last 24 hours when --since is omitted):
          --sort total_duration | avg_duration | executions | max_duration

        Use --json to see analysis fields (issues, suggestions, n_plus_one) in full.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Return queries executed at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Return queries executed at or before this time (ISO 8601)"
      option :sort,   type: :string,                  desc: "Order by total_duration, avg_duration, executions, or max_duration"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope and analysis fields"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since] = options[:since] if options[:since]
          params[:until] = options[:until] if options[:until]
          params[:sort]  = options[:sort]  if options[:sort]
          result = client.get("/queries", params)

          if result["data"].any? { |q| q["stats"] }
            rows = result["data"].map { |q| q.merge(q["stats"] || {}) }
            Formatter.render(result.merge("data" => rows), json: options[:json], columns: STATS_COLUMNS)
          else
            Formatter.render(result, json: options[:json], columns: COLUMNS)
          end
        end
      end
    end
  end
end
