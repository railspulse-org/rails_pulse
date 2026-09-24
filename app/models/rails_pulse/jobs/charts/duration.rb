module RailsPulse
  module Jobs
    module Charts
      class Duration < RailsPulse::Charts::Base
        def to_chart_data
          summaries = base_summary_query

          # Group by period_start and calculate weighted percentiles
          summaries = summaries
            .group(:period_start)
            .select(
              :period_start,
              "SUM(rails_pulse_summaries.count) as total_count",
              "SUM(rails_pulse_summaries.p50_duration * rails_pulse_summaries.count) as total_weighted_p50",
              "SUM(rails_pulse_summaries.p95_duration * rails_pulse_summaries.count) as total_weighted_p95",
              "SUM(rails_pulse_summaries.p99_duration * rails_pulse_summaries.count) as total_weighted_p99"
            )

          # Build raw_data hash from grouped results
          raw_data = {}
          summaries.each do |summary|
            timestamp = summary.period_start.to_i
            count = summary.total_count || 0

            raw_data[timestamp] = {
              total_weighted_p50: summary.total_weighted_p50 || 0,
              total_weighted_p95: summary.total_weighted_p95 || 0,
              total_weighted_p99: summary.total_weighted_p99 || 0,
              total_count: count
            }
          end

          # Convert to final values (weighted averages) and pad missing data
          step = time_step
          daily_data = {}
          (@window.start_time.to_i..@window.end_time.to_i).step(step) do |timestamp|
            if raw_data[timestamp]
              count = raw_data[timestamp][:total_count]
              daily_data[timestamp] = {
                p50: count > 0 ? (raw_data[timestamp][:total_weighted_p50] / count).round(0) : nil,
                p95: count > 0 ? (raw_data[timestamp][:total_weighted_p95] / count).round(0) : nil,
                p99: count > 0 ? (raw_data[timestamp][:total_weighted_p99] / count).round(0) : nil
              }
            else
              daily_data[timestamp] = { p50: nil, p95: nil, p99: nil }
            end
          end

          # Build series data as [timestamp_ms, value] pairs for ECharts time axis
          series = []

          series << {
            name: "P50",
            data: daily_data.map { |ts, data| [ ts * 1000, data[:p50] ] },
            type: "line",
            color: RailsPulse::ChartColors::DEFAULT
          }

          series << {
            name: "P95",
            data: daily_data.map { |ts, data| [ ts * 1000, data[:p95] ] },
            type: "line",
            color: RailsPulse::ChartColors::P95
          }

          series << {
            name: "P99",
            data: daily_data.map { |ts, data| [ ts * 1000, data[:p99] ] },
            type: "line",
            color: RailsPulse::ChartColors::P99
          }

          { series: series }
        end

        private

        def summarizable_type = "RailsPulse::Job"
      end
    end
  end
end
