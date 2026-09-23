module RailsPulse
  module Dashboard
    module Concerns
      module TimeRangeHelper
        private

        def period_range
          return [ @window.start_time, @window.end_time ] if @window

          [ @period.days.ago.beginning_of_day, Time.current ]
        end
      end
    end
  end
end
