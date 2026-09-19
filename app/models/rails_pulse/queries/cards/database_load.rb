module RailsPulse
  module Queries
    module Cards
      class DatabaseLoad < RailsPulse::Cards::Base
        def initialize(disabled_tags: [], show_non_tagged: true, period: 7, period_type: "day", start_time: nil, end_time: nil)
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @start_time = start_time
          @end_time = end_time
        end

        def to_metric_card
          # Use base class time period helpers
          last_n_units = current_window_start
          previous_n_units = range_start

          # Get query summaries (DB time) - use base class helper pattern
          query_summaries = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Query",
              period_type: @period_type,
              period_start: previous_n_units..now
            )

          # Get route summaries (total request time)
          route_summaries = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Route",
              period_type: @period_type,
              period_start: previous_n_units..now
            )

          # Calculate totals
          total_query_time = query_summaries.sum(:total_duration)
          total_request_time = route_summaries.sum(:total_duration)

          has_data = total_request_time > 0

          overall_db_percentage = has_data ? (total_query_time.to_f / total_request_time * 100).round(1) : 0

          # Calculate current and previous period percentages using base class quote helper
          current_query_time = query_summaries.where("period_start >= ?", last_n_units).sum(:total_duration)
          current_request_time = route_summaries.where("period_start >= ?", last_n_units).sum(:total_duration)
          current_percentage = current_request_time > 0 ? (current_query_time.to_f / current_request_time * 100) : 0

          if show_trend?
            previous_query_time = query_summaries.where("period_start >= ? AND period_start < ?", previous_n_units, last_n_units).sum(:total_duration)
            previous_request_time = route_summaries.where("period_start >= ? AND period_start < ?", previous_n_units, last_n_units).sum(:total_duration)
            previous_percentage = previous_request_time > 0 ? (previous_query_time.to_f / previous_request_time * 100) : 0

            if has_data
              percentage = previous_percentage.zero? ? 0 : ((current_percentage - previous_percentage) / previous_percentage * 100).abs.round(1)
              # For DB load, trending UP is bad (more time in DB), trending DOWN is good
              trend_icon = percentage < 0.1 ? "move-right" : current_percentage > previous_percentage ? "trending-up" : "trending-down"
              trend_amount = previous_percentage.zero? ? "0%" : "#{percentage}%"
            else
              trend_icon = "move-right"
              trend_amount = "—"
            end
          end

          # Sparkline data - group by hour or day depending on period_type
          if period_type_hours?
            start_time = sparkline_hours.first
            end_time = sparkline_hours.last

            # Create separate queries for sparkline data using only the current period
            sparkline_query_summaries = RailsPulse::Summary
              .with_tag_filters(@disabled_tags, @show_non_tagged)
              .where(
                summarizable_type: "RailsPulse::Query",
                period_type: @period_type,
                period_start: start_time..end_time
              )

            sparkline_route_summaries = RailsPulse::Summary
              .with_tag_filters(@disabled_tags, @show_non_tagged)
              .where(
                summarizable_type: "RailsPulse::Route",
                period_type: @period_type,
                period_start: start_time..end_time
              )

            # Group by hour
            hourly_query_time = sparkline_query_summaries.group_by { |s| s.period_start }
              .transform_values { |summaries| summaries.sum { |s| s.total_duration || 0 } }

            hourly_request_time = sparkline_route_summaries.group_by { |s| s.period_start }
              .transform_values { |summaries| summaries.sum { |s| s.total_duration || 0 } }

            sparkline_data = {}
            sparkline_hours.each do |current_time|
              query_time = hourly_query_time[current_time] || 0
              request_time = hourly_request_time[current_time] || 0
              percentage = request_time > 0 ? (query_time.to_f / request_time * 100).round(1) : 0

              # Color based on threshold
              color = if percentage < 25
                "rgb(34, 197, 94)"  # green
              elsif percentage < 40
                "rgb(234, 179, 8)"  # yellow
              else
                "rgb(239, 68, 68)"  # red
              end

              # Use timestamp in milliseconds as key to preserve uniqueness
              sparkline_data[current_time.to_i * 1000] = {
                value: percentage,
                itemStyle: { color: color }
              }
            end
          else
            # Group by day
            daily_query_time = query_summaries.group_by { |s| s.period_start.to_date }
              .transform_values { |summaries| summaries.sum { |s| s.total_duration || 0 } }

            daily_request_time = route_summaries.group_by { |s| s.period_start.to_date }
              .transform_values { |summaries| summaries.sum { |s| s.total_duration || 0 } }

            sparkline_data = {}
            sparkline_dates.each do |day|
              query_time = daily_query_time[day] || 0
              request_time = daily_request_time[day] || 0
              percentage = request_time > 0 ? (query_time.to_f / request_time * 100).round(1) : 0

              # Color based on threshold
              color = if percentage < 25
                "rgb(34, 197, 94)"  # green
              elsif percentage < 40
                "rgb(234, 179, 8)"  # yellow
              else
                "rgb(239, 68, 68)"  # red
              end

              label = day.strftime("%b %-d")
              sparkline_data[label] = {
                value: percentage,
                itemStyle: { color: color }
              }
            end
          end

          {
            id: "database_load",
            context: "queries",
            title: "Database Load",
            summary: has_data ? format_percentage(overall_db_percentage) : "—",
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: period_date_range,
            help_heading: "Database Load",
            help_text: "Percentage of total response time spent executing database queries. <25% is healthy (Ruby/views are the bottleneck, as expected). >40% means your database is your bottleneck — focus on query optimization, indexes, and N+1 elimination."
          }
        end
      end
    end
  end
end
