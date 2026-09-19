module RailsPulse
  module Queries
    module Cards
      class ExecutionRate < RailsPulse::Cards::Base
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
            "SUM(count) AS total_count",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN count ELSE 0 END) AS current_count",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN count ELSE 0 END) AS previous_count"
          ).take

          # Calculate metrics from single query result
          total_execution_count = metrics.total_count || 0
          current_period_count = metrics.current_count || 0
          previous_period_count = metrics.previous_count || 0

          # Use base class trend calculation
          trend_icon, trend_amount = trend_for(current_period_count, previous_period_count) if show_trend?

          # Create a query for sparkline data using only the current period
          sparkline_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Query",
              period_type: @period_type,
              period_start: current_window_start..now
            )
          sparkline_query = sparkline_query.where(summarizable_id: @query.id) if @query

          if period_type_hours?
            grouped_data = sparkline_query.group_by_hour(:period_start).sum(:count)
          else
            grouped_data = sparkline_query.group_by_date(:period_start).sum(:count)
          end

          # Use base class sparkline generation (handles hour vs day automatically)
          sparkline_data = sparkline_from(grouped_data)

          # Calculate appropriate rate display based on frequency
          total_minutes = (period_type_hours? ? (@period * 24).hours : (@period * 2).days) / 1.minute.to_f
          executions_per_minute = total_execution_count.to_f / total_minutes

          # Choose appropriate time unit for display
          if executions_per_minute >= 1
            summary = "#{executions_per_minute.round(2)} / min"
          elsif executions_per_minute * 60 >= 1
            executions_per_hour = executions_per_minute * 60
            summary = "#{executions_per_hour.round(2)} / hour"
          else
            executions_per_day = executions_per_minute * 60 * 24
            summary = "#{executions_per_day.round(2)} / day"
          end

          {
            id: "execution_rate",
            context: "queries",
            title: "Execution Rate",
            summary: summary,
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: total_execution_count > 0 ? "#{format_number(total_execution_count)} executions" : period_date_range,
            help_heading: "Query Execution Rate",
            help_text: "Total database queries executed over the last 14 days, expressed as an average rate. Spikes may indicate N+1 queries or inefficient data access patterns."
          }
        end
      end
    end
  end
end
