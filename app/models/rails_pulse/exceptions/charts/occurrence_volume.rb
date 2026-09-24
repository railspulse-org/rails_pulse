module RailsPulse
  module Exceptions
    module Charts
      # Exception frequency over time, read from the all-groups rollup summary.
      #
      # Reads summaries rather than counting occurrence rows directly: occurrence
      # rows are pruned by retention, so counting them would show a chart that
      # silently flattens toward zero the further back you look. Summaries are
      # retained at day granularity indefinitely.
      class OccurrenceVolume
        def initialize(window:, period_type: "day")
          @window      = window
          @period_type = period_type
        end

        def to_chart_data
          totals = RailsPulse::Summary
            .overall_exceptions
            .where(period_type: @period_type, period_start: @window.start_time..@window.end_time)
            .group(:period_start)
            .sum(:count)

          return nil if totals.empty?

          raw = totals.transform_keys { |period_start| period_start.to_i }
          padded = pad_with_zeros(raw)

          {
            series: [ {
              name: "Occurrences",
              data: padded.map { |timestamp, value| [ timestamp * 1000, value ] },
              type: "bar",
              color: RailsPulse::ChartColors::DEFAULT
            } ]
          }
        end

        private

        # A period with no exceptions produces no summary row, which is the
        # answer "zero" rather than "no data" — leaving the gap unfilled would
        # draw a chart that skips quiet days and misrepresents the trend.
        def pad_with_zeros(raw)
          step = @period_type.to_s == "hour" ? 3600 : 86_400

          {}.tap do |padded|
            (@window.start_time.to_i..@window.end_time.to_i).step(step) do |timestamp|
              padded[timestamp] = raw[timestamp] || 0
            end
          end
        end
      end
    end
  end
end
