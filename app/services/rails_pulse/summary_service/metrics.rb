module RailsPulse
  class SummaryService
    # The duration and status columns of a summary row, computed from raw
    # values.
    module Metrics
      module_function

      # `durations` must be sorted. Empty input yields count 0 and nil
      # percentiles, which is what an idle period should record.
      def duration(durations)
        avg = durations.any? ? durations.sum.to_f / durations.size : 0

        {
          count: durations.size,
          avg_duration: avg,
          min_duration: durations.first,
          max_duration: durations.last,
          total_duration: durations.sum,
          **PERCENTILES.transform_values { |quantile| Statistics.calculate_percentile(durations, quantile) },
          stddev_duration: Statistics.calculate_stddev(durations, avg)
        }
      end

      def status(statuses)
        {
          error_count: statuses.count { |s| s >= 500 },
          success_count: statuses.count { |s| s < 500 },
          status_2xx: statuses.count { |s| s.between?(200, 299) },
          status_3xx: statuses.count { |s| s.between?(300, 399) },
          status_4xx: statuses.count { |s| s.between?(400, 499) },
          status_5xx: statuses.count { |s| s >= 500 }
        }
      end
    end
  end
end
