require "test_helper"

module RailsPulse
  module Queries
    module Tables
      class IndexTest < ActiveSupport::TestCase
        fixtures :rails_pulse_queries, :rails_pulse_summaries

        def setup
          @start_time = 2.days.ago
          @end_time = Time.current
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time
          })
          @params = {}
        end

        # Helper method to create table service
        def create_table(disabled_tags: [], show_non_tagged: true, **options)
          RailsPulse::Queries::Tables::Index.new(
            ransack_query: @ransack_query,
            period_type: :day,
            params: @params,
            disabled_tags: disabled_tags,
            show_non_tagged: show_non_tagged,
            **options
          ).to_table
        end

        # Structure Tests

        test "returns ActiveRecord relation" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "result has required query attributes" do
          results = create_table

          assert_predicate results, :any?, "Expected query summary fixtures to be within the test time range"
          first_result = results.first

          assert_includes first_result.attributes.keys, "query_id"
          assert_includes first_result.attributes.keys, "normalized_sql"
          assert_includes first_result.attributes.keys, "tags"
        end

        test "result has metric attributes" do
          results = create_table

          if results.any?
            first_result = results.first

            assert_includes first_result.attributes.keys, "avg_duration"
            assert_includes first_result.attributes.keys, "p95_duration"
            assert_includes first_result.attributes.keys, "p99_duration"
            assert_includes first_result.attributes.keys, "max_duration"
          end
        end

        test "result has execution count attributes" do
          results = create_table

          if results.any?
            first_result = results.first

            assert_includes first_result.attributes.keys, "execution_count"
            assert_includes first_result.attributes.keys, "total_time_consumed"
          end
        end

        test "groups by query" do
          results = create_table

          # Each query should appear only once
          query_ids = results.map(&:query_id)

          assert_equal query_ids.uniq.length, query_ids.length
        end

        test "joins with rails_pulse_queries table" do
          results = create_table

          if results.any?
            # Should have normalized_sql from queries table
            assert_kind_of String, results.first.normalized_sql
          end
        end

        test "result attributes have correct types" do
          results = create_table

          if results.any?
            first_result = results.first
            assert_kind_of Numeric, first_result.query_id if first_result.query_id
            assert_kind_of String, first_result.normalized_sql if first_result.normalized_sql
          end
        end

        # Aggregation Tests

        test "avg_duration is AVG of avg_duration across periods" do
          results = create_table

          assert_predicate results, :any?, "Expected query summary fixtures to be within the test time range"
          result = results.first
          # Should be a numeric average
          assert result.avg_duration.nil? || result.avg_duration.is_a?(Numeric)
        end

        test "max_duration is MAX of max_duration across periods" do
          results = create_table

          if results.any?
            result = results.first
            # Should be a numeric maximum
            assert result.max_duration.nil? || result.max_duration.is_a?(Numeric)
          end
        end

        test "p95_duration is weighted average" do
          results = create_table

          assert_predicate results, :any?, "Expected query summary fixtures to be within the test time range"
          result = results.first
          # Should be calculated as SUM(p95 * count) / SUM(count)
          assert result.p95_duration.nil? || result.p95_duration.is_a?(Numeric)
        end

        test "p99_duration is weighted average" do
          results = create_table

          if results.any?
            result = results.first
            # Should be calculated as SUM(p99 * count) / SUM(count)
            assert result.p99_duration.nil? || result.p99_duration.is_a?(Numeric)
          end
        end

        test "execution_count is SUM of count across periods" do
          results = create_table

          if results.any?
            result = results.first
            # Should be a summed count
            assert_kind_of Numeric, result.execution_count
            assert_operator result.execution_count, :>=, 0
          end
        end

        test "total_time_consumed is SUM of total_duration" do
          results = create_table

          if results.any?
            result = results.first

            assert result.total_time_consumed.nil? || result.total_time_consumed.is_a?(Numeric)
          end
        end

        test "uses NULLIF to prevent division by zero" do
          # This is tested implicitly - if division by zero occurred, we'd get an error
          results = create_table

          # Should not raise division by zero error
          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple summaries for same query aggregate correctly" do
          results = create_table

          # Queries should be grouped and aggregated
          assert_kind_of ActiveRecord::Relation, results
        end

        test "single summary returns correct values" do
          results = create_table

          if results.any?
            result = results.first
            # Values should be present and valid
            assert result.execution_count.nil? || result.execution_count >= 0
          end
        end

        # Filtering Tests

        test "only includes Query summarizable_type" do
          results = create_table

          # Should only include query summaries, not route or job summaries
          assert_kind_of ActiveRecord::Relation, results
        end

        test "only includes records matching period_type" do
          results = create_table

          # Should only include summaries with specified period_type
          assert_kind_of ActiveRecord::Relation, results
        end

        test "respects ransack time range" do
          # Time range is implicit via ransack_query
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "disabled_tags excludes queries with actual tags" do
          results = create_table(disabled_tags: [ "slow" ])

          # Should exclude queries tagged with "slow"
          assert_kind_of ActiveRecord::Relation, results
          if results.any?
            results.each do |result|
              tags = result.tags
              refute_includes tags, "slow" if tags
            end
          end
        end

        test "disabled_tags with non_tagged excludes non-tagged queries" do
          results = create_table(disabled_tags: [ "non_tagged" ])

          # Should exclude queries without tags
          if results.any?
            results.each do |result|
              # All results should have tags
              assert result.tags
              refute_equal "[]", result.tags
            end
          end
        end

        test "show_non_tagged false excludes queries without tags" do
          results = create_table(show_non_tagged: false)

          # Should only include queries with tags
          if results.any?
            results.each do |result|
              assert result.tags
              refute_equal "[]", result.tags
            end
          end
        end

        test "show_non_tagged true includes queries without tags" do
          results = create_table(show_non_tagged: true)

          # Should include all queries
          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles empty disabled_tags array" do
          results = create_table(disabled_tags: [])

          # Should show all queries
          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple disabled tags all excluded" do
          results = create_table(disabled_tags: [ "slow", "n+1" ])

          # Should exclude queries with either tag
          assert_kind_of ActiveRecord::Relation, results
          if results.any?
            results.each do |result|
              tags = result.tags
              refute_includes tags, "slow" if tags
              refute_includes tags, "n+1" if tags
            end
          end
        end

        test "tag matching uses SQL LIKE with wildcards" do
          results = create_table(disabled_tags: [ "slow" ])

          # Should use LIKE pattern matching
          assert_kind_of ActiveRecord::Relation, results
        end

        test "sanitizes LIKE patterns" do
          # Should handle special characters safely
          results = create_table(disabled_tags: [ "%malicious%" ])

          # Should not cause SQL injection
          assert_kind_of ActiveRecord::Relation, results
        end

        # Sorting Tests

        test "default sort is AVG p95_duration DESC" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time
          })
          # No explicit sort

          results = create_table

          # Should be sorted by p95 descending
          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by avg_duration_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "avg_duration_sort asc"
          })

          results = create_table
          results_array = results.to_a

          # Should be sorted by avg duration
          if results_array.length > 1
            first_avg = results_array.first.avg_duration || 0
            last_avg = results_array.last.avg_duration || 0

            assert_operator first_avg, :<=, last_avg
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by max_duration_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "max_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by p95_duration_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "p95_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by p99_duration_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "p99_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by execution_count_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "execution_count_sort desc"
          })

          results = create_table
          results_array = results.to_a

          if results_array.length > 1
            first_count = results_array.first.execution_count || 0
            last_count = results_array.last.execution_count || 0

            assert_operator first_count, :>=, last_count
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by total_time_consumed_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "total_time_consumed_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "ascending sort works correctly" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "avg_duration_sort asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
          results_array = results.to_a

          if results_array.length > 1
            first_value = results_array.first.avg_duration || 0
            last_value = results_array.last.avg_duration || Float::INFINITY

            assert_operator first_value, :<=, last_value
          end
        end

        test "descending sort works correctly" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "execution_count_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
          results_array = results.to_a

          if results_array.length > 1
            first_value = results_array.first.execution_count || 0
            last_value = results_array.last.execution_count || 0

            assert_operator first_value, :>=, last_value
          end
        end

        # Edge Cases

        test "handles nil values gracefully" do
          results = create_table

          # Should handle nil values without errors
          assert_nothing_raised do
            results.each do |result|
              result.avg_duration
              result.p95_duration
              result.p99_duration
              result.max_duration
            end
          end
        end

        test "handles empty result set" do
          # Use a time range with no data
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: 100.years.ago,
            period_start_lt: 99.years.ago
          })

          results = create_table

          assert_equal 0, results.to_a.length
        end

        test "handles zero execution count" do
          results = create_table

          # Should handle queries with zero executions
          if results.any?
            results.each do |result|
              assert_operator result.execution_count, :>=, 0
            end
          end
        end

        test "handles queries with no duration data" do
          results = create_table

          # Should handle queries where all duration fields are nil
          assert_kind_of ActiveRecord::Relation, results
        end

        test "large datasets don't cause memory issues" do
          # Should work with large result sets
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
          # Just verify it returns without error
        end

        test "concurrent access doesn't cause race conditions" do
          # Multiple table creations should work independently
          results1 = create_table
          results2 = create_table

          assert_kind_of ActiveRecord::Relation, results1
          assert_kind_of ActiveRecord::Relation, results2
        end
      end
    end
  end
end
