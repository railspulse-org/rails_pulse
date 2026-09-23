require "test_helper"

module RailsPulse
  module Queries
    module Charts
      class DatabaseLoadTest < ActiveSupport::TestCase
        fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_summaries

        def setup
          ENV["TEST_TYPE"] = "functional"
          super

          @start_time = 7.days.ago.beginning_of_day.to_i
          @end_time = Time.current.end_of_day.to_i
        end

        # Structure Tests

        test "to_chart_data returns hash or nil" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          # Can be hash or nil if no data
          assert(result.nil? || result.is_a?(Hash))
        end

        test "returns nil when no query summaries exist" do
          # Use a future time range with no data
          future_start = 1.year.from_now.to_i
          future_end = 2.years.from_now.to_i

          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(future_start, future_end),
            period_type: :day
          )

          result = chart.to_chart_data

          assert_nil result
        end

        # Period Type Tests

        test "accepts day period_type" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        test "accepts hour period_type" do
          start_time = 24.hours.ago.beginning_of_hour.to_i
          end_time = Time.current.end_of_hour.to_i

          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(start_time, end_time),
            period_type: :hour
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        # Tag Filter Tests

        test "accepts disabled_tags parameter" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day,
            disabled_tags: [ "slow" ]
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        test "accepts show_non_tagged parameter" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day,
            show_non_tagged: false
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        test "accepts nil disabled_tags" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day,
            disabled_tags: nil
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        test "accepts empty disabled_tags array" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day,
            disabled_tags: []
          )

          assert_nothing_raised do
            chart.to_chart_data
          end
        end

        # Data Format Tests
        # Fixtures provide both query and route summaries within the 7-day range,
        # so to_chart_data returns a Hash (not nil) in these tests.

        test "result has no labels key" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          assert_not_nil result
          refute result.key?(:labels)
        end

        test "each data point has value as [timestamp_ms, percentage] array" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          assert_not_nil result
          result[:series].first[:data].each do |point|
            assert_kind_of Hash, point
            assert_kind_of Array, point[:value]
            assert_equal 2, point[:value].length
            assert_operator point[:value][0], :>, 1_000_000_000_000  # ms timestamp
            assert_kind_of Numeric, point[:value][1]
          end
        end

        test "each data point has itemStyle with color" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          assert_not_nil result
          result[:series].first[:data].each do |point|
            assert_kind_of Hash, point[:itemStyle]
            assert_match(/\Argb\(/, point[:itemStyle][:color])
          end
        end

        test "series is named DB Load with bar type" do
          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(@start_time, @end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          assert_not_nil result
          assert_equal "DB Load", result[:series].first[:name]
          assert_equal "bar", result[:series].first[:type]
        end

        # Color Threshold Tests

        test "assigns green color when DB load is below 25 percent" do
          period = 2.years.from_now.beginning_of_day
          # query_time=10, request_time=100 → 10% → green (<25%)
          chart, start_time = chart_with_db_load(period: period, query_duration: 10.0, route_duration: 100.0)

          result = chart.to_chart_data

          assert_not_nil result
          point = result[:series].first[:data].find { |p| p[:value][0] == start_time * 1000 }

          assert_not_nil point, "expected a data point at the created period"
          assert_equal "rgb(34, 197, 94)", point[:itemStyle][:color]
        end

        test "assigns yellow color when DB load is between 25 and 40 percent" do
          period = 2.years.from_now.beginning_of_day
          # query_time=30, request_time=100 → 30% → yellow (25-40%)
          chart, start_time = chart_with_db_load(period: period, query_duration: 30.0, route_duration: 100.0)

          result = chart.to_chart_data

          assert_not_nil result
          point = result[:series].first[:data].find { |p| p[:value][0] == start_time * 1000 }

          assert_not_nil point, "expected a data point at the created period"
          assert_equal "rgb(234, 179, 8)", point[:itemStyle][:color]
        end

        test "assigns red color when DB load exceeds 40 percent" do
          period = 2.years.from_now.beginning_of_day
          # query_time=50, request_time=100 → 50% → red (>40%)
          chart, start_time = chart_with_db_load(period: period, query_duration: 50.0, route_duration: 100.0)

          result = chart.to_chart_data

          assert_not_nil result
          point = result[:series].first[:data].find { |p| p[:value][0] == start_time * 1000 }

          assert_not_nil point, "expected a data point at the created period"
          assert_equal "rgb(239, 68, 68)", point[:itemStyle][:color]
        end

        # Edge Cases

        test "handles single day range" do
          start_time = Time.current.beginning_of_day.to_i
          end_time = Time.current.end_of_day.to_i

          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(start_time, end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          # Can be nil or hash depending on data availability
          assert(result.nil? || result.is_a?(Hash))
        end

        test "handles large time range" do
          start_time = 30.days.ago.beginning_of_day.to_i
          end_time = Time.current.end_of_day.to_i

          chart = DatabaseLoad.new(
            window: RailsPulse::TimeWindow.new(start_time, end_time),
            period_type: :day
          )

          result = chart.to_chart_data

          assert(result.nil? || result.is_a?(Hash))
        end

        private

        # Creates a DatabaseLoad chart backed by a single period of created summaries.
        # Uses a narrow 12-hour window so only one step is generated, keeping assertions
        # targeted. Returns [chart, start_time_seconds].
        def chart_with_db_load(period:, query_duration:, route_duration:)
          start_time = period.to_i
          end_time   = (period + 12.hours).to_i

          route = rails_pulse_routes(:api_users)
          query = rails_pulse_queries(:complex_query)

          RailsPulse::Summary.create!(
            summarizable: route,
            period_start: period,
            period_end:   period + 1.day,
            period_type:  "day",
            count:        10,
            total_duration: route_duration
          )

          RailsPulse::Summary.create!(
            summarizable: query,
            period_start: period,
            period_end:   period + 1.day,
            period_type:  "day",
            count:        10,
            total_duration: query_duration
          )

          chart = DatabaseLoad.new(window: RailsPulse::TimeWindow.new(start_time, end_time), period_type: :day)
          [ chart, start_time ]
        end
      end
    end
  end
end
