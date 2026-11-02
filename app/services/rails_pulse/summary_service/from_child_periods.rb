module RailsPulse
  class SummaryService
    # Summary rows for a day, week or month, rolled up from the summaries of
    # its child periods (hours for a day, days for a week or month) without
    # reading raw rows.
    #
    # The database combines the children in one GROUP BY, so Ruby receives
    # one row per summarizable however many child periods there are. Counts,
    # totals, averages, min, max, status counts and the standard deviation
    # combine exactly. Percentiles are the count-weighted average of the
    # children's, the same weighting Tables::Base applies when a dashboard
    # range spans several periods.
    #
    # Only plain SUM, MIN, MAX and arithmetic are used, so the query runs
    # unchanged on SQLite (which has no STDDEV or, without its math
    # extension, POWER), PostgreSQL and MySQL. Divisions happen in Ruby,
    # where integer sums cannot truncate them.
    #
    # Rows carry the summarizable and its metrics; SummaryService adds the
    # period columns.
    class FromChildPeriods
      TABLE = "rails_pulse_summaries".freeze
      STATUS_COLUMNS = %i[error_count success_count status_2xx status_3xx status_4xx status_5xx].freeze

      AGGREGATES = {
        count: "SUM(#{TABLE}.count)",
        total_duration: "SUM(#{TABLE}.total_duration)",
        min_duration: "MIN(#{TABLE}.min_duration)",
        max_duration: "MAX(#{TABLE}.max_duration)",
        **PERCENTILES.keys.flat_map { |column|
          [
            [ :"#{column}_weighted", "SUM(#{TABLE}.#{column} * #{TABLE}.count)" ],
            [ :"#{column}_weight", "SUM(CASE WHEN #{TABLE}.#{column} IS NOT NULL THEN #{TABLE}.count ELSE 0 END)" ]
          ]
        }.to_h,
        # The three sums Statistics.pooled_stddev needs.
        stddev_within_sum: "SUM((#{TABLE}.count - 1) * COALESCE(#{TABLE}.stddev_duration, 0) * COALESCE(#{TABLE}.stddev_duration, 0))",
        weighted_mean_sum: "SUM(#{TABLE}.count * #{TABLE}.avg_duration)",
        weighted_square_sum: "SUM(#{TABLE}.count * #{TABLE}.avg_duration * #{TABLE}.avg_duration)",
        **STATUS_COLUMNS.to_h { |column| [ column, "SUM(#{TABLE}.#{column})" ] }
      }.freeze

      # `child_starts` are the boundaries the children must start on. Rows in
      # the range that start elsewhere were written under a different
      # aggregation time zone; they overlap these and would be counted twice.
      def initialize(child_period_type, child_starts)
        @child_period_type = child_period_type
        @child_starts = child_starts
      end

      # Always exactly one row, even for an empty period (see SummaryService).
      def request_rows
        combined = combined_of("RailsPulse::Request")[0]

        [ row("RailsPulse::Request", 0).merge(duration_metrics(combined), status_metrics(combined)) ]
      end

      def route_rows
        combined_of("RailsPulse::Route").map do |route_id, combined|
          row("RailsPulse::Route", route_id).merge(duration_metrics(combined), status_metrics(combined))
        end
      end

      def query_rows
        combined_of("RailsPulse::Query").map do |query_id, combined|
          row("RailsPulse::Query", query_id).merge(duration_metrics(combined))
        end
      end

      def job_rows
        combined_by_job = combined_of("RailsPulse::Job")
        return [] if combined_by_job.empty?

        # A job whose row has gone (count-based cleanup) has nothing to
        # summarize against.
        known_job_ids = Job.where(id: combined_by_job.keys).pluck(:id).to_set

        combined_by_job.filter_map do |job_id, combined|
          next unless known_job_ids.include?(job_id)

          row("RailsPulse::Job", job_id).merge(
            duration_metrics(combined),
            status_metrics(combined).slice(:error_count, :success_count)
          )
        end
      end

      # The children already carry the all-groups row (id 0), which sums like
      # any other group.
      def exception_rows
        combined_of("RailsPulse::ExceptionGroup").map do |group_id, combined|
          row("RailsPulse::ExceptionGroup", group_id).merge(count: combined[:count].to_i)
        end
      end

      private

      def row(summarizable_type, summarizable_id)
        { summarizable_type: summarizable_type, summarizable_id: summarizable_id }
      end

      # { summarizable_type => { summarizable_id => { aggregate => value } } }.
      # Empty children (an idle hour's count-0 heartbeat) are left out; they
      # add nothing, and an idle period falls back to empty metrics.
      def combined_children
        @combined_children ||= Summary
          .where(period_type: @child_period_type, period_start: @child_starts)
          .where(count: 1..)
          .group(:summarizable_type, :summarizable_id)
          .pluck(:summarizable_type, :summarizable_id, *AGGREGATES.values.map { |sql| Arel.sql(sql) })
          .each_with_object({}) do |(type, id, *values), by_type|
            (by_type[type] ||= {})[id] = AGGREGATES.keys.zip(values).to_h
          end
      end

      # { summarizable_id => combined } for one summarizable type.
      def combined_of(summarizable_type)
        combined_children.fetch(summarizable_type, {})
      end

      def duration_metrics(combined)
        return Metrics.duration([]) unless combined

        count = combined[:count].to_i
        total = combined[:total_duration].to_f

        {
          count: count,
          # Count-weighted mean of the children's averages: identical to
          # total / count where every row has a duration (requests, routes,
          # queries), and consistent with the children for jobs, whose count
          # includes runs with no recorded duration (discarded runs) that
          # total / count would dilute the average with.
          avg_duration: combined[:weighted_mean_sum].to_f / count,
          min_duration: combined[:min_duration]&.to_f,
          max_duration: combined[:max_duration]&.to_f,
          total_duration: total,
          **PERCENTILES.keys.index_with { |column| weighted_percentile(combined, column) },
          stddev_duration: Statistics.pooled_stddev(
            count: count,
            within_sum: combined[:stddev_within_sum],
            weighted_mean_sum: combined[:weighted_mean_sum],
            weighted_square_sum: combined[:weighted_square_sum]
          )
        }
      end

      def weighted_percentile(combined, column)
        weight = combined[:"#{column}_weight"].to_f
        return nil if weight.zero?

        combined[:"#{column}_weighted"].to_f / weight
      end

      def status_metrics(combined)
        STATUS_COLUMNS.index_with { |column| combined ? combined[column].to_i : 0 }
      end
    end
  end
end
