module RailsPulse
  module Queries
    module Cards
      class AverageQueryTimes < RailsPulse::Cards::Base
        def initialize(query: nil, **kwargs)
          super(subject: query, **kwargs)
        end

        def to_metric_card
          # Use base class helper for query construction
          base_query = base_summary_query("RailsPulse::Query")

          metrics = base_query.select(
            "SUM(avg_duration * count) AS total_weighted_duration",
            "SUM(count) AS total_requests",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN avg_duration * count ELSE 0 END) AS current_weighted_duration",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN count ELSE 0 END) AS current_requests",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN avg_duration * count ELSE 0 END) AS previous_weighted_duration",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN count ELSE 0 END) AS previous_requests"
          ).take

          # Calculate metrics from single query result
          average_query_time = metrics.total_requests.to_i > 0 ? (metrics.total_weighted_duration / metrics.total_requests).round(0) : 0
          current_period_avg = metrics.current_requests.to_i > 0 ? (metrics.current_weighted_duration / metrics.current_requests) : 0
          previous_period_avg = metrics.previous_requests.to_i > 0 ? (metrics.previous_weighted_duration / metrics.previous_requests) : 0

          # Use base class trend calculation
          trend_icon, trend_amount = trend_for(current_period_avg, previous_period_avg) if show_trend?

          # Sparkline data with zero-filled periods
          grouped_weighted = bucket_by_period(base_query) { |relation| relation.sum(Arel.sql("avg_duration * count")) }
          grouped_counts = bucket_by_period(base_query) { |relation| relation.sum(:count) }

          # Calculate weighted averages for each period
          averages_by_period = grouped_weighted.transform_values.with_index do |(weighted, day), _|
            count = grouped_counts[day] || 0
            count > 0 ? (weighted.to_f / count).round(0) : 0
          end

          # Use base class sparkline generation
          sparkline_data = sparkline_from(averages_by_period)

          {
            id: "average_query_times",
            context: "queries",
            title: "Average Query Time",
            summary: format_duration(average_query_time),
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: metrics.total_requests.to_i > 0 ? "Across #{format_number(metrics.total_requests.to_i)} queries" : period_date_range
          }
        end
      end
    end
  end
end
