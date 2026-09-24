require "test_helper"

module RailsPulse
  module Exceptions
    module Charts
      # The chart reads the all-groups rollup summary rather than counting
      # occurrence rows, so that history survives retention. What matters here is
      # that it reads the right rows and that quiet periods come back as zero
      # rather than as a gap — a chart that skips quiet days misrepresents the
      # trend it exists to show.
      class OccurrenceVolumeTest < ActiveSupport::TestCase
        ROLLUP = "RailsPulse::ExceptionGroup".freeze

        def setup
          ENV["TEST_TYPE"] = "functional"
          super
          RailsPulse::Summary.delete_all
          @now = Time.utc(2026, 6, 15, 12, 0, 0)
          travel_to @now
          @start_time = (@now - 3.days).beginning_of_day
          @end_time   = @now.end_of_day
        end

        def teardown
          travel_back
          super
        end

        # Structure Tests

        test "chart returns a single named bar series" do
          create_rollup(@start_time, count: 4)

          series = chart.to_chart_data[:series]

          assert_equal 1, series.size
          assert_equal "Occurrences", series.first[:name]
          assert_equal "bar", series.first[:type]
          assert_equal RailsPulse::ChartColors::DEFAULT, series.first[:color]
        end

        test "chart emits millisecond timestamps for the time axis" do
          create_rollup(@start_time, count: 4)

          timestamp, value = chart.to_chart_data[:series].first[:data].first

          assert_equal @start_time.to_i * 1000, timestamp
          assert_equal 4, value
        end

        # Calculation Tests

        test "chart returns one bucket per day across the range" do
          create_rollup(@start_time, count: 4)

          # Start of day three days back through the start of today: four buckets.
          assert_equal 4, data_points.size
        end

        test "chart reports the count recorded for each day" do
          create_rollup(@start_time, count: 4)
          create_rollup(@start_time + 2.days, count: 9)

          assert_equal [ 4, 0, 9, 0 ], data_points.map(&:last)
        end

        test "chart pads a day with no summary row as zero rather than a gap" do
          create_rollup(@start_time + 1.day, count: 7)

          values = data_points.map(&:last)

          assert_equal 4, values.size
          assert_equal [ 0, 7, 0, 0 ], values
        end

        test "chart buckets hourly when asked for an hour period" do
          start_time = (@now - 3.hours).beginning_of_hour
          create_rollup(start_time, count: 2, period_type: "hour")
          create_rollup(start_time + 2.hours, count: 5, period_type: "hour")

          points = chart(window: RailsPulse::TimeWindow.new(start_time, @now), period_type: "hour")
            .to_chart_data[:series].first[:data]

          assert_equal [ 2, 0, 5, 0 ], points.map(&:last)
          assert_equal 3600 * 1000, points[1].first - points[0].first
        end

        # Filtering Tests

        test "chart reads the rollup and ignores per-group summaries" do
          create_rollup(@start_time, count: 4)
          create_rollup(@start_time, count: 99, summarizable_id: 7)

          assert_equal [ 4, 0, 0, 0 ], data_points.map(&:last)
        end

        test "chart ignores summaries of a different period type" do
          create_rollup(@start_time, count: 4, period_type: "hour")

          assert_nil chart.to_chart_data
        end

        test "chart ignores summaries outside the range" do
          create_rollup(@start_time - 5.days, count: 4)

          assert_nil chart.to_chart_data
        end

        # Edge Cases

        test "chart returns nil when nothing was summarized" do
          assert_nil chart.to_chart_data
        end

        test "chart returns zeroes rather than nil when a day recorded zero" do
          create_rollup(@start_time, count: 0)

          assert_equal [ 0, 0, 0, 0 ], data_points.map(&:last)
        end

        private

        def chart(window: RailsPulse::TimeWindow.new(@start_time, @end_time), period_type: "day")
          RailsPulse::Exceptions::Charts::OccurrenceVolume.new(
            window: window, period_type: period_type
          )
        end

        def data_points
          chart.to_chart_data[:series].first[:data]
        end

        def create_rollup(period_start, count:, summarizable_id: 0, period_type: "day")
          finish = period_type == "hour" ? period_start + 1.hour : period_start + 1.day

          RailsPulse::Summary.create!(
            summarizable_type: ROLLUP,
            summarizable_id: summarizable_id,
            period_type: period_type,
            period_start: period_start,
            period_end: finish,
            count: count
          )
        end
      end
    end
  end
end
