require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Insights < BaseCommand
      PERIODS = %w[hour day week month].freeze

      desc "show", "What needs attention over one period, and whether the thresholds fit it"
      long_desc <<~DESC
        Reads one summary period (an hour, day, week or month) and lists the routes, queries
        and jobs past their slow or critical thresholds, critical first, ten at most. Then
        checks route_thresholds, query_thresholds and job_thresholds against the period's
        slowest routes and jobs and most expensive queries, and suggests an initializer line when a slow threshold is
        exceeded by most of them or a critical threshold is never approached.

        Defaults to the last complete week. --at picks the period containing that time:
          --period day --at 2026-06-10T00:00:00Z

        Use --json for the full structure, including record ids and current thresholds.
      DESC
      option :period, type: :string, default: "week", enum: PERIODS, desc: "Summary period to read"
      option :at,     type: :string,                                   desc: "A time inside the period (ISO 8601); default the last complete one"
      option :json,   type: :boolean, default: false,                  desc: "Output raw JSON"
      def show
        with_error_handling do
          params = { period: options[:period] }
          params[:at] = options[:at] if options[:at]
          data = client.get("/insights", params)
          next say(JSON.pretty_generate(data)) if options[:json]

          print_period(data["period"] || {})
          print_attention(data["needs_attention"] || {})
          print_recommendations(data["threshold_recommendations"] || [])
        end
      end

      private

      def print_period(period)
        say "#{period['type'].to_s.capitalize} from #{period['start']} to #{period['end']}"
        say "  not fully summarized yet — what follows may be incomplete" unless period["summarized"]
        say ""
      end

      def print_attention(attention)
        say "Needs attention"
        items = Array(attention["critical"]) + Array(attention["warning"])
        return say("  nothing past its thresholds") if items.empty?

        items.each do |item|
          say "  #{item['severity'].to_s.upcase.ljust(8)} #{item['type'].to_s.ljust(5)} #{item['name']}"
          say "           #{item['reason']}"
        end
      end

      def print_recommendations(recommendations)
        say ""
        say "Threshold recommendations"
        return say("  none — the thresholds fit this period") if recommendations.empty?

        recommendations.each do |rec|
          say "  #{rec['title']}"
          say "    #{rec['detail']}"
          say "    #{rec['config_snippet']}"
        end
      end
    end
  end
end
