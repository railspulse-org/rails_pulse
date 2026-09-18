module RailsPulse
  module Dashboard
    module Concerns
      module TimeRangeHelper
        private

        def period_range
          window = RailsPulse::TimeWindow.build(@start_time, @end_time)
          return [ window.start_time, window.end_time ] if window

          [ @period.days.ago.beginning_of_day, Time.current ]
        end
      end
    end
  end
end
