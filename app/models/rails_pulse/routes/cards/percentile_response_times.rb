module RailsPulse
  module Routes
    module Cards
      class PercentileResponseTimes < RailsPulse::Cards::Base
        def initialize(route: nil, **kwargs)
          super(subject: route, **kwargs)
        end

        def to_metric_card
          # Use base class helper for query construction
          base_query = base_summary_query("RailsPulse::Route")

          metrics = base_query.select(
            "SUM(p95_duration * count) / NULLIF(SUM(count), 0) AS overall_p95",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN p95_duration * count ELSE 0 END) / NULLIF(SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN count ELSE 0 END), 0) AS current_p95",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN p95_duration * count ELSE 0 END) / NULLIF(SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN count ELSE 0 END), 0) AS previous_p95",
            "SUM(count) AS total_count"
          ).take

          # Calculate metrics from single query result
          p95_response_time = (metrics&.overall_p95 || 0).round(0)
          current_period_p95 = metrics&.current_p95 || 0
          previous_period_p95 = metrics&.previous_p95 || 0

          has_data = metrics.total_count.to_i > 0

          # Prefer a comparison against this route's own history; fall back to
          # period-over-period on the index, where there is no single subject.
          baseline = baseline_trend_for(@subject, metric: :p95)

          if baseline
            trend_icon, trend_amount, trend_caption = baseline
          elsif show_trend?
            trend_icon, trend_amount = has_data ? trend_for(current_period_p95, previous_period_p95) : [ "move-right", "—" ]
          end

          # Build sparkline data using base class helpers
          sparkline_query = build_sparkline_query("RailsPulse::Route")
          weighted_sums = group_sparkline_by_period(sparkline_query, "p95_duration * count")
          period_counts = group_sparkline_by_period(sparkline_query, :count)

          # Calculate weighted averages for each period
          averages_by_period = weighted_sums.each_with_object({}) do |(period, weighted), hash|
            count = period_counts[period].to_i
            hash[period] = count > 0 ? (weighted.to_f / count).round(0) : 0
          end

          # Use base class sparkline generation (handles hour vs day automatically)
          sparkline_data = sparkline_from(averages_by_period)

          {
            id: "percentile_response_times",
            chart_color: RailsPulse::ChartColors::P95,
            context: "routes",
            title: "P95 Response Time",
            summary: has_data ? "#{p95_response_time} ms" : "—",
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: trend_caption || (show_trend? ? comparison_period_text : nil),
            period_stat: has_data ? "Across #{format_number(metrics.total_count.to_i)} requests" : period_date_range,
            help_heading: "P95 Response Time",
            help_text: "The 95th percentile response time — 95% of requests are faster than this. Weighted by request volume across all routes. A rising P95 indicates increasing slowness affecting your users."
          }
        end
      end
    end
  end
end
