
module RailsPulse
  class SummaryService
    attr_reader :period_type, :start_time, :end_time

    def initialize(period_type, start_time)
      @period_type = period_type
      @start_time = Summary.normalize_period_start(period_type, start_time)
      @end_time = Summary.calculate_period_end(period_type, @start_time)
    end

    def perform
      RailsPulse.logger.info "Starting #{period_type} summary for #{start_time}"

      ActiveRecord::Base.transaction do
        aggregate_requests  # Overall system metrics
        aggregate_routes    # Per-route metrics
        aggregate_queries   # Per-query metrics
        aggregate_jobs      # Per-job metrics
        aggregate_exceptions # Per-exception-group frequency
      end

      RailsPulse.logger.info "Completed #{period_type} summary"
    rescue => e
      RailsPulse.logger.error "Summary failed: #{e.message}"
      raise
    end

    private

    def aggregate_requests
      # Create a single summary for ALL requests in this period. Written even
      # when the period is empty (count: 0) so its timestamp keeps advancing
      # every period — it's the heartbeat several health checks use to detect
      # whether SummaryJob is still running (dashboard banner, rails_pulse:status,
      # StoragePressure staleness, and CleanupService's summarized_cutoff).
      requests = Request.where(occurred_at: start_time...end_time)

      # Get all durations and statuses for percentile calculations
      request_data = requests.pluck(:duration, :status)
      durations = request_data.map(&:first).compact.sort
      statuses = request_data.map(&:second)
      avg = durations.any? ? durations.sum.to_f / durations.size : 0

      # Find or create the overall request summary
      summary = Summary.find_or_initialize_by(
        summarizable_type: "RailsPulse::Request",
        summarizable_id: 0,  # Use 0 as a special ID for overall summaries
        period_type: period_type,
        period_start: start_time
      )

      summary.assign_attributes(
        period_end: end_time,
        count: durations.size,
        avg_duration: avg,
        min_duration: durations.min,
        max_duration: durations.max,
        total_duration: durations.sum,
        p50_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.5),
        p95_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.95),
        p99_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.99),
        stddev_duration: RailsPulse::Statistics.calculate_stddev(durations, avg),
        error_count: statuses.count { |s| s >= 500 },
        success_count: statuses.count { |s| s < 500 },
        status_2xx: statuses.count { |s| s.between?(200, 299) },
        status_3xx: statuses.count { |s| s.between?(300, 399) },
        status_4xx: statuses.count { |s| s.between?(400, 499) },
        status_5xx: statuses.count { |s| s >= 500 }
      )

      summary.save!
    end

    private

    def aggregate_routes
      all_rows = Request
        .where(occurred_at: start_time...end_time)
        .where.not(route_id: nil)
        .pluck(:route_id, :duration, :status)

      return if all_rows.empty?

      all_rows.group_by(&:first).each do |route_id, rows|
        durations = rows.map { |_, d, _| d }.compact.sort
        statuses = rows.map { |_, _, s| s }
        avg = durations.sum.to_f / durations.size

        summary = Summary.find_or_initialize_by(
          summarizable_type: "RailsPulse::Route",
          summarizable_id: route_id,
          period_type: period_type,
          period_start: start_time
        )

        summary.assign_attributes(
          period_end: end_time,
          count: rows.size,
          avg_duration: avg,
          min_duration: durations.first,
          max_duration: durations.last,
          total_duration: durations.sum,
          p50_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.5),
          p95_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.95),
          p99_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.99),
          stddev_duration: RailsPulse::Statistics.calculate_stddev(durations, avg),
          error_count: statuses.count { |s| s >= 500 },
          success_count: statuses.count { |s| s < 500 },
          status_2xx: statuses.count { |s| s.between?(200, 299) },
          status_3xx: statuses.count { |s| s.between?(300, 399) },
          status_4xx: statuses.count { |s| s.between?(400, 499) },
          status_5xx: statuses.count { |s| s >= 500 }
        )

        summary.save!
      end
    end

    # Exception frequency, per group and overall.
    #
    # ExceptionGroup#occurrence_count is a lifetime counter and occurrence rows
    # are pruned by retention, so without this there is no way to ask how often
    # something happened last week — the history is gone as soon as cleanup
    # runs. Only `count` is meaningful here; the duration columns stay null
    # because an exception has no duration.
    def aggregate_exceptions
      return unless RailsPulse.configuration.track_exceptions
      return unless ExceptionOccurrence.table_exists?

      counts = ExceptionOccurrence
        .where(occurred_at: start_time...end_time)
        .group(:exception_group_id)
        .count

      return if counts.empty?

      counts.each do |group_id, occurrences|
        upsert_exception_summary(group_id, occurrences)
      end

      # A rollup across every group, so the dashboard can chart total exception
      # volume without loading one series per group.
      upsert_exception_summary(0, counts.values.sum)
    rescue ActiveRecord::ActiveRecordError => e
      # Exceptions are the newest summarizable and the only optional one. A
      # failure here must not lose the route, query and job summaries that were
      # written in the same transaction.
      RailsPulse.logger.error "Exception summary skipped: #{e.message}"
    end

    def upsert_exception_summary(group_id, occurrences)
      summary = Summary.find_or_initialize_by(
        summarizable_type: "RailsPulse::ExceptionGroup",
        summarizable_id: group_id,
        period_type: period_type,
        period_start: start_time
      )

      summary.assign_attributes(period_end: end_time, count: occurrences)
      summary.save!
    end

    def aggregate_queries
      all_rows = Operation
        .where(occurred_at: start_time...end_time)
        .where.not(query_id: nil)
        .pluck(:query_id, :duration)

      return if all_rows.empty?

      all_rows.group_by(&:first).each do |query_id, rows|
        durations = rows.map(&:last).compact.sort
        next if durations.empty?

        avg = durations.sum.to_f / durations.size

        summary = Summary.find_or_initialize_by(
          summarizable_type: "RailsPulse::Query",
          summarizable_id: query_id,
          period_type: period_type,
          period_start: start_time
        )

        summary.assign_attributes(
          period_end: end_time,
          count: durations.size,
          avg_duration: avg,
          min_duration: durations.first,
          max_duration: durations.last,
          total_duration: durations.sum,
          p50_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.5),
          p95_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.95),
          p99_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.99),
          stddev_duration: RailsPulse::Statistics.calculate_stddev(durations, avg)
        )

        summary.save!
      end
    end

    def aggregate_jobs
      job_runs = JobRun
        .includes(:job)
        .where(occurred_at: start_time...end_time)
        .where(status: JobRun::FINAL_STATUSES)

      return if job_runs.empty?

      job_runs.group_by(&:job_id).each do |job_id, runs|
        job = runs.first&.job
        next unless job

        duration_values = runs.map(&:duration).compact.map(&:to_f).sort
        next if duration_values.empty?

        duration_count = duration_values.size
        total_duration = duration_values.sum
        average_duration = total_duration / duration_count

        summary = Summary.find_or_initialize_by(
          summarizable_type: "RailsPulse::Job",
          summarizable_id: job.id,
          period_type: period_type,
          period_start: start_time
        )

        summary.assign_attributes(
          period_end: end_time,
          count: runs.size,
          avg_duration: average_duration,
          min_duration: duration_values.first,
          max_duration: duration_values.last,
          total_duration: total_duration,
          p50_duration: RailsPulse::Statistics.calculate_percentile(duration_values, 0.5),
          p95_duration: RailsPulse::Statistics.calculate_percentile(duration_values, 0.95),
          p99_duration: RailsPulse::Statistics.calculate_percentile(duration_values, 0.99),
          stddev_duration: RailsPulse::Statistics.calculate_stddev(duration_values, average_duration),
          error_count: runs.count(&:failure_like_status?),
          success_count: runs.count { |run| run.status == "success" }
        )

        summary.save!
      end
    end
  end
end
