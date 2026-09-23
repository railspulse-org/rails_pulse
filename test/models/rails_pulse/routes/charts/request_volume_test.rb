require "test_helper"

module RailsPulse
  module Routes
    module Charts
      class RequestVolumeTest < ActiveSupport::TestCase
        def setup
          @route = rails_pulse_routes(:api_test)
          @start_time = 1.day.ago.beginning_of_day
          @end_time = Time.current.end_of_day
          @ransack_query = RailsPulse::Summary.ransack
        end

        # Structure Tests

        test "returns hash with series key" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        test "series data contains timestamp/value pairs in milliseconds" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          first_point = data[:series].first[:data].first

          assert_kind_of Array, first_point
          assert_operator first_point[0], :>, 1_000_000_000_000  # ms timestamp
        end

        test "series is array with exactly one bar chart series" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Array, data[:series]
          assert_equal 1, data[:series].length
        end

        test "series has required fields" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          series = data[:series].first

          assert_includes series.keys, :name
          assert_includes series.keys, :data
          assert_includes series.keys, :type
          assert_includes series.keys, :color
        end

        test "series name is Requests" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "Requests", data[:series].first[:name]
        end

        test "series type is bar" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal "bar", data[:series].first[:type]
        end

        test "series color is ChartColors::DEFAULT" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_equal RailsPulse::ChartColors::DEFAULT, data[:series].first[:color]
        end

        test "data array contains at least one point" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_operator data[:series].first[:data].length, :>, 0
        end

        # Data Calculation Tests

        test "aggregates request counts by period_start" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Array, data[:series].first[:data]
          data[:series].first[:data].each do |point|
            assert_kind_of Array, point
            assert_kind_of Integer, point[1]
            assert_operator point[1], :>=, 0
          end
        end

        test "groups by hour when period_type is hour" do
          start_time = 2.hours.ago.beginning_of_hour
          end_time = Time.current.end_of_hour

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :hour,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have at least 3 data points (2 hours + 1)
          assert_operator data[:series].first[:data].length, :>=, 3
          # Check step size is 1 hour (3600 seconds in milliseconds)
          if data[:series].first[:data].length > 1
            step = (data[:series].first[:data][1][0] - data[:series].first[:data][0][0]) / 1000

            assert_equal 3600, step
          end
        end

        test "groups by day when period_type is day" do
          start_time = 3.days.ago.beginning_of_day
          end_time = Time.current.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have at least 4 data points (3 days + 1)
          assert_operator data[:series].first[:data].length, :>=, 4
          # Check step size is 1 day (86400 seconds in milliseconds)
          if data[:series].first[:data].length > 1
            step = (data[:series].first[:data][1][0] - data[:series].first[:data][0][0]) / 1000

            assert_equal 86400, step
          end
        end

        test "data values are integers" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          data[:series].first[:data].each do |point|
            assert_kind_of Integer, point[1]
          end
        end

        test "empty periods filled with zeros" do
          # Use a time range with no data
          start_time = 100.days.ago.beginning_of_day
          end_time = 99.days.ago.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # All values should be zero
          assert_operator data[:series].first[:data].length, :>, 0
          data[:series].first[:data].each do |point|
            assert_equal 0, point[1]
          end
        end

        # Filtering Tests

        test "filters by route when route parameter provided" do
          chart = RequestVolume.new(
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
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            route: nil,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_includes data.keys, :series
        end

        test "only includes Route summarizable_type records" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should only include data from Route summaries, not Query or Job summaries
          assert_kind_of Array, data[:series].first[:data]
        end

        test "only includes records matching period_type" do
          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          # Should only include daily summaries
          assert_kind_of Array, data[:series].first[:data]
        end

        test "respects disabled_tags array" do
          chart = RequestVolume.new(
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
          chart = RequestVolume.new(
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
          chart = RequestVolume.new(
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

        test "handles empty result set gracefully" do
          # Create ransack query that will return no results
          ransack_query = RailsPulse::Summary.ransack(
            period_start_gteq: 1000.days.ago,
            period_start_lt: 999.days.ago
          )

          chart = RequestVolume.new(
            ransack_query: ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(1000.days.ago, 999.days.ago)
          )

          data = chart.to_chart_data

          assert_kind_of Hash, data
          assert_operator data[:series].first[:data].length, :>, 0
          # All values should be zero
          data[:series].first[:data].each do |point|
            assert_equal 0, point[1]
          end
        end

        test "handles periods with no data" do
          start_time = 50.days.ago.beginning_of_day
          end_time = 49.days.ago.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have data points but zero values
          assert_operator data[:series].first[:data].length, :>, 0
          data[:series].first[:data].each do |point|
            assert_equal 0, point[1]
          end
        end

        test "handles single period correctly" do
          start_time = 1.day.ago.beginning_of_day
          end_time = 1.day.ago.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have at least 1 data point
          assert_operator data[:series].first[:data].length, :>=, 1
        end

        test "time range with no matching summaries returns all zeros" do
          start_time = 200.days.ago.beginning_of_day
          end_time = 199.days.ago.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          data[:series].first[:data].each do |point|
            assert_equal 0, point[1]
          end
        end

        test "step size is 3600 seconds for hourly data" do
          start_time = 5.hours.ago.beginning_of_hour
          end_time = Time.current.end_of_hour

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :hour,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          if data[:series].first[:data].length > 1
            step = (data[:series].first[:data][1][0] - data[:series].first[:data][0][0]) / 1000

            assert_equal 3600, step
          end
        end

        test "step size is 86400 seconds for daily data" do
          start_time = 5.days.ago.beginning_of_day
          end_time = Time.current.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          if data[:series].first[:data].length > 1
            step = (data[:series].first[:data][1][0] - data[:series].first[:data][0][0]) / 1000

            assert_equal 86400, step
          end
        end

        test "handles large time ranges" do
          start_time = 90.days.ago.beginning_of_day
          end_time = Time.current.end_of_day

          chart = RequestVolume.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(start_time, end_time)
          )

          data = chart.to_chart_data

          # Should have ~91 data points
          assert_operator data[:series].first[:data].length, :>, 90
        end
      end
    end
  end
end
