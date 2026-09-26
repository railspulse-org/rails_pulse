require_relative "base_command"

module RailsPulse
  module CLI
    class Thresholds < BaseCommand
      desc "show", "Suggest alert thresholds from recent performance data"
      long_desc <<~DESC
        Analyses hourly route summaries and proposes strict, balanced, and relaxed
        thresholds for each alert metric, with a backtest of how many hours each
        would have fired in the analysed window.

        Options:
          --days 14                   Days of history (1–30, default 7)
          --route "POST /checkout"    Scope to one route
          --metric p95_response_time  One of avg_response_time, p95_response_time, error_rate

        Use --json to get the full structured response including ready-to-use rule hashes.
      DESC
      option :days,   type: :numeric, default: 7,     desc: "Days of history to analyse (1–30)"
      option :route,  type: :string,                  desc: "Scope to one route, e.g. \"POST /checkout\""
      option :metric, type: :string,                  desc: "Restrict to one metric"
      option :json,   type: :boolean, default: false, desc: "Output raw JSON"
      def show
        with_error_handling do
          params = { days: options[:days] }
          params[:route]  = options[:route]  if options[:route]
          params[:metric] = options[:metric] if options[:metric]

          result = client.get("/threshold_suggestions", params)

          if options[:json]
            puts JSON.pretty_generate(result)
          else
            render_suggestions(result)
          end
        end
      end

      private

      def render_suggestions(data)
        window = data["window"] || {}
        scope  = data["scope"] || {}

        say ""
        say "Threshold suggestions — last #{window["days"]} days" \
            "#{scope["resource_identifier"] ? " for #{scope["resource_identifier"]}" : ""}", :bold
        say "#{window["hours_with_data"]} of #{window["expected_hours"]} hours have data, #{window["total_requests"]} requests"

        (data["metrics"] || []).each do |metric|
          say ""
          say metric["metric"].to_s.upcase, :bold
          if metric["insufficient_data"]
            say "  insufficient data (#{metric["hours_with_data"]} hours) — needs at least 24 hours of summaries", :yellow
          end
          next if metric["tiers"].to_a.empty?

          obs = metric["observed"]
          say "  observed: median #{obs["median"]}#{metric["unit"]}, p95 #{obs["p95"]}#{metric["unit"]}, max #{obs["max"]}#{metric["unit"]}"
          metric["tiers"].each do |tier|
            say "  #{tier["name"].ljust(9)} > #{tier["threshold"].to_s.ljust(8)}#{metric["unit"].ljust(3)}" \
                "would have fired #{tier["would_have_fired"]} times (~#{tier["fires_per_week"]}/week)"
          end
        end
        say ""
      end
    end
  end
end
