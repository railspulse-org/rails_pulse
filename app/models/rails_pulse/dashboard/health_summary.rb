module RailsPulse
  module Dashboard
    class HealthSummary
      include Concerns::ThresholdConstants
      include Concerns::TimeRangeHelper

      def initialize(disabled_tags: [], show_non_tagged: true, period: 7, start_time: nil, end_time: nil)
        @disabled_tags   = disabled_tags
        @show_non_tagged = show_non_tagged
        @period          = period
        @start_time      = start_time
        @end_time        = end_time
        @route_thresholds = RailsPulse.configuration.route_thresholds
        @query_thresholds = RailsPulse.configuration.query_thresholds
        @job_thresholds   = RailsPulse.configuration.job_thresholds
        @exception_thresholds = RailsPulse.configuration.exception_thresholds
      end

      def to_health_data
        {
          routes:   route_counts,
          queries:  query_counts,
          jobs:     job_counts,
          exceptions: exception_counts,
          tracking: tracking_counts,
          storage:  storage_counts
        }
      end

      private

      def route_counts
        start, finish = period_range

        data = RailsPulse::Summary
          .with_tag_filters(@disabled_tags, @show_non_tagged)
          .where(summarizable_type: "RailsPulse::Route", period_start: start..finish)
          .group("summarizable_id")
          .select(
            "summarizable_id",
            "SUM(p95_duration * count) / NULLIF(SUM(count), 0) as p95_duration",
            "SUM(count) as total_count",
            "SUM(error_count) as total_errors"
          )

        healthy = slow = critical = 0
        data.each do |r|
          p95        = r.p95_duration.to_f
          total      = r.total_count.to_i
          errors     = r.total_errors.to_i
          error_rate = total > 0 ? (errors * 100.0 / total) : 0.0

          if p95 >= @route_thresholds[:critical] || error_rate >= CRITICAL_ERROR_RATE
            critical += 1
          elsif p95 >= @route_thresholds[:slow] || error_rate >= WARNING_ERROR_RATE
            slow += 1
          else
            healthy += 1
          end
        end

        { healthy: healthy, slow: slow, critical: critical }
      end

      def query_counts
        start, finish = period_range

        data = RailsPulse::Summary
          .with_tag_filters(@disabled_tags, @show_non_tagged)
          .where(summarizable_type: "RailsPulse::Query", period_start: start..finish)
          .group("summarizable_id")
          .select(
            "summarizable_id",
            "SUM(p95_duration * count) / NULLIF(SUM(count), 0) as p95_duration"
          )

        healthy = slow = critical = 0
        data.each do |r|
          p95 = r.p95_duration.to_f

          if p95 >= @query_thresholds[:critical]
            critical += 1
          elsif p95 >= @query_thresholds[:slow]
            slow += 1
          else
            healthy += 1
          end
        end

        { healthy: healthy, slow: slow, critical: critical }
      end

      def storage_counts
        StoragePressure.new.storage_counts
      end

      # A process that dropped and has since gone away still counts as
      # critical for that hour. Nil until any writer has reported.
      def tracking_counts
        return nil unless RailsPulse::Event.table_available?

        live = RailsPulse::WriterHeartbeat.live_processes
        dropped_by_process = RailsPulse::WriterHeartbeat.dropped_by_process(window: 1.hour).select { |_, n| n.positive? }
        return nil if live.empty? && dropped_by_process.empty?

        critical = dropped_by_process.size
        healthy = slow = 0
        live.each do |process|
          next if dropped_by_process.key?(process.process_label)

          # queue_size <= 0 means unreadable metadata, not an empty queue
          if process.queue_size <= 0
            critical += 1
          elsif process.queue_depth * 2 >= process.queue_size
            slow += 1
          else
            healthy += 1
          end
        end

        { healthy: healthy, slow: slow, critical: critical }
      end

      def job_counts
        return nil unless RailsPulse.configuration.track_jobs

        healthy = slow = critical = 0
        RailsPulse::Job.where("runs_count > 0").each do |job|
          failure_rate = job.failure_rate
          p95          = job.p95_duration.to_f

          if failure_rate >= CRITICAL_JOB_FAILURE_RATE || p95 >= @job_thresholds[:critical]
            critical += 1
          elsif failure_rate >= WARNING_JOB_FAILURE_RATE || p95 >= @job_thresholds[:slow]
            slow += 1
          else
            healthy += 1
          end
        end

        { healthy: healthy, slow: slow, critical: critical }
      end

      # Exception groups classified by how often they fired over the dashboard
      # period, read from summaries rather than from ExceptionGroup's lifetime
      # occurrence_count — a group that fired ten thousand times last year and
      # is now silent is not a critical problem today.
      #
      # A group with occurrences in the period but below the warning threshold
      # counts as "slow" rather than "healthy": an exception happening at all is
      # not healthy, it is just not yet urgent.
      def exception_counts
        return nil unless RailsPulse.configuration.track_exceptions
        return nil unless exception_summaries_available?

        start, finish = period_range

        counts = RailsPulse::Summary
          .for_exceptions
          .where.not(summarizable_id: 0)
          .where(period_start: start..finish)
          .group(:summarizable_id)
          .sum(:count)

        healthy = slow = critical = 0

        open_group_ids.each do |group_id|
          occurrences = counts[group_id].to_i

          if occurrences >= @exception_thresholds[:critical]
            critical += 1
          elsif occurrences >= @exception_thresholds[:warning]
            slow += 1
          elsif occurrences.positive?
            slow += 1
          else
            healthy += 1
          end
        end

        { healthy: healthy, slow: slow, critical: critical }
      end

      def open_group_ids
        RailsPulse::ExceptionGroup.where(status: "open").pluck(:id)
      end

      def exception_summaries_available?
        RailsPulse::ExceptionGroup.table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end
    end
  end
end
