module RailsPulse
  # A resolved start/end range plus the bucketing helpers dashboard charts,
  # cards, and summary panels need: how many whole days it spans, which
  # calendar dates or hour-starts fall inside it, and the equal-length window
  # immediately before it for period-over-period comparisons.
  #
  # Built from the start/end times TimeRangeConcern#setup_time_range resolves
  # and threaded through instead of collapsing to a bare day count. Collapsing
  # to a count and re-deriving "the last N days ending now" from it silently
  # discarded any custom range set in the past, and truncated the count
  # itself via integer division on top of that.
  class TimeWindow
    attr_reader :start_time, :end_time

    # Returns nil (rather than raising) when either bound is missing, since
    # every caller already has a "no range selected" fallback to use instead.
    def self.build(start_time, end_time)
      return nil if start_time.nil? || end_time.nil?

      new(start_time, end_time)
    end

    def initialize(start_time, end_time)
      @start_time = coerce(start_time)
      @end_time = coerce(end_time)
    end

    # Whole days spanned, rounded rather than truncated so a range that is a
    # few seconds short of N whole days (e.g. "last N days" ending :59:59)
    # still counts as N, not N-1. Always at least 1.
    def days
      [ ((end_time - start_time) / 1.day).round, 1 ].max
    end

    # Every calendar date whose day-bucket (midnight to midnight) falls
    # entirely inside the window, ascending. A day whose midnight is before
    # the window start is excluded, so a start time that lands mid-day does
    # not pull in a partial day of data from before the selected range.
    def dates
      first_date = start_time.beginning_of_day == start_time ? start_time.to_date : (start_time.to_date + 1)
      return [] if first_date > end_time.to_date

      (first_date..end_time.to_date).to_a
    end

    # Every hour-start inside the window, ascending.
    def hour_starts
      starts = []
      current = start_time.beginning_of_hour
      current += 1.hour if current < start_time
      while current <= end_time
        starts << current
        current += 1.hour
      end
      starts
    end

    # The window of the same length immediately preceding this one, for
    # period-over-period comparisons. `unit` is "day" or "hour".
    def previous(unit)
      span = unit == "hour" ? (end_time - start_time) : days.days
      self.class.new(start_time - span, start_time)
    end

    private

    def coerce(value)
      value.is_a?(Numeric) ? Time.zone.at(value) : value.in_time_zone
    end
  end
end
