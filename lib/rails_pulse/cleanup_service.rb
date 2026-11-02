module RailsPulse
  class CleanupService
    # Rows removed per DELETE statement. Statement size, lock time and
    # transaction length stay flat however far a table has outgrown its limits.
    BATCH_SIZE = 5_000

    # Parent rows handled per round when their child rows must go first. The
    # parent ids are held in Ruby and sent back as a list, so this bounds it.
    PARENT_BATCH_SIZE = 1_000

    def self.perform
      new.perform
    end

    def initialize
      @config = RailsPulse.configuration
      @stats = {
        time_based: {},
        count_based: {},
        total_deleted: 0
      }
      @failures = []
    end

    def perform
      return unless cleanup_enabled?

      RailsPulse.logger.info "Starting data cleanup..."

      perform_time_based_cleanup
      perform_count_based_cleanup
      perform_event_cleanup
      perform_summary_cleanup

      log_cleanup_summary
      record_run
      raise @failures.first[:error] if @failures.any?

      @stats
    end

    private

    # Runs one table's cleanup and records its count. A failure is logged and
    # held until every stage has run, so one table that cannot be cleaned does
    # not stop the others; each stage removes its own child rows or skips rows
    # that still have them, so none depends on an earlier stage succeeding.
    def run_stage(group, name)
      @stats[group][name] = yield
    rescue StandardError => e
      @stats[group][name] = 0
      @failures << { stage: "#{name} (#{group})", error: e }
      RailsPulse.logger.error "Cleanup stage #{name} (#{group}) failed: #{e.class}: #{e.message}"
    end

    # Deletes the relation's rows in statements of at most BATCH_SIZE rows,
    # choosing each batch inside the database. `order_column` decides which
    # rows go first; `limit` stops after that many rows.
    def delete_in_batches(relation, order_column: nil, limit: nil)
      relation = relation.order(order_column => :asc) if order_column
      deleted = 0

      loop do
        batch_size = limit ? [ BATCH_SIZE, limit - deleted ].min : BATCH_SIZE
        break if batch_size <= 0

        count = relation.limit(batch_size).delete_all
        deleted += count
        break if count < batch_size
      end

      deleted
    end

    # Deletes parent rows oldest first, removing each batch's child rows before
    # the parents — there is no ON DELETE CASCADE on the foreign keys. Returns
    # the number of parent rows deleted.
    def delete_parents_in_batches(parents, order_column:, children:, foreign_key:, limit: nil)
      deleted = 0

      loop do
        batch_size = limit ? [ PARENT_BATCH_SIZE, limit - deleted ].min : PARENT_BATCH_SIZE
        break if batch_size <= 0

        ids = parents.order(order_column => :asc).limit(batch_size).pluck(:id)
        break if ids.empty?

        delete_in_batches(children.where(foreign_key => ids))
        deleted += parents.where(id: ids).delete_all
        break if ids.size < batch_size
      end

      deleted
    end

    def cleanup_enabled?
      @config.archiving_enabled
    end

    def perform_time_based_cleanup
      return unless @config.full_retention_period

      # Enforce a 1-hour minimum so records always have time to be summarized
      # before deletion, regardless of how short full_retention_period is set.
      cutoff_time = [ @config.full_retention_period.ago, 1.hour.ago ].min
      RailsPulse.logger.info "Time-based cleanup: removing records older than #{cutoff_time}"

      # Clean up in order that respects foreign key constraints
      run_stage(:time_based, :operations) { cleanup_operations_by_time(cutoff_time) }
      run_stage(:time_based, :job_runs)   { cleanup_job_runs_by_time(cutoff_time) }
      run_stage(:time_based, :requests)   { cleanup_requests_by_time(cutoff_time) }
      # Rollups substitute for the raw rows detail capture never wrote, and
      # BackfillSummariesJob reads them, so they live exactly as long as raw
      # requests do.
      run_stage(:time_based, :rollups)    { cleanup_rollups_by_time(cutoff_time) } if rollups_table_exists?
      run_stage(:time_based, :queries)    { cleanup_queries_by_time(cutoff_time) }
      run_stage(:time_based, :routes)     { cleanup_routes_by_time(cutoff_time) }
      run_stage(:time_based, :jobs)       { cleanup_jobs_by_time(cutoff_time) }
      run_stage(:time_based, :orphaned_baselines) { cleanup_orphaned_baselines } if baselines_table_exists?
      if exception_tables_exist?
        run_stage(:time_based, :exception_occurrences) { cleanup_exception_occurrences_by_time(cutoff_time) }
        run_stage(:time_based, :exception_groups)      { cleanup_orphaned_exception_groups }
      end
    end

    # event_retention_exempt_kinds are rows a writer updates in place, which
    # must survive so "last ran" never becomes "never ran"
    def perform_event_cleanup
      return unless @config.event_retention_period
      return unless RailsPulse::Event.table_available?

      cutoff_time = [ @config.event_retention_period.ago, 1.hour.ago ].min
      run_stage(:time_based, :events) do
        delete_in_batches(
          RailsPulse::Event
            .where.not(kind: @config.event_retention_exempt_kinds)
            .where(occurred_at: ...cutoff_time)
        )
      end
    end

    def perform_count_based_cleanup
      return unless @config.max_table_records&.any?

      RailsPulse.logger.info "Count-based cleanup: enforcing table record limits"

      # Clean up in order that respects foreign key constraints
      run_stage(:count_based, :operations) { cleanup_operations_by_count }
      run_stage(:count_based, :job_runs)   { cleanup_job_runs_by_count }
      run_stage(:count_based, :requests)   { cleanup_requests_by_count }
      run_stage(:count_based, :queries)    { cleanup_queries_by_count }
      run_stage(:count_based, :routes)     { cleanup_routes_by_count }
      run_stage(:count_based, :jobs)       { cleanup_jobs_by_count }
      run_stage(:count_based, :orphaned_baselines) { cleanup_orphaned_baselines } if baselines_table_exists?
      if exception_tables_exist?
        run_stage(:count_based, :exception_occurrences)     { cleanup_exception_occurrences_by_count }
        run_stage(:count_based, :exception_groups)          { cleanup_exception_groups_by_count }
        run_stage(:count_based, :orphaned_exception_groups) { cleanup_orphaned_exception_groups }
      end
      if deployments_table_exists?
        run_stage(:count_based, :deployments) { cleanup_deployments_by_count }
      end
    end

    # Deployments are markers, not measurements, so they are never pruned by
    # age — a marker from before the retention window still explains a
    # summary row. They are capped by count so the token-authenticated
    # create endpoint cannot grow the table without bound.
    def cleanup_deployments_by_count
      cleanup_by_count(RailsPulse::Deployment, :rails_pulse_deployments, order_column: :started_at)
    end

    def deployments_table_exists?
      RailsPulse::ApplicationRecord.connection.table_exists?(:rails_pulse_deployments)
    end

    # Shared helper: delete oldest records beyond a configured max count
    def cleanup_by_count(model_class, table_key, order_column:, scope: nil)
      max_records = @config.max_table_records[table_key]
      return 0 unless max_records

      relation = scope || model_class
      overage = relation.count - max_records
      return 0 if overage <= 0

      delete_in_batches(relation, order_column: order_column, limit: overage)
    end

    # Time-based cleanup methods

    def cleanup_operations_by_time(cutoff_time)
      delete_in_batches(RailsPulse::Operation.where("occurred_at < ?", cutoff_time), order_column: :occurred_at)
    end

    def cleanup_requests_by_time(cutoff_time)
      delete_parents_in_batches(
        RailsPulse::Request.where("occurred_at < ?", cutoff_time),
        order_column: :occurred_at,
        children: RailsPulse::Operation,
        foreign_key: :request_id
      )
    end

    # A rollup row covers a whole hour, so only hours that ended before the
    # cutoff go: the hour the cutoff falls in may not be summarized yet, and
    # its summary needs every rollup to count the folded traffic.
    def cleanup_rollups_by_time(cutoff_time)
      delete_in_batches(
        RailsPulse::Rollup.where("period_start <= ?", cutoff_time - 1.hour),
        order_column: :period_start
      )
    end

    def cleanup_queries_by_time(cutoff_time)
      delete_in_batches(
        orphaned_queries_scope.where("created_at < ?", cutoff_time)
      )
    end

    def cleanup_routes_by_time(cutoff_time)
      delete_in_batches(
        orphaned_routes_scope.where("created_at < ?", cutoff_time)
      )
    end

    def cleanup_job_runs_by_time(cutoff_time)
      delete_parents_in_batches(
        RailsPulse::JobRun.where("occurred_at < ?", cutoff_time),
        order_column: :occurred_at,
        children: RailsPulse::Operation,
        foreign_key: :job_run_id
      )
    end

    def cleanup_jobs_by_time(cutoff_time)
      delete_in_batches(
        RailsPulse::Job
          .where("created_at < ?", cutoff_time)
          .where("NOT EXISTS (SELECT 1 FROM rails_pulse_job_runs WHERE rails_pulse_job_runs.job_id = rails_pulse_jobs.id)")
      )
    end

    # Count-based cleanup methods (complex cases that need custom scoping)

    # Only operations from periods that have already been summarized are
    # deleted, so count-based cleanup never removes data the summary job has
    # not yet aggregated.
    def cleanup_operations_by_count
      cutoff = summarized_cutoff
      return 0 unless cutoff

      cleanup_by_count(
        RailsPulse::Operation,
        :rails_pulse_operations,
        order_column: :occurred_at,
        scope: RailsPulse::Operation.where("occurred_at < ?", cutoff)
      )
    end

    def cleanup_requests_by_count
      max_records = @config.max_table_records[:rails_pulse_requests]
      return 0 unless max_records

      # Only delete requests from periods that have already been summarized
      cutoff = summarized_cutoff
      return 0 unless cutoff

      overage = RailsPulse::Request.count - max_records
      return 0 if overage <= 0

      delete_parents_in_batches(
        RailsPulse::Request.where("occurred_at < ?", cutoff),
        order_column: :occurred_at,
        children: RailsPulse::Operation,
        foreign_key: :request_id,
        limit: overage
      )
    end

    def cleanup_job_runs_by_count
      max_records = @config.max_table_records[:rails_pulse_job_runs]
      return 0 unless max_records

      overage = RailsPulse::JobRun.count - max_records
      return 0 if overage <= 0

      delete_parents_in_batches(
        RailsPulse::JobRun,
        order_column: :occurred_at,
        children: RailsPulse::Operation,
        foreign_key: :job_run_id,
        limit: overage
      )
    end

    def cleanup_queries_by_count
      cleanup_by_count(RailsPulse::Query, :rails_pulse_queries, order_column: :created_at, scope: orphaned_queries_scope)
    end

    def cleanup_routes_by_count
      cleanup_by_count(RailsPulse::Route, :rails_pulse_routes, order_column: :created_at, scope: orphaned_routes_scope)
    end

    # A route or query with rollup rows is still feeding hourly summaries
    # (detail capture folded its traffic instead of persisting it), so it is
    # not an orphan until its rollups are pruned.
    def orphaned_queries_scope
      scope = RailsPulse::Query.where(
        "NOT EXISTS (SELECT 1 FROM rails_pulse_operations WHERE rails_pulse_operations.query_id = rails_pulse_queries.id)"
      )
      if rollups_table_exists?
        scope = scope.where(
          "NOT EXISTS (SELECT 1 FROM rails_pulse_rollups WHERE rails_pulse_rollups.rollupable_type = 'RailsPulse::Query' AND rails_pulse_rollups.rollupable_id = rails_pulse_queries.id)"
        )
      end
      scope
    end

    def orphaned_routes_scope
      scope = RailsPulse::Route.where(
        "NOT EXISTS (SELECT 1 FROM rails_pulse_requests WHERE rails_pulse_requests.route_id = rails_pulse_routes.id)"
      )
      if rollups_table_exists?
        scope = scope.where(
          "NOT EXISTS (SELECT 1 FROM rails_pulse_rollups WHERE rails_pulse_rollups.rollupable_type = 'RailsPulse::Route' AND rails_pulse_rollups.rollupable_id = rails_pulse_routes.id)"
        )
      end
      scope
    end

    def rollups_table_exists?
      RailsPulse::Rollup.table_available?
    end

    def cleanup_jobs_by_count
      scope = RailsPulse::Job.where(
        "NOT EXISTS (SELECT 1 FROM rails_pulse_job_runs WHERE rails_pulse_job_runs.job_id = rails_pulse_jobs.id)"
      )
      cleanup_by_count(RailsPulse::Job, :rails_pulse_jobs, order_column: :created_at, scope: scope)
    end

    def exception_tables_exist?
      connection = RailsPulse::ApplicationRecord.connection
      connection.table_exists?(:rails_pulse_exception_groups) &&
        connection.table_exists?(:rails_pulse_exception_occurrences)
    end

    def cleanup_exception_occurrences_by_time(cutoff_time)
      delete_in_batches(
        exception_occurrences_cleanup_scope.where("occurred_at < ?", cutoff_time),
        order_column: :occurred_at
      )
    end

    def cleanup_exception_occurrences_by_count
      cleanup_by_count(
        RailsPulse::ExceptionOccurrence,
        :rails_pulse_exception_occurrences,
        order_column: :occurred_at,
        scope: exception_occurrences_cleanup_scope
      )
    end

    # Preserve exempts a group from all automatic cleanup, including its
    # occurrence rows — otherwise a preserved group can lose its backtraces.
    def exception_occurrences_cleanup_scope
      preserved_ids = RailsPulse::ExceptionGroup.where(preserve: true).select(:id)
      RailsPulse::ExceptionOccurrence.where.not(exception_group_id: preserved_ids)
    end

    # Prune the oldest deletable groups when over the configured cap. Preserved
    # and ignored groups are outside the cap: counting them would make a cap
    # that they alone fill impossible to satisfy, so every run would trim the
    # deletable groups for no gain (decision 0017). Child occurrences must be
    # deleted first — there is no ON DELETE CASCADE on the FK.
    def cleanup_exception_groups_by_count
      max_records = @config.max_table_records[:rails_pulse_exception_groups]
      return 0 unless max_records

      scope = RailsPulse::ExceptionGroup.where(preserve: false).where.not(status: "ignored")
      overage = scope.count - max_records
      return 0 if overage <= 0

      delete_parents_in_batches(
        scope,
        order_column: :last_seen_at,
        children: RailsPulse::ExceptionOccurrence,
        foreign_key: :exception_group_id,
        limit: overage
      )
    end

    # Delete groups whose last occurrence was removed — the orphan check and
    # the delete are one statement per batch, so no orphan can be deleted while
    # a concurrent occurrence is being inserted.
    # preserve: true and ignored groups are never deleted automatically.
    def cleanup_orphaned_exception_groups
      delete_in_batches(
        RailsPulse::ExceptionGroup
          .where(preserve: false)
          .where.not(status: "ignored")
          .where("NOT EXISTS (SELECT 1 FROM rails_pulse_exception_occurrences WHERE rails_pulse_exception_occurrences.exception_group_id = rails_pulse_exception_groups.id)")
      )
    end

    # Routes, queries and jobs are removed with delete_all, which skips their
    # has_one :baseline callback, so a removed subject's baseline goes here.
    def cleanup_orphaned_baselines
      RailsPulse::Baseline::SUBJECT_TYPES.sum do |subject_type|
        subject_table = subject_type.constantize.table_name
        delete_in_batches(
          RailsPulse::Baseline
            .where(subject_type: subject_type)
            .where("NOT EXISTS (SELECT 1 FROM #{subject_table} WHERE #{subject_table}.id = rails_pulse_baselines.subject_id)")
        )
      end
    end

    def baselines_table_exists?
      RailsPulse::ApplicationRecord.connection.table_exists?(:rails_pulse_baselines)
    end

    def perform_summary_cleanup
      # Hourly summaries back the 1-day time range view and set how precisely
      # Operations::ChangePoint can place a change. Beyond this cutoff the finest
      # answer available is a day, so raising `hourly_summary_retention` is what
      # buys hour-accurate change points further back — at the cost of summary
      # table growth. Day, week and month summaries are never pruned.
      cutoff = @config.hourly_summary_retention.ago
      run_stage(:time_based, :hourly_summaries) do
        delete_in_batches(
          RailsPulse::Summary.where(period_type: "hour").where("period_start < ?", cutoff),
          order_column: :period_start
        )
      end
    end

    # rails_pulse:status reads this to tell whether cleanup is scheduled. A
    # failure to record must not turn a successful cleanup into a failed one.
    def record_run
      return unless RailsPulse::Event.table_available?

      RailsPulse::CleanupRun.record!(stats: @stats, failed_stages: @failures.map { |failure| failure[:stage] })
    rescue StandardError => e
      RailsPulse.logger.error "Could not record the cleanup run: #{e.class}: #{e.message}"
    end

    # Returns the period_end of the most recent completed hourly overall-request
    # summary, or nil if the summary job has never run. Records with occurred_at
    # before this timestamp have been fully aggregated and are safe to delete.
    def summarized_cutoff
      @summarized_cutoff ||= RailsPulse::Summary
        .where(summarizable_type: "RailsPulse::Request", summarizable_id: 0, period_type: "hour")
        .maximum(:period_end)
    end

    def log_cleanup_summary
      total_time_based = @stats[:time_based].values.sum
      total_count_based = @stats[:count_based].values.sum
      @stats[:total_deleted] = total_time_based + total_count_based

      if @failures.any?
        RailsPulse.logger.error "Cleanup finished with #{@failures.size} failed stage(s): #{@failures.map { |failure| failure[:stage] }.join(', ')}"
      end

      RailsPulse.logger.info "Cleanup completed:"
      RailsPulse.logger.info "  Time-based: #{total_time_based} records deleted"
      RailsPulse.logger.info "  Count-based: #{total_count_based} records deleted"
      RailsPulse.logger.info "  Total: #{@stats[:total_deleted]} records deleted"

      if @stats[:total_deleted] > 0
        RailsPulse.logger.info "  Breakdown:"
        @stats[:time_based].each do |table, count|
          RailsPulse.logger.info "    #{table} (time): #{count}" if count > 0
        end
        @stats[:count_based].each do |table, count|
          RailsPulse.logger.info "    #{table} (count): #{count}" if count > 0
        end
      end
    end
  end
end
