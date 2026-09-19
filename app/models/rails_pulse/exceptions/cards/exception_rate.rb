module RailsPulse
  module Exceptions
    module Cards
      # Exceptions raised per 1,000 requests.
      #
      # Raw occurrence counts rise with traffic, so a busy week and a broken
      # week look the same on the Occurrences card. Dividing by request volume
      # separates the two: this is the only exception figure that can fall while
      # occurrences climb, which is what "we shipped a fix but got busier" looks
      # like.
      #
      # Both sides come from rails_pulse_summaries — the all-groups exception
      # rollup over the overall request summary — so the ratio stays accurate
      # after cleanup has pruned the underlying records.
      class ExceptionRate < RailsPulse::Cards::Base
        PER = 1_000

        def initialize(disabled_tags: [], show_non_tagged: true, period: 14, period_type: "day")
          @disabled_tags   = disabled_tags
          @show_non_tagged = show_non_tagged
          @period          = period
          @period_type     = period_type
        end

        def to_metric_card
          exceptions = window_totals(RailsPulse::Summary.overall_exceptions)
          requests   = window_totals(RailsPulse::Summary.overall_requests)

          rate = rate_for(exceptions[:total], requests[:total])

          # More exceptions per request is worse, so the arrow reads the
          # opposite way round from a throughput card — the strip already
          # colours trending-up as negative.
          if show_trend?
            trend_icon, trend_amount = trend_for(
              rate_for(exceptions[:current],  requests[:current]),
              rate_for(exceptions[:previous], requests[:previous])
            )
          end

          {
            id: "exceptions_rate",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "exceptions",
            title: "Exception Rate",
            summary: "#{rate} per #{format_number(PER)}",
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: period_stat(exceptions[:total], requests[:total]),
            help_heading: "Exception Rate",
            help_text: "Exceptions raised per 1,000 requests over the period. Occurrence counts on their own rise and fall with traffic; this figure does not, so it is the one to watch when you want to know whether the application itself got worse. Reads the all-groups exception rollup against the overall request summary. Exceptions raised inside background jobs are counted in the numerator but have no request to divide by, so a job-heavy application will read high."
          }
        end

        private

        # Total, current-window and previous-window counts in one pass, so the
        # rate can be compared across windows without four separate queries.
        def window_totals(scope)
          row = scope
            .where(period_type: @period_type, period_start: range_start..now)
            .select(
              "SUM(rails_pulse_summaries.count) AS total_count",
              "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS current_count",
              "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS previous_count"
            )
            .take

          {
            total:    row&.total_count.to_i,
            current:  row&.current_count.to_i,
            previous: row&.previous_count.to_i
          }
        end

        # No requests in a period is "nothing to divide by", not "a rate of
        # zero" — but zero is the honest reading for a card that answers "how
        # often did this happen", and it keeps the sparkline continuous.
        def rate_for(exceptions, requests)
          return 0.0 if requests.to_i.zero?

          (exceptions.to_f / requests * PER).round(1)
        end

        def sparkline_data
          exceptions = grouped_counts(RailsPulse::Summary.overall_exceptions)
          requests   = grouped_counts(RailsPulse::Summary.overall_requests)

          sparkline_from(
            requests.keys.union(exceptions.keys).index_with do |bucket|
              rate_for(exceptions[bucket], requests[bucket])
            end
          )
        end

        def grouped_counts(scope)
          scoped = scope.where(period_type: @period_type, period_start: current_window_start..now)

          bucket_by_period(scoped) { |relation| relation.sum("rails_pulse_summaries.count") }
        end

        def period_stat(exceptions, requests)
          return period_date_range if requests.zero?

          "#{format_number(exceptions)} raised · #{format_number(requests)} requests"
        end
      end
    end
  end
end
