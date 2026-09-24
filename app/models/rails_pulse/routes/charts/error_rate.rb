module RailsPulse
  module Routes
    module Charts
      class ErrorRate < RailsPulse::Charts::Base
        def initialize(route: nil, **kwargs)
          super(subject: route, **kwargs)
        end

        def to_chart_data
          summaries = base_summary_query
            .group(:period_start)
            .select(
              :period_start,
              "SUM(count) as total_count",
              "SUM(error_count) as total_errors",
              "SUM(status_4xx) as total_4xx"
            )

          # Build raw_data hash from grouped results
          raw_data = {}
          summaries.each do |summary|
            timestamp = summary.period_start.to_i
            count = summary.total_count || 0
            raw_data[timestamp] = {
              error_rate: count > 0 ? (summary.total_errors.to_f / count * 100).round(2) : nil,
              client_error_rate: count > 0 ? (summary.total_4xx.to_f / count * 100).round(2) : nil
            }
          end

          # Pad missing data with defaults
          default_value = { error_rate: nil, client_error_rate: nil }
          daily_data = {}
          (@window.start_time.to_i..@window.end_time.to_i).step(time_step) do |timestamp|
            daily_data[timestamp] = raw_data[timestamp] || default_value
          end

          # Build series data as [timestamp_ms, value] pairs for ECharts time axis
          series = [
            {
              name: "4xx Errors",
              data: daily_data.map { |ts, d| [ ts * 1000, d[:client_error_rate] ] },
              type: "bar",
              stack: "error_rate",
              color: RailsPulse::ChartColors::P99,
              itemStyle: { borderRadius: [ 0, 0, 0, 0 ] }
            },
            {
              name: "5xx Errors",
              data: daily_data.map { |ts, d| [ ts * 1000, d[:error_rate] ] },
              type: "bar",
              stack: "error_rate",
              color: RailsPulse::ChartColors::P95,
              itemStyle: { borderRadius: [ 5, 5, 0, 0 ] }
            }
          ]

          { series: series }
        end

        private

        def summarizable_type = "RailsPulse::Route"
      end
    end
  end
end
