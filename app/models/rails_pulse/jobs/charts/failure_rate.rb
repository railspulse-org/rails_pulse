module RailsPulse
  module Jobs
    module Charts
      class FailureRate < RailsPulse::Charts::Base
        def to_chart_data
          summaries = base_summary_query

          # Single query fetching both counts
          summaries = summaries
            .group(:period_start)
            .select(
              :period_start,
              "SUM(rails_pulse_summaries.count) as total_count",
              "SUM(rails_pulse_summaries.error_count) as total_errors"
            )

          # Build raw_data hash from grouped results
          raw_data = {}
          summaries.each do |summary|
            timestamp = summary.period_start.to_i
            count = summary.total_count || 0
            raw_data[timestamp] = count > 0 ? (summary.total_errors.to_f / count * 100).round(2) : nil
          end

          # Pad missing data with zeros
          step = time_step
          daily_data = {}
          (@window.start_time.to_i..@window.end_time.to_i).step(step) do |timestamp|
            daily_data[timestamp] = raw_data[timestamp] || nil
          end

          series = [
            {
              name: "Failure Rate",
              data: daily_data.map { |ts, v| [ ts * 1000, v ] },
              type: "bar",
              color: RailsPulse::ChartColors::P95
            }
          ]

          { series: series }
        end

        private

        def summarizable_type = "RailsPulse::Job"
      end
    end
  end
end
