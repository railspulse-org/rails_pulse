module RailsPulse
  module Charts
    class PercentileChartBase
      def initialize(ransack_query:, period_type: nil, subject: nil, window: nil, start_duration: nil, disabled_tags: [], show_non_tagged: true)
        @ransack_query = ransack_query
        @period_type = period_type
        @subject = subject
        @window = window
        @start_duration = start_duration
        @disabled_tags = disabled_tags
        @show_non_tagged = show_non_tagged
      end

      def to_chart_data
        summaries = @ransack_query.result(distinct: false)
          .with_tag_filters(@disabled_tags, @show_non_tagged)
          .where(
            summarizable_type: summarizable_type,
            period_type: @period_type
          )

        summaries = summaries.where(summarizable_id: @subject.id) if @subject

        # Group by period_start at database level and calculate weighted aggregates
        summaries = summaries
          .group(:period_start)
          .select(
            :period_start,
            "SUM(count) as total_count",
            "SUM(p50_duration * count) as total_weighted_p50",
            "SUM(p95_duration * count) as total_weighted_p95",
            "SUM(p99_duration * count) as total_weighted_p99"
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
        step = @period_type.to_s == "hour" ? 3600 : 86400
        daily_data = {}
        (@window.start_time.to_i..@window.end_time.to_i).step(step) do |timestamp|
          if raw_data[timestamp]
            count = raw_data[timestamp][:total_count]
            daily_data[timestamp] = {
              p50: count > 0 ? (raw_data[timestamp][:total_weighted_p50] / count).round(2) : nil,
              p95: count > 0 ? (raw_data[timestamp][:total_weighted_p95] / count).round(2) : nil,
              p99: count > 0 ? (raw_data[timestamp][:total_weighted_p99] / count).round(2) : nil
            }
          else
            daily_data[timestamp] = { p50: nil, p95: nil, p99: nil }
          end
        end

        # Build series data as [timestamp_ms, value] pairs for ECharts time axis
        timestamps_ms = daily_data.keys.map { |ts| ts * 1000 }

        series = []

        series << {
          name: "P50",
          data: daily_data.map { |ts, d| [ ts * 1000, d[:p50] ] },
          type: "line",
          color: RailsPulse::ChartColors::DEFAULT
        }

        series << {
          name: "P95",
          data: daily_data.map { |ts, d| [ ts * 1000, d[:p95] ] },
          type: "line",
          color: RailsPulse::ChartColors::P95
        }

        series << {
          name: "P99",
          data: daily_data.map { |ts, d| [ ts * 1000, d[:p99] ] },
          type: "line",
          color: RailsPulse::ChartColors::P99
        }

        slo_configs = RailsPulse.configuration.public_send(slo_config_key)
        slo_configs.each do |slo|
          color = slo[:percentile] == 95 ? RailsPulse::ChartColors::P95 : RailsPulse::ChartColors::P99
          series.unshift({
            name: "P#{slo[:percentile]} SLO (#{slo[:threshold]}ms)",
            data: timestamps_ms.map { |ts| [ ts, slo[:threshold] ] },
            type: "line",
            lineStyle: { type: "dashed", width: 2 },
            color: color,
            symbol: "none"
          })
        end

        { series: series }
      end

      private

      # Abstract methods — must be implemented by subclasses
      def summarizable_type = raise(NotImplementedError)
      def slo_config_key = raise(NotImplementedError)
    end
  end
end
