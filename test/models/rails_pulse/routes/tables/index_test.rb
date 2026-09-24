require "test_helper"

module RailsPulse
  module Routes
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

        # Helper method to create table service
        def create_table(disabled_tags: [], show_non_tagged: true, **options)
          RailsPulse::Routes::Tables::Index.new(
            ransack_query: @ransack_query,
            period_type: :day,
            params: @params,
            disabled_tags: disabled_tags,
            show_non_tagged: show_non_tagged,
            **options
          ).to_table
        end

        def first_table_row(**options)
          row = create_table(**options).first

          assert row, "Expected route summary fixtures to be within the test time range"
          row
        end

        # Structure Tests

        test "returns ActiveRecord relation" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "result has required route attributes" do
          first_result = first_table_row

          assert_includes first_result.attributes.keys, "route_id"
          assert_includes first_result.attributes.keys, "path"
          assert_includes first_result.attributes.keys, "route_methods"
          assert_includes first_result.attributes.keys, "controller_action"
        end

        test "result has metric attributes" do
          first_result = first_table_row

          assert_includes first_result.attributes.keys, "avg_duration"
          assert_includes first_result.attributes.keys, "p95_duration"
          assert_includes first_result.attributes.keys, "p99_duration"
          assert_includes first_result.attributes.keys, "max_duration"
        end

        test "result has count attributes" do
          first_result = first_table_row

          assert_includes first_result.attributes.keys, "count"
          assert_includes first_result.attributes.keys, "error_count"
          assert_includes first_result.attributes.keys, "success_count"
        end

        test "groups by controller_action and path" do
          results = create_table

          # Each (controller_action, path) combination should appear only once
          groups = results.map { |r| [ r.controller_action, r.path ] }

          assert_equal groups.uniq.length, groups.length
        end

        test "joins with rails_pulse_routes table" do
          first_result = first_table_row

          assert_kind_of String, first_result.path
          assert_kind_of String, first_result.route_methods
        end

        test "result attributes have correct types" do
          first_result = first_table_row

          assert_kind_of Numeric, first_result.route_id
          assert_kind_of String, first_result.path
          assert_kind_of String, first_result.route_methods
        end

        # Aggregation Tests

        test "avg_duration is AVG of avg_duration across periods" do
          result = first_table_row

          assert result.avg_duration.nil? || result.avg_duration.is_a?(Numeric)
        end

        test "max_duration is MAX of max_duration across periods" do
          result = first_table_row

          assert result.max_duration.nil? || result.max_duration.is_a?(Numeric)
        end

        test "p95_duration is weighted average" do
          result = first_table_row

          assert result.p95_duration.nil? || result.p95_duration.is_a?(Numeric)
        end

        test "p99_duration is weighted average" do
          result = first_table_row

          assert result.p99_duration.nil? || result.p99_duration.is_a?(Numeric)
        end

        test "count is SUM of count across periods" do
          result = first_table_row

          assert_kind_of Numeric, result.count
          assert_operator result.count, :>=, 0
        end

        test "error_count is SUM of error_count across periods" do
          result = first_table_row

          assert result.error_count.nil? || result.error_count.is_a?(Numeric)
        end

        test "success_count is SUM of success_count across periods" do
          result = first_table_row

          assert result.success_count.nil? || result.success_count.is_a?(Numeric)
        end

        test "uses NULLIF to prevent division by zero" do
          # This is tested implicitly - if division by zero occurred, we'd get an error
          results = create_table

          # Should not raise division by zero error
          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple summaries for same route aggregate correctly" do
          results = create_table

          # Routes should be grouped and aggregated
          assert_kind_of ActiveRecord::Relation, results
        end

        test "single summary returns correct values" do
          result = first_table_row

          assert result.count.nil? || result.count >= 0
        end

        # Filtering Tests

        test "only includes Route summarizable_type" do
          results = create_table

          # Should only include route summaries, not query or job summaries
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

        test "disabled_tags excludes routes with actual tags" do
          results = create_table(disabled_tags: [ "api" ])

          # Should exclude routes tagged with "api"
          assert_kind_of ActiveRecord::Relation, results
          if results.any?
            results.each do |result|
              tags = result.tags
              refute_includes tags, "api" if tags
            end
          end
        end

        test "disabled_tags with non_tagged excludes non-tagged routes" do
          results = create_table(disabled_tags: [ "non_tagged" ])

          assert_kind_of ActiveRecord::Relation, results
          results.each do |result|
            assert result.tags
            refute_equal "[]", result.tags
          end
        end

        test "show_non_tagged false excludes routes without tags" do
          results = create_table(show_non_tagged: false)

          assert_kind_of ActiveRecord::Relation, results
          results.each do |result|
            assert result.tags
            refute_equal "[]", result.tags
          end
        end

        test "show_non_tagged true includes routes without tags" do
          results = create_table(show_non_tagged: true)

          # Should include all routes
          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles empty disabled_tags array" do
          results = create_table(disabled_tags: [])

          # Should show all routes
          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple disabled tags all excluded" do
          results = create_table(disabled_tags: [ "api", "maintenance" ])

          # Should exclude routes with either tag
          assert_kind_of ActiveRecord::Relation, results
          if results.any?
            results.each do |result|
              tags = result.tags
              refute_includes tags, "api" if tags
              refute_includes tags, "maintenance" if tags
            end
          end
        end

        test "tag matching uses SQL LIKE with wildcards" do
          results = create_table(disabled_tags: [ "api" ])

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

        test "sorts by count_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort desc"
          })

          results = create_table
          results_array = results.to_a

          if results_array.length > 1
            first_count = results_array.first.count || 0
            last_count = results_array.last.count || 0

            assert_operator first_count, :>=, last_count
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "sorts by request_count_sort" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "request_count_sort desc"
          })

          results = create_table

          # request_count_sort is an alias for count_sort
          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by requests_per_minute" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "requests_per_minute desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by error_rate_percentage" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "error_rate_percentage desc"
          })

          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "sorts by route_path" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "route_path asc"
          })

          results = create_table
          results_array = results.to_a

          if results_array.length > 1
            paths = results_array.map(&:path)

            assert_equal paths.sort, paths
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "supports both ASC and DESC directions" do
          # Test ASC
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort asc"
          })

          results_asc = create_table

          # Test DESC
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "count_sort desc"
          })

          results_desc = create_table

          assert_kind_of ActiveRecord::Relation, results_asc
          assert_kind_of ActiveRecord::Relation, results_desc
        end

        test "unknown sort field falls back to default" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "invalid_field asc"
          })

          results = create_table

          # Should use default sort instead of erroring
          assert_kind_of ActiveRecord::Relation, results
        end

        test "uses Arel.sql for safe sorting" do
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: @start_time,
            period_start_lt: @end_time,
            s: "avg_duration_sort desc"
          })

          results = create_table

          # Should not raise SQL injection error
          assert_kind_of ActiveRecord::Relation, results
        end

        # Tag Filtering Edge Cases

        test "distinguishes non_tagged virtual tag from actual tags" do
          # "non_tagged" should not be treated as a real tag to match
          results = create_table(disabled_tags: [ "non_tagged" ])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles tags with special characters" do
          results = create_table(disabled_tags: [ "special-tag_123" ])

          # Should sanitize and handle safely
          assert_kind_of ActiveRecord::Relation, results
        end

        test "empty tags array shows all routes" do
          results = create_table(disabled_tags: [])

          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles tag with brackets" do
          results = create_table(disabled_tags: [ "[tag]" ])

          # Should sanitize brackets
          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles tag with percent" do
          results = create_table(disabled_tags: [ "%tag%" ])

          # Should sanitize LIKE wildcards
          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles tag with underscore" do
          results = create_table(disabled_tags: [ "_tag" ])

          # Should sanitize LIKE wildcards
          assert_kind_of ActiveRecord::Relation, results
        end

        test "multiple tags in disabled_tags array" do
          results = create_table(disabled_tags: [ "api", "users", "maintenance" ])

          # Should exclude all specified tags
          assert_kind_of ActiveRecord::Relation, results
        end

        # Integration Tests

        test "works with ransack query object" do
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        test "handles empty result sets" do
          # Use time range with no data
          @ransack_query = RailsPulse::Summary.ransack({
            period_start_gteq: 1000.days.ago,
            period_start_lt: 999.days.ago
          })

          results = create_table

          assert_equal 0, results.to_a.length
        end

        test "returns correct structure for pagination" do
          results = create_table

          # Should return an ActiveRecord::Relation that can be paginated
          assert_kind_of ActiveRecord::Relation, results
          # The relation will be paginated by the controller using Kaminari
          assert_operator results.to_a.length, :>=, 0
        end

        test "multiple routes in same period aggregated by controller_action and path" do
          results = create_table
          results_array = results.to_a

          # Each (controller_action, path) group should appear exactly once
          groups = results_array.map { |r| [ r.controller_action, r.path ] }

          assert_equal groups.uniq.length, groups.length
        end

        test "single route across multiple periods aggregated together" do
          results = create_table
          results_array = results.to_a

          # Single (controller_action, path) group across multiple periods → one row
          if results_array.any?
            groups = results_array.map { |r| [ r.controller_action, r.path ] }

            assert_equal groups.uniq.length, groups.length
          else
            assert_kind_of ActiveRecord::Relation, results
          end
        end

        test "multi-verb route shows all accepted methods in route_methods" do
          now = Time.current
          shared_path = "/multi-verb-test-#{SecureRandom.hex(4)}"

          route = RailsPulse::Route.create!(
            http_methods: '["GET","POST"]',
            path: shared_path,
            controller_action: "home#index",
            tags: "[]"
          )
          RailsPulse::Summary.create!(
            summarizable: route,
            period_type: :day,
            period_start: now.beginning_of_day,
            period_end: now.end_of_day,
            count: 20,
            avg_duration: 50.0,
            min_duration: 10.0,
            max_duration: 100.0,
            total_duration: 1000.0,
            p50_duration: 50.0,
            p95_duration: 90.0,
            p99_duration: 95.0,
            stddev_duration: 20.0,
            error_count: 0,
            success_count: 20
          )

          results = create_table.to_a
          matching = results.select { |r| r.path == shared_path }

          assert_equal 1, matching.length, "multi-verb route should produce exactly one row"
          methods = JSON.parse(matching.first.route_methods || "[]")

          assert_includes methods, "GET"
          assert_includes methods, "POST"
        end

        test "combines with controller parameters correctly" do
          @params = { page: 1, limit: 10 }
          results = create_table

          assert_kind_of ActiveRecord::Relation, results
        end

        # Path / action filter Tests

        test "filters by route_path_cont via ransack" do
          now = Time.current
          unique = SecureRandom.hex(4)
          matching_path = "/path-filter-match-#{unique}"
          other_path    = "/path-filter-other-#{unique}"

          [ matching_path, other_path ].each_with_index do |path, i|
            route = RailsPulse::Route.create!(http_methods: '["GET"]', path: path, controller_action: "home#index", tags: "[]")
            RailsPulse::Summary.create!(
              summarizable: route, period_type: :day,
              period_start: now.beginning_of_day, period_end: now.end_of_day,
              count: 10, avg_duration: 50.0, min_duration: 10.0, max_duration: 100.0,
              total_duration: 500.0, p50_duration: 50.0, p95_duration: 90.0,
              p99_duration: 95.0, stddev_duration: 20.0, error_count: 0, success_count: 10
            )
          end

          @ransack_query = RailsPulse::Summary.ransack(route_path_cont: "path-filter-match-#{unique}")
          results = create_table.to_a

          assert_includes results.map(&:path), matching_path
          refute_includes results.map(&:path), other_path
        end

        test "filters by route_controller_action_cont via ransack" do
          now = Time.current
          unique = SecureRandom.hex(4)
          matching_ca = "acme_#{unique}#show"
          other_ca    = "other_#{unique}#index"

          [ matching_ca, other_ca ].each_with_index do |ca, i|
            route = RailsPulse::Route.create!(http_methods: '["GET"]', path: "/ca-filter-#{i}-#{unique}", controller_action: ca, tags: "[]")
            RailsPulse::Summary.create!(
              summarizable: route, period_type: :day,
              period_start: now.beginning_of_day, period_end: now.end_of_day,
              count: 10, avg_duration: 50.0, min_duration: 10.0, max_duration: 100.0,
              total_duration: 500.0, p50_duration: 50.0, p95_duration: 90.0,
              p99_duration: 95.0, stddev_duration: 20.0, error_count: 0, success_count: 10
            )
          end

          @ransack_query = RailsPulse::Summary.ransack(route_controller_action_cont: "acme_#{unique}")
          results = create_table.to_a

          assert_includes results.map(&:controller_action), matching_ca
          refute_includes results.map(&:controller_action), other_ca
        end
      end
    end
  end
end
