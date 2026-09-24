module RailsPulse
  module Queries
    module Charts
      class DatabaseLoad
        def initialize(window:, period_type: :day, disabled_tags: [], show_non_tagged: true)
          @window = window
          @period_type = period_type
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
        end

        def to_chart_data
          step = @period_type.to_s == "hour" ? 3600 : 86400

          # Get query summaries (DB time)
          query_summaries = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Query",
              period_type: @period_type,
              period_start: @window.start_time..@window.end_time
            )

          # Get route summaries (total request time)
          route_summaries = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Route",
              period_type: @period_type,
              period_start: @window.start_time..@window.end_time
            )

          return nil if query_summaries.empty? || route_summaries.empty?

          # Group by period_start timestamp
          query_time_by_period = {}
          query_summaries.each do |summary|
            ts = summary.period_start.to_i
            query_time_by_period[ts] ||= 0
            query_time_by_period[ts] += summary.total_duration || 0
          end

          request_time_by_period = {}
          route_summaries.each do |summary|
            ts = summary.period_start.to_i
            request_time_by_period[ts] ||= 0
            request_time_by_period[ts] += summary.total_duration || 0
          end

          # Build time-axis bar data with per-point colors
          # <25% = green (healthy), 25-40% = yellow (watch), >40% = red (bottleneck)
          bar_data = []

          (@window.start_time.to_i..@window.end_time.to_i).step(step) do |timestamp|
            query_time = query_time_by_period[timestamp] || 0
            request_time = request_time_by_period[timestamp] || 0
            percentage = request_time > 0 ? (query_time.to_f / request_time * 100).round(1) : 0

            color = if percentage < 25
              "rgb(34, 197, 94)"  # green
            elsif percentage < 40
              "rgb(234, 179, 8)"  # yellow
            else
              "rgb(239, 68, 68)"  # red
            end

            bar_data << {
              value: [ timestamp * 1000, percentage ],
              itemStyle: { color: color }
            }
          end

          {
            series: [
              {
                name: "DB Load",
                data: bar_data,
                type: "bar"
              }
            ]
          }
        end
      end
    end
  end
end
