module RailsPulse
  # Aggregates one period (hour, day, week or month) into
  # rails_pulse_summaries rows.
  #
  # Hours are computed from raw rows by FromRawRows. Days are rolled up from
  # their hours, and weeks and months from their days, by FromChildPeriods,
  # so a long period never re-reads raw rows: its cost does not grow with
  # its length, and it stays correct after raw retention has pruned them.
  #
  # Every period gets one overall request row (type RailsPulse::Request,
  # summarizable_id 0), written even when the period is empty (count: 0) so
  # its timestamp keeps advancing every period — and only once the period
  # has ended. It is the heartbeat several
  # health checks use to detect whether SummaryJob is still running
  # (dashboard banner, rails_pulse:status, StoragePressure staleness, and
  # CleanupService's summarized_cutoff), and the marker this service uses to
  # tell whether a child period has been summarized.
  #
  # Rows are written with upsert_all against the summaries table's unique
  # index, one statement per summarizable kind, so re-running a period (the
  # backfill task, a retried SummaryJob) overwrites rather than duplicates and
  # a period with hundreds of routes costs a handful of statements instead of
  # two per route.
  class SummaryService
    UNIQUE_INDEX = :idx_pulse_summaries_unique

    # The period each longer period is rolled up from. Weeks and months build
    # from days because weeks do not tile months.
    CHILD_PERIOD_TYPES = { "day" => "hour", "week" => "day", "month" => "day" }.freeze
    CHILD_PERIOD_STEPS = { "hour" => 1.hour, "day" => 1.day }.freeze

    # Every percentile column a summary row carries, with its quantile.
    # Metrics, FromRawRows, FromChildPeriods and RouteMerger read this, so a
    # percentile added here is written and merged on every summary path.
    # Cloud::CombinedMetrics keeps its own list, matching the columns the
    # Cloud payload sends.
    PERCENTILES = { p50_duration: 0.5, p90_duration: 0.9, p95_duration: 0.95, p99_duration: 0.99 }.freeze

    attr_reader :period_type, :start_time, :end_time

    def initialize(period_type, start_time)
      @period_type = period_type
      @start_time = Summary.normalize_period_start(period_type, start_time)
      @end_time = Summary.calculate_period_end(period_type, @start_time)
    end

    def perform
      # A period is summarized only once it has ended. The overall request
      # row doubles as the heartbeat that CleanupService's summarized_cutoff
      # and summarize_missing_child_periods trust to mean "fully aggregated";
      # written mid-period, it would let cleanup delete raw rows that were
      # never counted and let a later rollup bake the partial numbers in as
      # final.
      if end_time >= Time.current
        RailsPulse.logger.info "Skipping #{period_type} summary for #{start_time}: period has not ended"
        return
      end

      RailsPulse.logger.info "Starting #{period_type} summary for #{start_time}"

      summarize_missing_child_periods if rollup?

      # Rows are computed before the transaction opens. A busy period's
      # aggregation can take seconds; doing it with the transaction already
      # open leaves it idle from the database's perspective and vulnerable to
      # a configured idle_in_transaction_session_timeout on installs that set
      # one.
      rows = summary_rows

      # The engine's own connection: on a separate-database install
      # ActiveRecord::Base would open the transaction on the host's primary.
      RailsPulse::ApplicationRecord.transaction do
        upsert_summaries(rows[:requests_and_routes])
        upsert_summaries(rows[:queries])
        upsert_summaries(rows[:jobs])
        upsert_exception_summaries(rows[:exceptions])
      end

      RailsPulse.logger.info "Completed #{period_type} summary"
    rescue => e
      RailsPulse.logger.error "Summary failed: #{e.message}"
      raise
    end

    private

    def rollup?
      CHILD_PERIOD_TYPES.key?(period_type)
    end

    def source
      @source ||=
        if rollup?
          FromChildPeriods.new(child_period_type, child_period_starts)
        else
          FromRawRows.new(start_time...end_time)
        end
    end

    def summary_rows
      {
        requests_and_routes: with_period(source.request_rows + source.route_rows),
        queries: with_period(source.query_rows),
        jobs: with_period(source.job_rows),
        exceptions: with_period(exception_rows)
      }
    end

    def with_period(rows)
      rows.map { |row| row.merge(period_type: period_type, period_start: start_time, period_end: end_time) }
    end

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
    def exception_rows
      return [] unless RailsPulse.configuration.track_exceptions
      return [] unless ExceptionOccurrence.table_exists?

      source.exception_rows
    rescue ActiveRecord::ActiveRecordError => e
      RailsPulse.logger.error "Exception summary skipped: #{e.message}"
      []
    end

    def upsert_exception_summaries(rows)
      upsert_summaries(rows)
    rescue ActiveRecord::ActiveRecordError => e
      RailsPulse.logger.error "Exception summary skipped: #{e.message}"
    end

    def child_period_type
      CHILD_PERIOD_TYPES.fetch(period_type)
    end

    # Every child boundary inside this period. perform refuses periods that
    # have not ended, so a rollup's children have all ended too.
    def child_period_starts
      @child_period_starts ||= begin
        step = CHILD_PERIOD_STEPS.fetch(child_period_type)
        starts = []
        current = start_time
        while current <= end_time
          starts << current
          current += step
        end
        starts
      end
    end

    # A child period without its heartbeat row was never summarized
    # (SummaryJob was not running, or a backfill asked only for the longer
    # period), so it is summarized now, recursively, before being rolled up.
    def summarize_missing_child_periods
      summarized = Summary
        .where(summarizable_type: "RailsPulse::Request", summarizable_id: 0, period_type: child_period_type)
        .where(period_start: start_time..end_time)
        .pluck(:period_start)
        .to_set(&:to_i)

      child_period_starts.each do |child_start|
        next if summarized.include?(child_start.to_i)

        SummaryService.new(child_period_type, child_start).perform
      end
    end
  end
end
