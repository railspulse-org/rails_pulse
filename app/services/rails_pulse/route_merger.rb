module RailsPulse
  # Merges source into target: combine http_methods, reassign requests and summaries, destroy source.
  # Used when two routes would collide on the unique [controller_action, path] index.
  class RouteMerger
    METRIC_SUM_COLUMNS = %w[
      count error_count success_count total_duration
      status_2xx status_3xx status_4xx status_5xx
    ].freeze

    WEIGHTED_AVG_COLUMNS = [ "avg_duration", *SummaryService::PERCENTILES.keys.map(&:to_s) ].freeze

    # A rollup bucket for hour H keeps replace-upserting its row until the
    # first drain after H + 1 hour + STALE_HOUR_GRACE retires it; drains come
    # at most FLUSH_INTERVAL apart while the writer sees traffic. Rows younger
    # than this may still be rewritten by a live writer and cannot be moved.
    LIVE_ROLLUP_WINDOW = 1.hour + RollupAccumulator::STALE_HOUR_GRACE +
      (2 * RollupAccumulator::FLUSH_INTERVAL)

    def self.call(target:, source:)
      new(target, source).call
    end

    def initialize(target, source)
      @target = target
      @source = source
    end

    def call
      return if @target.id == @source.id

      @source.http_methods_list.each { |m| @target.add_http_method(m) }
      RailsPulse::Route.transaction do
        @source.requests.update_all(route_id: @target.id)
        reassign_or_merge_summaries!
        reassign_rollups!
        @source.destroy!
      end
    end

    private

    # Retired rollup rows move to the target under fresh writer ids. Keeping
    # the original id could collide with a target-route row the same writer
    # owns for the same hour; "merged:<row id>" is unique by construction and
    # never written again, so readers sum a moved row like any other.
    #
    # Rows inside LIVE_ROLLUP_WINDOW stay keyed to the source: their bucket's
    # next flush would re-insert the same cumulative totals under the source
    # id, double-counting the hour. Readers sum every rollup in an hour
    # whether or not its route still exists, so the stay-behind traffic still
    # counts in overall summaries — attributed to the merged-away route until
    # retention prunes it.
    def reassign_rollups!
      return unless RailsPulse::Rollup.table_available?

      RailsPulse::Rollup
        .where(rollupable_type: "RailsPulse::Route", rollupable_id: @source.id)
        .where(period_start: ...LIVE_ROLLUP_WINDOW.ago)
        .in_batches do |batch|
          batch.update_all([ "rollupable_id = ?, writer_id = #{merged_writer_id_sql}", @target.id ])
        end
    end

    # Cross-database "merged:<row id>" expression; MySQL has no || operator.
    def merged_writer_id_sql
      if RailsPulse::DatabaseAdapter.mysql?(RailsPulse::Rollup.connection)
        "CONCAT('merged:', id)"
      else
        "'merged:' || id"
      end
    end

    def reassign_or_merge_summaries!
      source_summaries = RailsPulse::Summary.where(
        summarizable_type: "RailsPulse::Route",
        summarizable_id: @source.id
      )

      source_summaries.find_each do |source_summary|
        target_summary = RailsPulse::Summary.find_by(
          summarizable_type: "RailsPulse::Route",
          summarizable_id: @target.id,
          period_type: source_summary.period_type,
          period_start: source_summary.period_start
        )

        if target_summary
          merge_summary_metrics!(target_summary, source_summary)
          source_summary.destroy!
        else
          source_summary.update_column(:summarizable_id, @target.id)
        end
      end
    end

    def merge_summary_metrics!(target_summary, source_summary)
      target_count = target_summary.count.to_i
      source_count = source_summary.count.to_i
      combined_count = target_count + source_count

      attrs = {}

      METRIC_SUM_COLUMNS.each do |column|
        next unless target_summary.has_attribute?(column)

        attrs[column] = target_summary.public_send(column).to_f + source_summary.public_send(column).to_f
      end

      if combined_count.positive?
        WEIGHTED_AVG_COLUMNS.each do |column|
          next unless target_summary.has_attribute?(column)

          target_value = target_summary.public_send(column)
          source_value = source_summary.public_send(column)
          next if target_value.nil? && source_value.nil?

          attrs[column] = (
            (target_value.to_f * target_count) + (source_value.to_f * source_count)
          ) / combined_count
        end
      end

      if target_summary.has_attribute?(:min_duration)
        mins = [ target_summary.min_duration, source_summary.min_duration ].compact
        attrs[:min_duration] = mins.min if mins.any?
      end

      if target_summary.has_attribute?(:max_duration)
        maxes = [ target_summary.max_duration, source_summary.max_duration ].compact
        attrs[:max_duration] = maxes.max if maxes.any?
      end

      target_summary.update_columns(attrs.merge(updated_at: Time.current))
    end
  end
end
