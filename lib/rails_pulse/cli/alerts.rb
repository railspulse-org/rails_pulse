require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Alerts < BaseCommand
      COLUMNS = [
        [ "Rule",      30, :rule_name ],
        [ "Value",     12, :triggered_value ],
        [ "Triggered", 25, :triggered_at ],
        [ "Message",   50, :message ]
      ].freeze

      desc "list", "List fired alert events"
      long_desc <<~DESC
        Returns alert events (rule trigger instances) ordered by most recent first.

        Filter by rule name (exact match against the name defined in your config):
          --rule "High P95 Response Time"

        Filter by time window (ISO 8601):
          --since 2026-06-01T00:00:00Z
          --until 2026-06-01T23:59:59Z

        Both --since and --until can be combined.
        Use --json to get the full response envelope including meta.total.
      DESC
      option :limit,  type: :numeric, default: 25,    desc: "Max records to return (1–500)"
      option :offset, type: :numeric, default: 0,     desc: "Number of records to skip (for pagination)"
      option :since,  type: :string,                  desc: "Return events triggered at or after this time (ISO 8601)"
      option :until,  type: :string,                  desc: "Return events triggered at or before this time (ISO 8601)"
      option :rule,   type: :string,                  desc: "Filter by exact rule name (e.g. \"High P95 Response Time\")"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON including meta envelope"
      def list
        with_error_handling do
          params = { limit: options[:limit], offset: options[:offset] }
          params[:since] = options[:since] if options[:since]
          params[:until] = options[:until] if options[:until]
          params[:rule]  = options[:rule]  if options[:rule]
          result = client.get("/alerts", params)
          Formatter.render(result, json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
