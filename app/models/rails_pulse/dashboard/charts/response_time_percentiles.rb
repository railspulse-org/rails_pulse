module RailsPulse
  module Dashboard
    module Charts
      class ResponseTimePercentiles
        def initialize(disabled_tags: [], show_non_tagged: true, period: 7, period_type: "day", start_time: nil, end_time: nil)
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @start_time = start_time
          @end_time = end_time
        end

        def to_chart_data
          if @period_type == "hour"
            # Bucket to exactly the selected hours when an explicit range was
            # given; otherwise fall back to "the trailing @period days".
            hours = time_window&.hour_starts || default_hour_range
            start_time = hours.first
            end_time = hours.last

            # Get the actual data from Summary records (routes)
            summaries = RailsPulse::Summary
              .with_tag_filters(@disabled_tags, @show_non_tagged)
              .where(
                summarizable_type: "RailsPulse::Route",
                period_type: "hour",
                period_start: start_time..end_time
              )

            return nil if summaries.empty?

            # Group by hour and calculate weighted percentiles
            hourly_data = {}
            summaries.each do |summary|
              time_key = summary.period_start.beginning_of_hour
              count = summary.count || 0

              if hourly_data[time_key]
                hourly_data[time_key][:total_weighted_p50] += (summary.p50_duration || 0) * count
                hourly_data[time_key][:total_weighted_p95] += (summary.p95_duration || 0) * count
                hourly_data[time_key][:total_weighted_p99] += (summary.p99_duration || 0) * count
                hourly_data[time_key][:total_count] += count
              else
                hourly_data[time_key] = {
                  total_weighted_p50: (summary.p50_duration || 0) * count,
                  total_weighted_p95: (summary.p95_duration || 0) * count,
                  total_weighted_p99: (summary.p99_duration || 0) * count,
                  total_count: count
                }
              end
            end

            # Convert to final values (weighted averages)
            final_data = hourly_data.transform_values do |data|
              {
                p50: data[:total_count] > 0 ? (data[:total_weighted_p50] / data[:total_count]).round(0) : nil,
                p95: data[:total_count] > 0 ? (data[:total_weighted_p95] / data[:total_count]).round(0) : nil,
                p99: data[:total_count] > 0 ? (data[:total_weighted_p99] / data[:total_count]).round(0) : nil
              }
            end

            time_range = hours

            # Build series data as [timestamp_ms, value] pairs for ECharts time axis
            timestamps_ms = time_range.map { |t| t.to_i * 1000 }
            p50_data = time_range.map { |time| [ time.to_i * 1000, final_data[time]&.[](:p50) ] }
            p95_data = time_range.map { |time| [ time.to_i * 1000, final_data[time]&.[](:p95) ] }
            p99_data = time_range.map { |time| [ time.to_i * 1000, final_data[time]&.[](:p99) ] }
          else
            # Bucket to exactly the selected calendar days when an explicit
            # range was given; otherwise fall back to "the trailing @period days".
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

            return nil if summaries.empty?

            daily_data = {}
            summaries.each do |summary|
              date = summary.period_start.to_date
              count = summary.count || 0

              if daily_data[date]
                daily_data[date][:total_weighted_p50] += (summary.p50_duration || 0) * count
                daily_data[date][:total_weighted_p95] += (summary.p95_duration || 0) * count
                daily_data[date][:total_weighted_p99] += (summary.p99_duration || 0) * count
                daily_data[date][:total_count] += count
              else
                daily_data[date] = {
                  total_weighted_p50: (summary.p50_duration || 0) * count,
                  total_weighted_p95: (summary.p95_duration || 0) * count,
                  total_weighted_p99: (summary.p99_duration || 0) * count,
                  total_count: count
                }
              end
            end

            # Convert to final values
            final_data = daily_data.transform_values do |data|
              {
                p50: data[:total_count] > 0 ? (data[:total_weighted_p50] / data[:total_count]).round(0) : nil,
                p95: data[:total_count] > 0 ? (data[:total_weighted_p95] / data[:total_count]).round(0) : nil,
                p99: data[:total_count] > 0 ? (data[:total_weighted_p99] / data[:total_count]).round(0) : nil
              }
            end

            # Build labels array
            labels = date_range.map { |date| date.strftime("%b %-d") }

            # Build series data
            p50_data = date_range.map { |date| final_data[date]&.[](:p50) }
            p95_data = date_range.map { |date| final_data[date]&.[](:p95) }
            p99_data = date_range.map { |date| final_data[date]&.[](:p99) }
          end

          # Build series (common for both hourly and daily)
          series = []
          series << {
            name: "P50",
            data: p50_data,
            type: "line",
            color: RailsPulse::ChartColors::DEFAULT
          }
          series << {
            name: "P95",
            data: p95_data,
            type: "line",
            color: RailsPulse::ChartColors::P95
          }
          series << {
            name: "P99",
            data: p99_data,
            type: "line",
            color: RailsPulse::ChartColors::P99
          }

          # Add Service Level Objective series if configured
          slo_configs = RailsPulse.configuration.service_level_objectives
          slo_configs.each do |slo|
            color = slo[:percentile] == 95 ? RailsPulse::ChartColors::P95 : RailsPulse::ChartColors::P99
            slo_data = if @period_type == "hour"
              timestamps_ms.map { |ts| [ ts, slo[:threshold] ] }
            else
              Array.new(labels.length, slo[:threshold])
            end
            series.unshift({
              name: "P#{slo[:percentile]} SLO (#{slo[:threshold]}ms)",
              data: slo_data,
              type: "line",
              lineStyle: { type: "dashed", width: 2 },
              color: color,
              symbol: "none"
            })
          end

          if @period_type == "hour"
            { series: series }
          else
            { labels: labels, series: series }
          end
        end

        private

        # nil unless both start_time and end_time were given, so the dashboard's
        # default "recent" view (no custom range selected) keeps using the
        # trailing-@period-days fallback below.
        def time_window
          @time_window ||= RailsPulse::TimeWindow.build(@start_time, @end_time)
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
