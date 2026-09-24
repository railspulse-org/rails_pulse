module RailsPulse
  module Dashboard
    module Charts
      class ThroughputAndErrors
        def initialize(disabled_tags: [], show_non_tagged: true, period: 7, period_type: "day", window: nil)
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @window = window
        end

        def to_chart_data
          if @period_type == "hour"
            hours = time_window&.hour_starts || default_hour_range
            start_time = hours.first
            end_time = hours.last

            summaries = RailsPulse::Summary
              .with_tag_filters(@disabled_tags, @show_non_tagged)
              .where(
                summarizable_type: "RailsPulse::Route",
                period_type: "hour",
                period_start: start_time..end_time
              )
              .group(:period_start)
              .select(
                :period_start,
                "SUM(count) as total_count",
                "SUM(error_count) as total_5xx",
                "SUM(status_4xx) as total_4xx"
              )

            return nil if summaries.empty?

            hourly_data = {}
            summaries.each do |summary|
              time_key = summary.period_start.beginning_of_hour
              hourly_data[time_key] = {
                requests: summary.total_count || 0,
                errors: (summary.total_5xx || 0) + (summary.total_4xx || 0)
              }
            end

            time_range = hours

            series = [
              {
                name: "Requests",
                data: time_range.map { |time| [ time.to_i * 1000, hourly_data[time]&.[](:requests) || 0 ] },
                type: "bar",
                color: RailsPulse::ChartColors::DEFAULT,
                itemStyle: { borderRadius: [ 5, 5, 0, 0 ] },
                z: 1
              },
              {
                name: "Errors",
                data: time_range.map { |time| [ time.to_i * 1000, hourly_data[time]&.[](:errors) || 0 ] },
                type: "bar",
                color: "#dc2626",
                itemStyle: { borderRadius: [ 5, 5, 0, 0 ] },
                barGap: "-100%",
                z: 2
              }
            ]

            return { series: series }
          else
            date_range = time_window&.dates || default_day_range
            start_date = date_range.first
            end_date = date_range.last

            summaries = RailsPulse::Summary
              .with_tag_filters(@disabled_tags, @show_non_tagged)
              .where(
                summarizable_type: "RailsPulse::Route",
                period_type: "day",
                period_start: start_date.beginning_of_day..end_date.end_of_day
              )
              .group(:period_start)
              .select(
                :period_start,
                "SUM(count) as total_count",
                "SUM(error_count) as total_5xx",
                "SUM(status_4xx) as total_4xx"
              )

            return nil if summaries.empty?

            daily_data = {}
            summaries.each do |summary|
              date = summary.period_start.to_date
              daily_data[date] = {
                requests: summary.total_count || 0,
                errors: (summary.total_5xx || 0) + (summary.total_4xx || 0)
              }
            end

            labels = date_range.map { |date| date.strftime("%b %-d") }

            series = [
              {
                name: "Requests",
                data: date_range.map { |date| daily_data[date]&.[](:requests) || 0 },
                type: "bar",
                color: RailsPulse::ChartColors::DEFAULT,
                itemStyle: { borderRadius: [ 5, 5, 0, 0 ] },
                z: 1
              },
              {
                name: "Errors",
                data: date_range.map { |date| daily_data[date]&.[](:errors) || 0 },
                type: "bar",
                color: "#dc2626",
                itemStyle: { borderRadius: [ 5, 5, 0, 0 ] },
                barGap: "-100%",
                z: 2
              }
            ]
          end

          { labels: labels, series: series }
        end

        private

        # nil unless a window was given, so the default
        # "recent" view keeps using the trailing-@period-days fallback below.
        def time_window
          @window
        end

        def default_hour_range
          start_time = (@period * 24).hours.ago.beginning_of_hour
          end_time = Time.current.beginning_of_hour
          hours = []
          current_time = start_time
          while current_time <= end_time
            hours << current_time
            current_time += 1.hour
          end
          hours
        end

        def default_day_range
          start_date = @period.days.ago.beginning_of_day.to_date
          end_date = Time.current.to_date
          (start_date..end_date).to_a
        end
      end
    end
  end
end
