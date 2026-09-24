module RailsPulse
  # Aggregates one period (hour, day, week or month) of requests, operations,
  # job runs and exception occurrences into rails_pulse_summaries rows.
  #
  # Rows are written with upsert_all against the summaries table's unique
  # index, one statement per summarizable kind, so re-running a period (the
  # backfill task, a retried SummaryJob) overwrites rather than duplicates and
  # a period with hundreds of routes costs a handful of statements instead of
  # two per route.
  class SummaryService
    UNIQUE_INDEX = :idx_pulse_summaries_unique

    attr_reader :period_type, :start_time, :end_time

    def initialize(period_type, start_time)
      @period_type = period_type
      @start_time = Summary.normalize_period_start(period_type, start_time)
      @end_time = Summary.calculate_period_end(period_type, @start_time)
    end

    def perform
      RailsPulse.logger.info "Starting #{period_type} summary for #{start_time}"

      # Rows are computed (queried, grouped, sorted, percentiles taken)
      # before the transaction opens. A busy period's Ruby-side aggregation
      # can take seconds; doing it with the transaction already open leaves
      # it idle from the database's perspective and vulnerable to a
      # configured idle_in_transaction_session_timeout on installs that set
      # one.
      request_and_route_rows = request_summary_rows + route_summary_rows # Overall and per-route
      query_rows = query_summary_rows                                    # Per-query
      job_rows = job_summary_rows                                        # Per-job
      exception_rows = exception_summary_rows                            # Per-exception-group frequency

      # The engine's own connection: on a separate-database install
      # ActiveRecord::Base would open the transaction on the host's primary.
      RailsPulse::ApplicationRecord.transaction do
        upsert_summaries(request_and_route_rows)
        upsert_summaries(query_rows)
        upsert_summaries(job_rows)
        upsert_exception_summaries(exception_rows)
      end

      RailsPulse.logger.info "Completed #{period_type} summary"
    rescue => e
      RailsPulse.logger.error "Summary failed: #{e.message}"
      raise
    end

    private

    # Every row in one call must have the same keys, which is why the
    # summarizable kinds are upserted separately: request and route rows carry
    # status columns, query rows do not, exception rows carry only a count.
    def upsert_summaries(rows)
      return if rows.empty?

      # MySQL resolves the conflict through any unique key and rejects an
      # explicit target.
      unique_by = Summary.connection.supports_insert_conflict_target? ? UNIQUE_INDEX : nil
      Summary.upsert_all(rows, unique_by: unique_by)
    end

    def summary_row(summarizable_type, summarizable_id)
      {
        summarizable_type: summarizable_type,
        summarizable_id: summarizable_id,
        period_type: period_type,
        period_start: start_time,
        period_end: end_time
      }
    end

    # `durations` must be sorted. Empty input yields count 0 and nil
    # percentiles, which is what an idle period should record.
    def duration_metrics(durations)
      avg = durations.any? ? durations.sum.to_f / durations.size : 0

      {
        count: durations.size,
        avg_duration: avg,
        min_duration: durations.first,
        max_duration: durations.last,
        total_duration: durations.sum,
        p50_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.5),
        p95_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.95),
        p99_duration: RailsPulse::Statistics.calculate_percentile(durations, 0.99),
        stddev_duration: RailsPulse::Statistics.calculate_stddev(durations, avg)
      }
    end

    def status_metrics(statuses)
      {
        error_count: statuses.count { |s| s >= 500 },
        success_count: statuses.count { |s| s < 500 },
        status_2xx: statuses.count { |s| s.between?(200, 299) },
        status_3xx: statuses.count { |s| s.between?(300, 399) },
        status_4xx: statuses.count { |s| s.between?(400, 499) },
        status_5xx: statuses.count { |s| s >= 500 }
      }
    end

    # One row for ALL requests in the period, written even when the period is
    # empty (count: 0) so its timestamp keeps advancing every period — it is
    # the heartbeat several health checks use to detect whether SummaryJob is
    # still running (dashboard banner, rails_pulse:status, StoragePressure
    # staleness, and CleanupService's summarized_cutoff). summarizable_id 0
    # marks the overall rollup.
    def request_summary_rows
      request_data = Request.where(occurred_at: start_time...end_time).pluck(:duration, :status)
      durations = request_data.map(&:first).compact.sort
      statuses = request_data.map(&:second)

      [ summary_row("RailsPulse::Request", 0).merge(duration_metrics(durations), status_metrics(statuses)) ]
    end

    def route_summary_rows
      all_rows = Request
        .where(occurred_at: start_time...end_time)
        .where.not(route_id: nil)
        .pluck(:route_id, :duration, :status)

      all_rows.group_by(&:first).map do |route_id, rows|
        durations = rows.map { |_, d, _| d }.compact.sort
        statuses = rows.map { |_, _, s| s }

        summary_row("RailsPulse::Route", route_id)
          .merge(duration_metrics(durations), status_metrics(statuses), count: rows.size)
      end
    end

    def query_summary_rows
      all_rows = Operation
        .where(occurred_at: start_time...end_time)
        .where.not(query_id: nil)
        .pluck(:query_id, :duration)

      all_rows.group_by(&:first).filter_map do |query_id, rows|
        durations = rows.map(&:last).compact.sort
        next if durations.empty?

        summary_row("RailsPulse::Query", query_id).merge(duration_metrics(durations))
      end
    end

    def job_summary_rows
      all_rows = JobRun
        .where(occurred_at: start_time...end_time)
        .where(status: JobRun::FINAL_STATUSES)
        .where.not(job_id: nil)
        .pluck(:job_id, :duration, :status)
      return [] if all_rows.empty?

      # A run whose job row has gone (count-based cleanup) has nothing to
      # summarize against.
      known_job_ids = Job.where(id: all_rows.map(&:first).uniq).pluck(:id).to_set

      all_rows.group_by(&:first).filter_map do |job_id, runs|
        next unless known_job_ids.include?(job_id)

        durations = runs.map { |_, d, _| d }.compact.map(&:to_f).sort
        next if durations.empty?

        statuses = runs.map { |_, _, s| s }
        summary_row("RailsPulse::Job", job_id).merge(
          duration_metrics(durations),
          count: runs.size,
          error_count: statuses.count { |s| s != "success" },
          success_count: statuses.count { |s| s == "success" }
        )
      end
    end

    # Exception frequency, per group and overall.
    #
    # ExceptionGroup#occurrence_count is a lifetime counter and occurrence rows
    # are pruned by retention, so without this there is no way to ask how often
    # something happened last week — the history is gone as soon as cleanup
    # runs. Only `count` is meaningful here; the duration columns stay null
    # because an exception has no duration.
    #
    # Exceptions are the newest summarizable and the only optional one, so
    # both the query here and the upsert in upsert_exception_summaries are
    # individually rescued: a failure in either must not lose the route,
    # query and job summaries computed or written alongside it.
    def exception_summary_rows
      return [] unless RailsPulse.configuration.track_exceptions
      return [] unless ExceptionOccurrence.table_exists?

      counts = ExceptionOccurrence
        .where(occurred_at: start_time...end_time)
        .group(:exception_group_id)
        .count

      return [] if counts.empty?

      rows = counts.map { |group_id, occurrences| summary_row("RailsPulse::ExceptionGroup", group_id).merge(count: occurrences) }
      # A rollup across every group, so the dashboard can chart total exception
      # volume without loading one series per group.
      rows << summary_row("RailsPulse::ExceptionGroup", 0).merge(count: counts.values.sum)
      rows
    rescue ActiveRecord::ActiveRecordError => e
      RailsPulse.logger.error "Exception summary skipped: #{e.message}"
      []
    end

    def upsert_exception_summaries(rows)
      upsert_summaries(rows)
    rescue ActiveRecord::ActiveRecordError => e
      RailsPulse.logger.error "Exception summary skipped: #{e.message}"
    end
  end
end
