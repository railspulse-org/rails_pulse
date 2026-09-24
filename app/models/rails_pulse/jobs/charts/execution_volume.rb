module RailsPulse
  module Jobs
    module Charts
      class ExecutionVolume < RailsPulse::Charts::Base
        def to_chart_data
          summaries = base_summary_query

          # Group by period_start and sum execution counts
          summaries = summaries
            .group(:period_start)
            .select(
              :period_start,
              "SUM(rails_pulse_summaries.count) as total_count"
            )

          # Build raw_data hash from grouped results
          raw_data = {}
          summaries.each do |summary|
            timestamp = summary.period_start.to_i
            raw_data[timestamp] = summary.total_count || 0
          end

          # Pad missing data with zeros using base class helper
          daily_data = pad_data_with_zeros(raw_data, @window.start_time, @window.end_time, time_step)

          # Build series data as [timestamp_ms, value] pairs for ECharts time axis
          series = [ {
            name: "Executions",
            data: daily_data.map { |ts, v| [ ts * 1000, v ] },
            type: "bar",
            color: RailsPulse::ChartColors::DEFAULT
          } ]

          { series: series }
        end

        private

        def summarizable_type = "RailsPulse::Job"
      end
    end
  end
end
