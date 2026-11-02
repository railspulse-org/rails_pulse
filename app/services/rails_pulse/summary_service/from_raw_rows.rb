module RailsPulse
  class SummaryService
    # Summary rows for an hour, computed from raw requests, operations, job
    # runs and exception occurrences.
    #
    # Each kind is read with one query, sorted by summarizable and then
    # duration so every summarizable's durations arrive as one consecutive,
    # already-sorted run; the overall request row and the per-route rows
    # share a single read. The operations read is served entirely by the
    # (occurred_at, query_id, duration) covering index, so its cost is
    # bounded by the hour however much history is retained — without it the
    # read does scattered fetches of wide rows (actual_sql is unbounded) and
    # degrades as the table outgrows the database's cache. Memory is bounded
    # by one hour's rows, and the hour costs one query per kind however many
    # routes, queries or jobs it saw. Percentiles are exact.
    #
    # When detail capture folded part of the hour into rails_pulse_rollups
    # (decision 0022), each subject's raw rows are merged with its rollups:
    # counts, sums, min, max, averages and stddev stay exact, and percentiles
    # come from the rollups' histograms walked together with the exactly-kept
    # durations. A subject with no rollups takes the plain path, so with
    # detail capture off nothing changes.
    #
    # Rows carry the summarizable and its metrics; SummaryService adds the
    # period columns.
    class FromRawRows
      def initialize(time_range)
        @time_range = time_range
      end

      # Always exactly one row, even for an empty hour (see SummaryService).
      def request_rows
        durations = request_data.map { |_, duration, _| duration }.compact.sort
        statuses = request_data.map { |_, _, status| status }
        rollup = merge_rollups(route_rollups.values)

        [ row("RailsPulse::Request", 0).merge(duration_metrics(durations, rollup), status_metrics(statuses, rollup)) ]
      end

      def route_rows
        raw_by_route = request_data
          .slice_when { |previous, current| previous.first != current.first }
          .to_h { |rows| [ rows.first.first, rows ] }

        (raw_by_route.keys | route_rollups.keys).map do |route_id|
          rows = raw_by_route[route_id] || []
          durations = rows.map { |_, duration, _| duration }
          statuses = rows.map { |_, _, status| status }
          rollup = route_rollups[route_id]

          row("RailsPulse::Route", route_id).merge(
            duration_metrics(durations, rollup),
            status_metrics(statuses, rollup)
          )
        end
      end

      def query_rows
        raw_by_query = rows_by_summarizable(Operation.where(occurred_at: @time_range), :query_id).to_h

        (raw_by_query.keys | query_rollups.keys).filter_map do |query_id|
          durations = (raw_by_query[query_id] || []).map(&:first).compact
          rollup = query_rollups[query_id]
          next if durations.empty? && rollup.nil?

          row("RailsPulse::Query", query_id).merge(duration_metrics(durations, rollup))
        end
      end

      def job_rows
        scope = JobRun.where(occurred_at: @time_range).where(status: JobRun::FINAL_STATUSES)
        runs_by_job = rows_by_summarizable(scope, :job_id, :status)
        return [] if runs_by_job.empty?

        # A run whose job row has gone (count-based cleanup) has nothing to
        # summarize against.
        known_job_ids = Job.where(id: runs_by_job.map(&:first)).pluck(:id).to_set

        runs_by_job.filter_map do |job_id, runs|
          next unless known_job_ids.include?(job_id)

          durations = runs.map(&:first).compact.map(&:to_f)
          next if durations.empty?

          statuses = runs.map(&:second)
          row("RailsPulse::Job", job_id).merge(
            Metrics.duration(durations),
            count: runs.size,
            error_count: statuses.count { |s| s != "success" },
            success_count: statuses.count { |s| s == "success" }
          )
        end
      end

      # Per-group counts plus an all-groups row (id 0), so the dashboard can
      # chart total exception volume without loading one series per group.
      def exception_rows
        counts = ExceptionOccurrence.where(occurred_at: @time_range).group(:exception_group_id).count
        return [] if counts.empty?

        rows = counts.map { |group_id, occurrences| row("RailsPulse::ExceptionGroup", group_id).merge(count: occurrences) }
        rows << row("RailsPulse::ExceptionGroup", 0).merge(count: counts.values.sum)
      end

      private

      # Everything one subject's rollup rows add up to, with sums as floats.
      MergedRollup = Struct.new(
        :count, :error_count,
        :status_2xx, :status_3xx, :status_4xx, :status_5xx,
        :sum_duration, :sum_square_duration, :min_duration, :max_duration,
        :histogram_counts
      )

      def row(summarizable_type, summarizable_id)
        { summarizable_type: summarizable_type, summarizable_id: summarizable_id }
      end

      # Identical to Metrics.duration when the subject has no rollups.
      def duration_metrics(sorted_durations, rollup)
        return Metrics.duration(sorted_durations) if rollup.nil?

        count = sorted_durations.size + rollup.count
        total = sorted_durations.sum + rollup.sum_duration
        sum_of_squares = sorted_durations.sum { |d| d * d } + rollup.sum_square_duration
        avg = count.positive? ? total.to_f / count : 0

        {
          count: count,
          avg_duration: avg,
          min_duration: [ sorted_durations.first, rollup.min_duration ].compact.min,
          max_duration: [ sorted_durations.last, rollup.max_duration ].compact.max,
          total_duration: total,
          p50_duration: merged_percentile(rollup, sorted_durations, 0.5),
          p90_duration: merged_percentile(rollup, sorted_durations, 0.9),
          p95_duration: merged_percentile(rollup, sorted_durations, 0.95),
          p99_duration: merged_percentile(rollup, sorted_durations, 0.99),
          # Each value as its own group makes this the exact sample stddev
          # from N, sum(x) and sum(x^2).
          stddev_duration: Statistics.pooled_stddev(
            count: count, within_sum: 0,
            weighted_mean_sum: total, weighted_square_sum: sum_of_squares
          )
        }
      end

      def status_metrics(statuses, rollup)
        return Metrics.status(statuses) if rollup.nil?

        base = Metrics.status(statuses)
        {
          error_count: base[:error_count] + rollup.error_count,
          success_count: base[:success_count] + (rollup.count - rollup.error_count),
          status_2xx: base[:status_2xx] + rollup.status_2xx,
          status_3xx: base[:status_3xx] + rollup.status_3xx,
          status_4xx: base[:status_4xx] + rollup.status_4xx,
          status_5xx: base[:status_5xx] + rollup.status_5xx
        }
      end

      def merged_percentile(rollup, sorted_durations, percentile)
        DurationHistogram.percentile(
          counts: rollup.histogram_counts,
          exact_sorted: sorted_durations,
          percentile: percentile
        )
      end

      def route_rollups
        rollup_data.fetch("RailsPulse::Route", {})
      end

      def query_rollups
        rollup_data.fetch("RailsPulse::Query", {})
      end

      # { rollupable_type => { rollupable_id => MergedRollup } } for the hour,
      # each subject's writer rows already summed. Empty on installs that have
      # not migrated the table yet.
      def rollup_data
        @rollup_data ||= Rollup.table_available? ? load_rollups : {}
      end

      def load_rollups
        Rollup
          .where(period_start: @time_range)
          .pluck(:rollupable_type, :rollupable_id, :count, :error_count,
                 :status_2xx, :status_3xx, :status_4xx, :status_5xx,
                 :sum_duration, :sum_square_duration, :min_duration, :max_duration,
                 :histogram)
          .group_by { |type, _id, *| type }
          .transform_values do |type_rows|
            type_rows
              .group_by { |_type, id, *| id }
              .transform_values { |subject_rows| merge_rollup_rows(subject_rows) }
          end
      end

      def merge_rollup_rows(rows)
        merged = MergedRollup.new(0, 0, 0, 0, 0, 0, 0.0, 0.0, nil, nil, {})
        rows.each do |_type, _id, count, error_count, s2, s3, s4, s5, sum, sum_sq, min, max, histogram|
          merged.count += count
          merged.error_count += error_count
          merged.status_2xx += s2
          merged.status_3xx += s3
          merged.status_4xx += s4
          merged.status_5xx += s5
          merged.sum_duration += sum.to_f
          merged.sum_square_duration += sum_sq.to_f
          merged.min_duration = [ merged.min_duration, min&.to_f ].compact.min
          merged.max_duration = [ merged.max_duration, max&.to_f ].compact.max
          add_histogram(merged.histogram_counts, histogram)
        end
        merged
      end

      def add_histogram(accumulated, histogram_json)
        DurationHistogram.load(histogram_json).counts.each do |index, n|
          accumulated[index] = accumulated.fetch(index, 0) + n
        end
      end

      # The overall row folds every route's rollups into one.
      def merge_rollups(merged_rollups)
        return nil if merged_rollups.empty?

        combined = MergedRollup.new(0, 0, 0, 0, 0, 0, 0.0, 0.0, nil, nil, {})
        merged_rollups.each do |rollup|
          combined.count += rollup.count
          combined.error_count += rollup.error_count
          combined.status_2xx += rollup.status_2xx
          combined.status_3xx += rollup.status_3xx
          combined.status_4xx += rollup.status_4xx
          combined.status_5xx += rollup.status_5xx
          combined.sum_duration += rollup.sum_duration
          combined.sum_square_duration += rollup.sum_square_duration
          combined.min_duration = [ combined.min_duration, rollup.min_duration ].compact.min
          combined.max_duration = [ combined.max_duration, rollup.max_duration ].compact.max
          rollup.histogram_counts.each do |index, n|
            combined.histogram_counts[index] = combined.histogram_counts.fetch(index, 0) + n
          end
        end
        combined
      end

      # One read serves the overall request row and every route's. route_id
      # and duration are NOT NULL on requests, so ordering by (route_id,
      # duration) hands each route its durations already sorted.
      def request_data
        @request_data ||= Request
          .where(occurred_at: @time_range)
          .order(:route_id, :duration)
          .pluck(:route_id, :duration, :status)
      end

      # [[summarizable_id, [[duration, *extra_columns], ...]], ...], with
      # each summarizable's rows in ascending duration order (NULL durations
      # land at one end or the other depending on the database; callers
      # compact them).
      def rows_by_summarizable(scope, column, *extra_columns)
        scope
          .where.not(column => nil)
          .order(column, :duration)
          .pluck(column, :duration, *extra_columns)
          .slice_when { |previous, current| previous.first != current.first }
          .map { |rows| [ rows.first.first, rows.map { |row| row.drop(1) } ] }
      end
    end
  end
end
