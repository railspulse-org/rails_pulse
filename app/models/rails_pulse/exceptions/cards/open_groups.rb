module RailsPulse
  module Exceptions
    module Cards
      # How many distinct exception sites are currently open.
      #
      # Occurrence volume and open-group count answer different questions: one
      # loud exception firing ten thousand times and a hundred different sites
      # each firing once are both worth knowing about, and neither number tells
      # you about the other.
      class OpenGroups < RailsPulse::Cards::Base
        def initialize(disabled_tags: [], show_non_tagged: true, period: 14, period_type: "day")
          super
        end

        def to_metric_card
          open_count = RailsPulse::ExceptionGroup.where(status: "open").count

          # New groups are the ones that did not exist before this window — a
          # site that has just started failing, rather than a known one.
          new_in_window = RailsPulse::ExceptionGroup
            .where(status: "open")
            .where(first_seen_at: current_window_start..now)
            .count

          grouped = bucket_by_period(
            RailsPulse::ExceptionGroup.where(first_seen_at: current_window_start..now),
            column: :first_seen_at
          ) { |relation| relation.count }

          {
            id: "exceptions_open_groups",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "exceptions",
            title: "Open Groups",
            summary: "#{format_number(open_count)} open",
            chart_data: sparkline_from(grouped),
            trend_text: nil,
            period_stat: "#{format_number(new_in_window)} new this period",
            help_heading: "Open Exception Groups",
            help_text: "Distinct exception sites currently marked open — one per exception class and code location, not one per raise. Resolved and ignored groups are excluded. The period figure counts sites seen for the first time in this window, which is usually where a new bug shows up."
          }
        end
      end
    end
  end
end
