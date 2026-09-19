module RailsPulse
  module Queries
    module Cards
      class PercentileQueryTimes < RailsPulse::Cards::Base
        def initialize(query: nil, disabled_tags: [], show_non_tagged: true, period: 7, period_type: "day", start_time: nil, end_time: nil)
          @query = query
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @start_time = start_time
          @end_time = end_time
        end

        def to_metric_card
          # Use base class helper for query construction
          base_query = base_summary_query("RailsPulse::Query")

          metrics = base_query.select(
            "SUM(p95_duration * count) / NULLIF(SUM(count), 0) AS overall_p95",
            "SUM(count) AS total_count",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN p95_duration * count ELSE 0 END) / NULLIF(SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN count ELSE 0 END), 0) AS current_p95",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN p95_duration * count ELSE 0 END) / NULLIF(SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN count ELSE 0 END), 0) AS previous_p95"
          ).take

          # Calculate metrics from single query result
          p95_query_time = (metrics.overall_p95 || 0).round(0)
          current_period_p95 = metrics.current_p95 || 0
          previous_period_p95 = metrics.previous_p95 || 0

          baseline = baseline_trend_for(@query, metric: :p95)

          if baseline
            trend_icon, trend_amount, trend_caption = baseline
          elsif show_trend?
            trend_icon, trend_amount = trend_for(current_period_p95, previous_period_p95)
          end

          # Create a query for sparkline data using only the current period
          sparkline_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Query",
              period_type: @period_type,
              period_start: current_window_start..now
            )
          sparkline_query = sparkline_query.where(summarizable_id: @query.id) if @query

          weighted_sums = bucket_by_period(sparkline_query) { |relation| relation.sum("p95_duration * count") }
          period_counts = bucket_by_period(sparkline_query) { |relation| relation.sum(:count) }

          # Calculate weighted averages for each period
          averages_by_period = weighted_sums.each_with_object({}) do |(period, weighted), hash|
            count = period_counts[period].to_i
            hash[period] = count > 0 ? (weighted.to_f / count).round(0) : 0
          end

          # Use base class sparkline generation (handles hour vs day automatically)
          sparkline_data = sparkline_from(averages_by_period)

          {
            id: "percentile_query_times",
            chart_color: RailsPulse::ChartColors::P95,
            context: "queries",
            title: "P95 Query Time",
            summary: format_duration(p95_query_time),
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: trend_caption || (show_trend? ? comparison_period_text : nil),
            period_stat: metrics.total_count.to_i > 0 ? "Across #{format_number(metrics.total_count.to_i)} queries" : period_date_range,
            help_heading: "P95 Query Time",
            help_text: "The 95th percentile database query duration — 95% of queries complete faster than this. Weighted by execution frequency across all queries. Slow queries are often caused by missing indexes or N+1 patterns."
          }
        end
      end
    end
  end
end
