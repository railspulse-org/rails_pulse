module RailsPulse
  module Exceptions
    module Cards
      # How often exceptions fired, and whether that is going up.
      #
      # This is the card that makes "which exceptions are increasing?" a
      # question the product can answer at a glance. It reads the all-groups
      # rollup summary rather than ExceptionGroup#occurrence_count, which is a
      # lifetime counter and never goes down.
      class TotalOccurrences < RailsPulse::Cards::Base
        SUMMARIZABLE_TYPE = "RailsPulse::ExceptionGroup".freeze

        def initialize(disabled_tags: [], show_non_tagged: true, period: 14, period_type: "day")
          @disabled_tags   = disabled_tags
          @show_non_tagged = show_non_tagged
          @period          = period
          @period_type     = period_type
        end

        def to_metric_card
          base_query = RailsPulse::Summary
            .overall_exceptions
            .where(period_type: @period_type, period_start: range_start..now)

          metrics = base_query.select(
            "SUM(rails_pulse_summaries.count) AS total_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS current_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS previous_count"
          ).take

          total    = metrics&.total_count.to_i
          current  = metrics&.current_count.to_i
          previous = metrics&.previous_count.to_i

          # More exceptions is worse, so the trend arrow means the opposite of
          # what it means on a throughput card.
          trend_icon, trend_amount = trend_for(current, previous) if show_trend?

          grouped = bucket_by_period(base_query.where(period_start: current_window_start..now)) do |relation|
            relation.sum("rails_pulse_summaries.count")
          end

          {
            id: "exceptions_total_occurrences",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "exceptions",
            title: "Occurrences",
            summary: "#{format_number(total)} raised",
            chart_data: sparkline_from(grouped),
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: period_date_range,
            help_heading: "Exception Occurrences",
            help_text: "How many exceptions your application raised over the period, across every group. Read from retained summaries, so the history stays accurate even after individual occurrence records have been cleaned up. A rising trend is the signal to look at which groups are growing."
          }
        end
      end
    end
  end
end
