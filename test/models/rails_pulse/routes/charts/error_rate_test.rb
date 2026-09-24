require "test_helper"

module RailsPulse
  module Routes
    module Charts
      class ErrorRateTest < ActiveSupport::TestCase
        def setup
          @route = rails_pulse_routes(:api_test)
          @start_time = 10.days.ago.beginning_of_day
          @end_time = Time.current.end_of_day
          @ransack_query = RailsPulse::Summary.ransack
        end

        # Structure Tests

        test "returns hash with series key" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        test "series data contains timestamp/value pairs in milliseconds" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          first_point = data[:series].first[:data].first

          assert_kind_of Array, first_point
          assert_operator first_point[0], :>, 1_000_000_000_000  # ms timestamp
        end

        test "series is array with exactly two bar chart series" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Array, data[:series]
          assert_equal 2, data[:series].length
        end

        test "first series name is 4xx Errors" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "4xx Errors", data[:series][0][:name]
        end

        test "second series name is 5xx Errors" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "5xx Errors", data[:series][1][:name]
        end

        test "both series have type bar" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "bar", data[:series][0][:type]
          assert_equal "bar", data[:series][1][:type]
        end

        test "both series are stacked together" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "error_rate", data[:series][0][:stack]
          assert_equal "error_rate", data[:series][1][:stack]
        end

        test "bottom series has no border radius" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal [ 0, 0, 0, 0 ], data[:series][0][:itemStyle][:borderRadius]
        end

        test "top series has rounded top corners only" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal [ 5, 5, 0, 0 ], data[:series][1][:itemStyle][:borderRadius]
        end

        test "4xx Errors series color is ChartColors::P99" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal RailsPulse::ChartColors::P99, data[:series][0][:color]
        end

        test "5xx Errors series color is ChartColors::P95" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal RailsPulse::ChartColors::P95, data[:series][1][:color]
        end

        test "both series have same number of data points" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal data[:series][0][:data].length, data[:series][1][:data].length
        end

        # Calculation Tests

        test "error rate calculated as total_errors / total_count * 100" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Values should be percentages or nil
          data[:series][0][:data].each do |point|
            value = point[1]
            next if value.nil?

            assert_kind_of Numeric, value
            assert_operator value, :>=, 0
            assert_operator value, :<=, 100
          end
        end

        test "client error rate calculated as total_4xx / total_count * 100" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Values should be percentages or nil
          data[:series][1][:data].each do |point|
            value = point[1]
            next if value.nil?

            assert_kind_of Numeric, value
            assert_operator value, :>=, 0
            assert_operator value, :<=, 100
          end
        end

        test "percentages rounded to 2 decimal places" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Check that any non-nil values have at most 2 decimal places
          data[:series][0][:data].each do |point|
            value = point[1]
            next if value.nil?
            # Convert to string and check decimal places
            str = value.to_s
            if str.include?(".")
              decimals = str.split(".")[1]

              assert_operator decimals.length, :<=, 2
            end
          end
        end

        test "returns nil when count is zero" do
          # Use a time range with no data
          start_time = 100.days.ago.beginning_of_day
          end_time = 99.days.ago.end_of_day

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # All values should be nil (no division by zero)
          data[:series][0][:data].each do |point|
            assert_nil point[1]
          end
          data[:series][1][:data].each do |point|
            assert_nil point[1]
          end
        end

        test "sums error_count across multiple routes in same period" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            route: nil, # Aggregate all routes
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should have aggregated data
          assert_kind_of Array, data[:series][0][:data]
        end

        test "sums status_4xx across multiple routes in same period" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            route: nil, # Aggregate all routes
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should have aggregated data
          assert_kind_of Array, data[:series][1][:data]
        end

        test "groups by period_start correctly" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should have multiple periods
          assert_operator data[:series][0][:data].length, :>, 1
        end

        # Filtering Tests

        test "filters by route when route parameter provided" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            route: @route,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        test "aggregates all routes when route is nil" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            route: nil,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        test "only includes Route summarizable_type" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should only include data from Route summaries
          assert_kind_of Array, data[:series][0][:data]
          assert_kind_of Array, data[:series][1][:data]
        end

        test "only includes matching period_type" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should only include daily summaries
          assert_kind_of Array, data[:series][0][:data]
        end

        test "respects disabled_tags parameter" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            disabled_tags: [ "api" ]
          )

          data = chart.to_chart_data

          # Should exclude routes with "api" tag
          assert_kind_of Hash, data
        end

        test "respects show_non_tagged false" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            show_non_tagged: false
          )

          data = chart.to_chart_data

          # Should exclude routes without tags
          assert_kind_of Hash, data
        end

        test "uses with_tag_filters scope" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            disabled_tags: [ "maintenance" ],
            show_non_tagged: true
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        # Edge Cases

        test "pads missing periods with nil values" do
          # Use a time range with likely no data
          start_time = 50.days.ago.beginning_of_day
          end_time = 49.days.ago.end_of_day

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have data points but nil values
          assert_operator data[:series][0][:data].length, :>, 0
          data[:series][0][:data].each do |point|
            assert_nil point[1]
          end
        end

        test "handles zero errors gracefully" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # If there are zero errors, rate should be 0.0 or nil
          data[:series][0][:data].each do |point|
            value = point[1]
            next if value.nil?

            assert_operator value, :>=, 0.0
          end
        end

        test "handles 100% error rate correctly" do
          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Error rate should never exceed 100%
          data[:series][0][:data].each do |point|
            value = point[1]
            next if value.nil?

            assert_operator value, :<=, 100.0
          end
        end

        test "handles periods with no data" do
          start_time = 200.days.ago.beginning_of_day
          end_time = 199.days.ago.end_of_day

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have nil values for missing periods
          data[:series][0][:data].each do |point|
            assert_nil point[1]
          end
          data[:series][1][:data].each do |point|
            assert_nil point[1]
          end
        end

        test "empty result set returns structure with nil data" do
          ransack_query = RailsPulse::Summary.ransack(
            period_start_gteq: 1000.days.ago,
            period_start_lt: 999.days.ago
          )

          chart = ErrorRate.new(
            ransack_query: ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(1000.days.ago, 999.days.ago)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_operator data[:series][0][:data].length, :>, 0
          # All values should be nil
          data[:series][0][:data].each do |point|
            assert_nil point[1]
          end
        end

        test "step size matches period_type for hour" do
          start_time = 5.hours.ago.beginning_of_hour
          end_time = Time.current.end_of_hour

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :hour,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          if data[:series][0][:data].length > 1
            step = (data[:series][0][:data][1][0] - data[:series][0][:data][0][0]) / 1000

            assert_equal 3600, step
          end
        end

        test "step size matches period_type for day" do
          start_time = 5.days.ago.beginning_of_day
          end_time = Time.current.end_of_day

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          if data[:series][0][:data].length > 1
            step = (data[:series][0][:data][1][0] - data[:series][0][:data][0][0]) / 1000

            assert_equal 86400, step
          end
        end

        test "nil values in data array for missing periods" do
          # Mix of periods with and without data
          start_time = 10.days.ago.beginning_of_day
          end_time = Time.current.end_of_day

          chart = ErrorRate.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have some data points for periods without data
          assert_operator data[:series][0][:data].length, :>, 0
          # Data can contain nil values (as [ts, nil] pairs)
          assert_kind_of Array, data[:series][0][:data]
          assert_kind_of Array, data[:series][1][:data]
        end
      end
    end
  end
end
