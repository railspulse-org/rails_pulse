require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class Summary < BaseCommand
      desc "show", "Show the performance summary for a period"
      long_desc <<~DESC
        Returns a full performance summary: headline stats, slowest routes and queries,
        background jobs, needs-attention insights, fired alerts, and config recommendations.

        Select the period type:
          --period week    Weekly summary (default)
          --period month   Monthly summary

        Navigate to a specific period using any date within it:
          --from 2026-05-26

        Defaults to the last completed period (last week or last month).

        Use --json to get the full structured response — ideal for piping to an AI agent:
          rails-pulse summary show --json | claude "analyse this and suggest fixes"
      DESC
      option :period, type: :string,  default: "week",  desc: "Period type: week or month"
      option :from,   type: :string,                    desc: "Any date within the target period (YYYY-MM-DD)"
      option :json,   type: :boolean, default: false,   desc: "Output raw JSON"
      def show
        with_error_handling do
          params = { period: options[:period] }
          params[:from] = options[:from] if options[:from]

          result = client.get("/summary", params)

          if options[:json]
            puts JSON.pretty_generate(result)
          else
            render_summary(result)
          end
        end
      end

      private

      def render_summary(data)
        period  = data["period"]
        ov      = data["overview"] || {}
        vs_prev = ov["vs_previous"] || {}

        say ""
        say "#{period["label"]}  (#{period["type"]})", :bold
        say "═" * 52

        # Overview
        say ""
        say "OVERVIEW", :bold
        if ov["total_requests"].nil?
          # The period has no summary rows: nothing was tracked, or
          # SummaryJob has not run for it yet.
          say "  No summary data for this period. Summaries are built by RailsPulse::SummaryJob;", :yellow
          say "  run `rails rails_pulse:backfill_summaries` to build them for past traffic.", :yellow
        else
          render_stat "P95 Response Time", "#{ov["p95_ms"]} ms",
                      vs_prev["p95_ms"] ? "#{ov["p95_ms"]} ms vs #{vs_prev["p95_ms"]} ms" : nil,
                      vs_prev["p95_delta_pct"]
          render_stat "Avg Response Time",  "#{ov["avg_ms"]} ms"
          render_stat "Total Requests",     ov["total_requests"].to_s,
                      vs_prev["total_requests"] ? "from #{vs_prev["total_requests"]}" : nil,
                      vs_prev["total_delta_pct"]
          render_stat "Error Rate",         "#{ov["error_rate_pct"]}%  (#{ov["error_count"]} errors)",
                      vs_prev["error_rate_pct"] ? "from #{vs_prev["error_rate_pct"]}%" : nil,
                      vs_prev["error_rate_delta_pct"]
        end

        # Needs Attention
        insights = data["insights"] || {}
        if insights["total"].to_i > 0
          say ""
          say "NEEDS ATTENTION  (#{insights["total"]} issues)", :bold
          render_insight_group "CRITICAL", insights["critical"] || [], :red
          render_insight_group "WARNING",  insights["warning"]  || [], :yellow
        end

        # Slowest Routes
        routes = data["slowest_routes"] || []
        unless routes.empty?
          say ""
          say "SLOWEST ROUTES  (by P95)", :bold
          routes.first(5).each do |r|
            delta = r["prev_p95_delta_pct"] ? "  #{trend_arrow(r["prev_p95_delta_pct"])}#{r["prev_p95_delta_pct"].abs}%" : ""
            say "  #{r["route"].to_s.ljust(35)}  avg #{r["avg_ms"]}ms  P95 #{r["p95_ms"]}ms  errors: #{r["error_count"]}#{delta}"
          end
        end

        # Slowest Queries
        queries = data["slowest_queries"] || []
        unless queries.empty?
          say ""
          say "SLOWEST QUERIES  (by total time)", :bold
          queries.first(5).each do |q|
            sql = q["sql"].to_s.gsub(/\s+/, " ").strip
            sql = sql.length > 60 ? "#{sql[0..59]}…" : sql
            say "  #{sql.ljust(62)}  #{q["executions"]} exec  P95 #{q["p95_ms"]}ms"
          end
        end

        # Jobs
        jobs = data["job_summaries"] || []
        unless jobs.empty?
          say ""
          say "BACKGROUND JOBS", :bold
          jobs.each do |j|
            failures = j["failures"].to_i > 0 ? "  ✗ #{j["failures"]} failures" : ""
            say "  #{j["name"].to_s.ljust(40)}  #{j["runs"]} runs  P95 #{j["p95_ms"]}ms#{failures}"
          end
        end

        # Alerts
        alerts = data["alert_events"] || []
        say ""
        say "ALERTS  (#{alerts.size} fired this #{period["type"]})", :bold
        if alerts.empty?
          say "  All clear — no alerts fired."
        else
          alerts.first(5).each do |a|
            say "  #{a["rule"].to_s.ljust(32)}  #{a["value"]}  #{a["triggered_at"]}"
          end
          say "  … and #{alerts.size - 5} more" if alerts.size > 5
        end

        # Recommendations
        recs = data["recommendations"] || []
        unless recs.empty?
          say ""
          say "CONFIG RECOMMENDATIONS", :bold
          recs.each do |rec|
            say ""
            say "  ⚠  #{rec["title"]}", :yellow
            say "     #{rec["detail"]}"
            say "     #{rec["config_snippet"]}"
          end
        end

        say ""
      end

      def render_stat(label, value, context = nil, delta = nil)
        line = "  #{label.ljust(22)}  #{value}"
        line += "  (#{trend_arrow(delta)}#{delta.abs}% #{context})" if delta
        say line
      end

      def render_insight_group(label, items, color)
        return if items.empty?

        say "  #{label}", color
        items.each do |item|
          say "    #{item["type"].to_s.ljust(6)}  #{item["name"]}  —  #{item["reason"]}"
        end
      end

      def trend_arrow(delta)
        return "" if delta.nil?

        delta > 0 ? "↑" : "↓"
      end
    end
  end
end
