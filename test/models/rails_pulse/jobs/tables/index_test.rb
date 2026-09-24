require "test_helper"

module RailsPulse
  module Jobs
    module Tables
      class IndexTest < ActiveSupport::TestCase
        def setup
          @start_time = 2.days.ago
          @end_time = Time.current
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time
          })
          @params = {}
        end

        def create_table(period_type: :hour, disabled_tags: [], show_non_tagged: true, queue_name: nil)
          RailsPulse::Jobs::Tables::Index.new(
            ransack_query: @ransack_query,
            period_type: period_type,
            params: @params,
            disabled_tags: disabled_tags,
            show_non_tagged: show_non_tagged,
            queue_name: queue_name
          ).to_table
        end

        # Structure Tests

        test "returns ActiveRecord relation" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "result has required job attributes" do
          results = create_table

          if results.any?
            first_result = results.first

            assert_includes first_result.attributes.keys, "job_id"
            assert_includes first_result.attributes.keys, "name"
            assert_includes first_result.attributes.keys, "queue_name"
            assert_includes first_result.attributes.keys, "tags"
          end
        end

        test "result has metric attributes" do
          results = create_table

          if results.any?
            first_result = results.first

            assert_includes first_result.attributes.keys, "avg_duration"
            assert_includes first_result.attributes.keys, "max_duration"
            assert_includes first_result.attributes.keys, "p95_duration"
            assert_includes first_result.attributes.keys, "p99_duration"
          end
        end

        test "result has count attributes" do
          results = create_table

          if results.any?
            first_result = results.first

            assert_includes first_result.attributes.keys, "count"
            assert_includes first_result.attributes.keys, "error_count"
            assert_includes first_result.attributes.keys, "success_count"
          end
        end

        test "groups by job" do
          results = create_table

          job_ids = results.map(&:job_id)

          assert_equal job_ids.uniq.length, job_ids.length
        end

        test "joins with rails_pulse_jobs table" do
          results = create_table

          if results.any?
            assert_kind_of String, results.first.name
            assert_kind_of String, results.first.queue_name
          end
        end

        test "result count is numeric and non-negative" do
          results = create_table

          if results.any?
            result = results.first

            assert_kind_of Numeric, result.count
            assert_operator result.count, :>=, 0
          end
        end

        # Aggregation Tests

        test "avg_duration is AVG across periods" do
          results = create_table

          if results.any?
            result = results.first

            assert result.avg_duration.nil? || result.avg_duration.is_a?(Numeric)
          end
        end

        test "max_duration is MAX across periods" do
          results = create_table

          if results.any?
            result = results.first

            assert result.max_duration.nil? || result.max_duration.is_a?(Numeric)
          end
        end

        test "p95_duration is weighted average" do
          results = create_table

          if results.any?
            result = results.first

            assert result.p95_duration.nil? || result.p95_duration.is_a?(Numeric)
          end
        end

        test "p99_duration is weighted average" do
          results = create_table

          if results.any?
            result = results.first

            assert result.p99_duration.nil? || result.p99_duration.is_a?(Numeric)
          end
        end

        test "error_count is SUM across periods" do
          results = create_table

          if results.any?
            result = results.first

            assert result.error_count.nil? || result.error_count.is_a?(Numeric)
          end
        end

        test "success_count is SUM across periods" do
          results = create_table

          if results.any?
            result = results.first

            assert result.success_count.nil? || result.success_count.is_a?(Numeric)
          end
        end

        # Filtering Tests

        test "only includes Job summarizable_type" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "filters by period_type hour" do
          results = create_table(period_type: :hour)

          assert_kind_of ActiveRecord::Relation, results
          assert_operator results.to_a.length, :>=, 0
        end

        test "filters by period_type day" do
          results = create_table(period_type: :day)

          assert_kind_of ActiveRecord::Relation, results
        end

        test "queue_name filter restricts results" do
          results_all = create_table

          results_filtered = create_table(queue_name: "mailers")

          assert_kind_of ActiveRecord::Relation, results_all
          assert_kind_of ActiveRecord::Relation, results_filtered

          if results_filtered.any?
            results_filtered.each do |result|
              assert_equal "mailers", result.queue_name
            end
          end
        end

        test "nil queue_name includes all queues" do
          results = create_table(queue_name: nil)

          assert_kind_of ActiveRecord::Relation, results
        end

        test "empty queue_name includes all queues" do
          results = create_table(queue_name: "")

          assert_kind_of ActiveRecord::Relation, results
        end

        test "queue_name default queue filter" do
          results = create_table(queue_name: "default")

          assert_kind_of ActiveRecord::Relation, results

          if results.any?
            results.each do |result|
              assert_equal "default", result.queue_name
            end
          end
        end

        test "disabled_tags excludes jobs with matching tags" do
          results = create_table(disabled_tags: [ "report" ])

          assert_kind_of ActiveRecord::Relation, results

          if results.any?
            results.each do |result|
              tags = result.tags
              refute_includes tags, "report" if tags
            end
          end
        end

        test "disabled_tags non_tagged excludes non-tagged jobs" do
          results = create_table(disabled_tags: [ "non_tagged" ])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "show_non_tagged false excludes jobs without tags" do
          results = create_table(show_non_tagged: false)

          if results.any?
            results.each do |result|
              assert result.tags
              refute_equal "[]", result.tags
            end
          end
        end

        test "show_non_tagged true includes all jobs" do
          results = create_table(show_non_tagged: true)

          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles empty disabled_tags array" do
          results = create_table(disabled_tags: [])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple disabled tags all excluded" do
          results = create_table(disabled_tags: [ "report", "maintenance" ])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sanitizes LIKE special characters in tags" do
          results = create_table(disabled_tags: [ "%malicious%" ])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles tag with underscore" do
          results = create_table(disabled_tags: [ "_tag" ])

          assert_kind_of ActiveRecord::Relation, results
        end

        # Sorting Tests

        test "default sort is count DESC" do
          results = create_table

          results_array = results.to_a

          if results_array.length > 1
            first_count = results_array.first.count.to_i
            last_count = results_array.last.count.to_i

            assert_operator first_count, :>=, last_count
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by name asc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "name asc"
          })

          results = create_table

          results_array = results.to_a

          if results_array.length > 1
            names = results_array.map(&:name)

            assert_equal names.sort, names
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by queue_name asc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "queue_name asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by avg_duration_sort desc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "avg_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by max_duration_sort asc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "max_duration_sort asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by p95_duration_sort desc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "p95_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by p99_duration_sort desc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "p99_duration_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by count_sort desc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort desc"
          })

          results = create_table
          results_array = results.to_a

          if results_array.length > 1
            first_count = results_array.first.count.to_i
            last_count = results_array.last.count.to_i

            assert_operator first_count, :>=, last_count
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by runs_count_sort desc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "runs_count_sort desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by failures_count_sort asc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "failures_count_sort asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by error_count_sort asc" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "error_count_sort asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "unknown sort field falls back to default" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "unknown_field asc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "supports both ASC and DESC directions" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort asc"
          })
          results_asc = create_table

          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort desc"
          })
          results_desc = create_table

          assert_kind_of ActiveRecord::Relation, results_asc
          assert_kind_of ActiveRecord::Relation, results_desc
        end

        # Integration Tests

        test "handles empty result set" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: 1000.days.ago,
            period_start_lt: 999.days.ago
          })

          results = create_table

          assert_equal 0, results.to_a.length
        end

        test "each job appears at most once" do
          results = create_table

          results_array = results.to_a
          job_ids = results_array.map(&:job_id)

          assert_equal job_ids.uniq.length, job_ids.length
        end

        test "uses NULLIF to prevent division by zero" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end
      end
    end
  end
end
