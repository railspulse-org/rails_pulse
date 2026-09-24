require "test_helper"

module RailsPulse
  module Charts
    class PercentileChartBaseTest < ActiveSupport::TestCase
      fixtures :rails_pulse_routes, :rails_pulse_summaries

      # Test-only concrete implementation
      class TestPercentileChart < PercentileChartBase
        def summarizable_type = "RailsPulse::Route"
        def slo_config_key = :service_level_objectives
      end

      def setup
        ENV["TEST_TYPE"] = "functional"
        super

        @now = Time.current
        travel_to @now

        RailsPulse::Summary.delete_all
        @route = rails_pulse_routes(:api_users)
        @start_time = 7.days.ago.beginning_of_day
        @end_time = Time.current.end_of_day
        @ransack_query = RailsPulse::Summary.ransack
      end

      def teardown
        travel_back
        super
      end

      # ============================================================================
      # Structure Tests
      # ============================================================================

      test "initializes with required ransack_query parameter" do
        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_kind_of TestPercentileChart, chart
      end

      test "to_chart_data returns hash with series key" do
        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        assert_kind_of Hash, result
        assert_includes result.keys, :series
      end

      test "series data contains timestamp/value pairs in milliseconds" do
        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        first_point = result[:series].find { |s| s[:name] == "P50" }[:data].first

        assert_kind_of Array, first_point
        assert_operator first_point[0], :>, 1_000_000_000_000  # ms timestamp
      end

      test "series contains P50, P95, and P99 by default" do
        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        series_names = result[:series].map { |s| s[:name] }

        assert_includes series_names, "P50"
        assert_includes series_names, "P95"
        assert_includes series_names, "P99"
      end

      # ============================================================================
      # Weighted Percentile Calculation Tests
      # ============================================================================

      test "calculates weighted average P50 from multiple summaries" do
        # Route 1: 100 requests at P50=200ms → weight: 20000
        # Route 2: 100 requests at P50=400ms → weight: 40000
        # Weighted avg: 60000 / 200 = 300ms
        route2 = rails_pulse_routes(:api_posts)

        create_summary(@route, 1.day.ago, p50: 200, p95: 500, p99: 700, count: 100)
        create_summary(route2, 1.day.ago, p50: 400, p95: 600, p99: 800, count: 100)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Find non-nil values (should be the weighted average)
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 300, non_nil_values.first[1]
      end

      test "calculates weighted average P95 with different counts" do
        # Route 1: 200 requests at P95=300ms → weight: 60000
        # Route 2: 100 requests at P95=600ms → weight: 60000
        # Weighted avg: 120000 / 300 = 400ms
        route2 = rails_pulse_routes(:api_posts)

        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 200)
        create_summary(route2, 1.day.ago, p50: 100, p95: 600, p99: 800, count: 100)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p95_series = result[:series].find { |s| s[:name] == "P95" }

        # Find non-nil values (should be the weighted average)
        non_nil_values = p95_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 400, non_nil_values.first[1]
      end

      test "rounds percentile values to 2 decimal places" do
        create_summary(@route, 1.day.ago, p50: 100.7, p95: 300.3, p99: 500.9, count: 3)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        result[:series].each do |series|
          next if series[:name].include?("SLO")
          non_nil_values = series[:data].select { |v| !v[1].nil? }.map { |v| v[1] }

          non_nil_values.each do |value|
            assert_kind_of Numeric, value
            assert_equal value.round(2), value
          end
        end
      end

      # ============================================================================
      # Time Range and Padding Tests
      # ============================================================================

      test "pads missing days with nil values for daily period" do
        # Only create data for 1 day, but request 7 days
        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Should have 8 data points (7 days + today)
        assert_operator result[:series].first[:data].length, :>=, 7
        # Most should be nil (no data)
        nil_count = p50_series[:data].count { |v| v[1].nil? }

        assert_operator nil_count, :>, 5
      end

      test "generates correct step size for day period type" do
        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_data = result[:series].find { |s| s[:name] == "P50" }[:data]

        # Check that timestamps are spaced 86400000 milliseconds apart (1 day)
        if p50_data.length > 1
          diff = p50_data[1][0] - p50_data[0][0]

          assert_equal 86400000, diff
        end
      end

      test "generates correct step size for hour period type" do
        start_time = 24.hours.ago.beginning_of_hour
        end_time = Time.current.beginning_of_hour

        create_summary(@route, 1.hour.ago, p50: 100, p95: 300, p99: 500, count: 50, period_type: "hour")

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "hour",
          window: RailsPulse::TimeWindow.new(start_time, end_time)
        )
        result = chart.to_chart_data
        p50_data = result[:series].find { |s| s[:name] == "P50" }[:data]

        # Check that timestamps are spaced 3600000 milliseconds apart (1 hour)
        if p50_data.length > 1
          diff = p50_data[1][0] - p50_data[0][0]

          assert_equal 3600000, diff
        end
      end

      # ============================================================================
      # Subject Filtering Tests
      # ============================================================================

      test "filters to specific subject when provided" do
        route2 = rails_pulse_routes(:api_posts)

        # Create data for both routes
        create_summary(@route, 1.day.ago, p50: 200, p95: 400, p99: 600, count: 100)
        create_summary(route2, 1.day.ago, p50: 999, p95: 999, p99: 999, count: 100)

        # Chart filtered to just @route
        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          subject: @route,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Should only see @route's data (200), not route2's data (999)
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 200, non_nil_values.first[1]
      end

      test "aggregates all subjects when subject is nil" do
        route2 = rails_pulse_routes(:api_posts)

        create_summary(@route, 1.day.ago, p50: 200, p95: 400, p99: 600, count: 100)
        create_summary(route2, 1.day.ago, p50: 400, p95: 600, p99: 800, count: 100)

        # No subject filter - should aggregate both
        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          subject: nil,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Weighted average: (200*100 + 400*100) / 200 = 300
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 300, non_nil_values.first[1]
      end

      # ============================================================================
      # Tag Filtering Tests
      # ============================================================================

      test "filters summaries by disabled tags" do
        # api_users has no tags, api_cleanup has "maintenance" tag
        cleanup_route = rails_pulse_routes(:api_cleanup)

        create_summary(@route, 1.day.ago, p50: 200, p95: 400, p99: 600, count: 100)
        create_summary(cleanup_route, 1.day.ago, p50: 999, p95: 999, p99: 999, count: 100)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: [ "maintenance" ],
          show_non_tagged: true
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Should only see api_users data (200), not api_cleanup (999)
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 200, non_nil_values.first[1]
      end

      test "excludes non-tagged routes when show_non_tagged is false" do
        # api_users has tags, api_other has no tags
        create_summary(@route, 1.day.ago, p50: 200, p95: 400, p99: 600, count: 100)
        create_summary(rails_pulse_routes(:api_other), 1.day.ago, p50: 999, p95: 999, p99: 999, count: 100)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: [],
          show_non_tagged: false
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Should only see tagged route data (200), not untagged (999)
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 200, non_nil_values.first[1]
      end

      # ============================================================================
      # SLO Series Tests
      # ============================================================================

      test "includes SLO series when configured" do
        original_config = RailsPulse.configuration.service_level_objectives
        RailsPulse.configuration.service_level_objectives = [
          { percentile: 95, threshold: 500 }
        ]

        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        slo_series = result[:series].find { |s| s[:name].include?("SLO") }

        assert_not_nil slo_series
      ensure
        RailsPulse.configuration.service_level_objectives = original_config
      end

      test "SLO series is flat line at threshold value" do
        original_config = RailsPulse.configuration.service_level_objectives
        RailsPulse.configuration.service_level_objectives = [
          { percentile: 95, threshold: 500 }
        ]

        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        slo_series = result[:series].find { |s| s[:name].include?("SLO") }

        assert slo_series[:data].all? { |v| v[1] == 500 }
      ensure
        RailsPulse.configuration.service_level_objectives = original_config
      end

      test "SLO series uses dashed line style" do
        original_config = RailsPulse.configuration.service_level_objectives
        RailsPulse.configuration.service_level_objectives = [
          { percentile: 95, threshold: 500 }
        ]

        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        slo_series = result[:series].find { |s| s[:name].include?("SLO") }

        assert_equal "dashed", slo_series[:lineStyle][:type]
        assert_equal "none", slo_series[:symbol]
      ensure
        RailsPulse.configuration.service_level_objectives = original_config
      end

      test "creates multiple SLO series when multiple SLOs configured" do
        original_config = RailsPulse.configuration.service_level_objectives
        RailsPulse.configuration.service_level_objectives = [
          { percentile: 95, threshold: 500 },
          { percentile: 99, threshold: 1000 }
        ]

        create_summary(@route, 1.day.ago, p50: 100, p95: 300, p99: 500, count: 50)

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        slo_series = result[:series].select { |s| s[:name].include?("SLO") }

        assert_equal 2, slo_series.length
      ensure
        RailsPulse.configuration.service_level_objectives = original_config
      end

      # ============================================================================
      # Edge Cases
      # ============================================================================

      test "handles empty data gracefully" do
        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data

        assert_kind_of Hash, result
        assert_kind_of Array, result[:series]

        p50_series = result[:series].find { |s| s[:name] == "P50" }

        assert p50_series[:data].all? { |v| v[1].nil? }
      end

      test "handles nil percentile values by treating as zero" do
        RailsPulse::Summary.create!(
          summarizable: @route,
          period_start: 1.day.ago.beginning_of_day,
          period_end: 1.day.ago.end_of_day,
          period_type: "day",
          count: 100,
          avg_duration: 150.0,
          p50_duration: nil,
          p95_duration: nil,
          p99_duration: nil
        )

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # Should have exactly one non-nil value which is 0
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_equal 1, non_nil_values.length
        assert_equal 0, non_nil_values.first[1]
      end

      test "handles zero count summaries" do
        RailsPulse::Summary.create!(
          summarizable: @route,
          period_start: 1.day.ago.beginning_of_day,
          period_end: 1.day.ago.end_of_day,
          period_type: "day",
          count: 0,
          avg_duration: 0.0,
          p50_duration: 0.0,
          p95_duration: 0.0,
          p99_duration: 0.0
        )

        chart = TestPercentileChart.new(
          ransack_query: @ransack_query,
          period_type: "day",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )
        result = chart.to_chart_data
        p50_series = result[:series].find { |s| s[:name] == "P50" }

        # With zero count, all values should be nil (no data to aggregate)
        non_nil_values = p50_series[:data].select { |v| !v[1].nil? }

        assert_empty non_nil_values
      end

      private

      def create_summary(route, date, p50:, p95:, p99:, count:, period_type: "day")
        RailsPulse::Summary.create!(
          summarizable: route,
          period_start: date.beginning_of_day,
          period_end: date.end_of_day,
          period_type: period_type,
          count: count,
          avg_duration: p50.to_f,
          p50_duration: p50.to_f,
          p95_duration: p95.to_f,
          p99_duration: p99.to_f
        )
      end
    end
  end
end
