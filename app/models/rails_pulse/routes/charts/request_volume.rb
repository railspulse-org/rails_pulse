module RailsPulse
  module Routes
    module Charts
      class RequestVolume < RailsPulse::Charts::Base
        def initialize(route: nil, **kwargs)
          super(subject: route, **kwargs)
        end

        def to_chart_data
          summaries = base_summary_query
            .group(:period_start)
            .select(
              :period_start,
              "SUM(count) as total_count"
            )

          # Build raw_data hash from grouped results
          raw_data = {}
          summaries.each do |summary|
            timestamp = summary.period_start.to_i
            raw_data[timestamp] = summary.total_count || 0
          end

          # Pad missing data with zeros
          daily_data = pad_data_with_zeros(raw_data, @window.start_time, @window.end_time, time_step)

          # Build series data as [timestamp_ms, value] pairs for ECharts time axis
          series = [ {
            name: "Requests",
            data: daily_data.map { |ts, v| [ ts * 1000, v ] },
            type: "bar",
            color: RailsPulse::ChartColors::DEFAULT
          } ]

          { series: series }
        end

        private

        def summarizable_type = "RailsPulse::Route"
      end
    end
  end
end
