require "test_helper"

module RailsPulse
  module Jobs
    module Charts
      class DurationTest < ActiveSupport::TestCase
        fixtures :rails_pulse_jobs, :rails_pulse_summaries

        def setup
          ENV["TEST_TYPE"] = "functional"
          super

          RailsPulse::Summary.delete_all

          @job = rails_pulse_jobs(:report_job)
          @start_time = 7.days.ago.beginning_of_day
          @end_time = Time.current.end_of_day
          @ransack_query = RailsPulse::Summary.ransack
        end

        # Structure Tests

        test "to_chart_data returns hash with series key" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_kind_of Hash, result
          assert_includes result.keys, :series
        end

        test "series data contains timestamp/value pairs in milliseconds" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data
          first_point = result[:series].first[:data].first

          assert_kind_of Array, first_point
          assert_operator first_point[0], :>, 1_000_000_000_000
        end

        test "series contains exactly three entries for P50, P95, P99" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_equal 3, result[:series].length
        end

        test "series names are P50, P95, P99" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data
          names = result[:series].map { |s| s[:name] }

          assert_includes names, "P50"
          assert_includes names, "P95"
          assert_includes names, "P99"
        end

        test "all series are line type" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          result[:series].each do |series|
            assert_equal "line", series[:type]
          end
        end

        test "series use correct chart colors" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data
          colors = result[:series].map { |s| s[:color] }

          assert_includes colors, RailsPulse::ChartColors::DEFAULT
          assert_includes colors, RailsPulse::ChartColors::P95
          assert_includes colors, RailsPulse::ChartColors::P99
        end

        test "all series data arrays contain points" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          result[:series].each do |series|
            assert_operator series[:data].length, :>, 0
          end
        end

        # Calculation Tests

        test "calculates weighted P95 across multiple jobs in same period" do
          # Two jobs, same period: count=10 at p95=100ms and count=10 at p95=300ms
          # Weighted avg = (100*10 + 300*10) / 20 = 200ms
          create_summary(days_ago: 1, count: 10, p50: 50, p95: 100, p99: 150)
          create_summary(days_ago: 1, count: 10, p50: 50, p95: 300, p99: 400, job: rails_pulse_jobs(:mailer_job))

          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          p95_series = result[:series].find { |s| s[:name] == "P95" }
          non_nil_values = p95_series[:data].reject { |v| v[1].nil? }

          assert_operator non_nil_values.length, :>, 0
          assert_equal 200, non_nil_values.first[1]
        end

        test "returns nil for periods with no data" do
          # No summaries created — all values should be nil
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data
          p95_series = result[:series].find { |s| s[:name] == "P95" }

          assert p95_series[:data].all? { |v| v[1].nil? }, "expected all nil for periods with no data"
        end

        test "filters by job when subject provided" do
          other_job = rails_pulse_jobs(:mailer_job)
          create_summary(days_ago: 1, count: 10, p50: 50, p95: 200, p99: 300)
          create_summary(days_ago: 1, count: 10, p50: 50, p95: 999, p99: 999, job: other_job)

          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          p95_series = result[:series].find { |s| s[:name] == "P95" }
          non_nil_values = p95_series[:data].reject { |v| v[1].nil? }

          refute_includes non_nil_values.map { |v| v[1] }, 999
        end

        test "daily step size is 86400 seconds" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(3.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data

          if result[:series].first[:data].length > 1
            step_ms = result[:series].first[:data][1][0] - result[:series].first[:data][0][0]

            assert_equal 86400, step_ms / 1000
          end
        end

        test "hourly step size is 3600 seconds" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "hour",
            window: RailsPulse::TimeWindow.new(3.hours.ago.beginning_of_hour, Time.current.end_of_hour)
          )

          result = chart.to_chart_data

          if result[:series].first[:data].length > 1
            step_ms = result[:series].first[:data][1][0] - result[:series].first[:data][0][0]

            assert_equal 3600, step_ms / 1000
          end
        end

        # Edge Cases

        test "handles empty result set" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_kind_of Hash, result
          assert_operator result[:series].first[:data].length, :>, 0
          result[:series].each do |series|
            assert series[:data].all? { |v| v[1].nil? }, "expected nil for all empty periods"
          end
        end

        test "handles summary with zero count without dividing by zero" do
          create_summary(days_ago: 1, count: 0, p50: 0, p95: 0, p99: 0)

          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          assert_nothing_raised { chart.to_chart_data }
        end

        test "handles large time range" do
          chart = Duration.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(90.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data

          assert_operator result[:series].first[:data].length, :>, 90
          result[:series].each do |series|
            assert_equal result[:series].first[:data].length, series[:data].length
          end
        end

        private

        def create_summary(days_ago:, count:, p50:, p95:, p99:, job: @job)
          period_start = days_ago.days.ago.beginning_of_day
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Job",
            summarizable_id: job.id,
            period_start: period_start,
            period_end: period_start.end_of_day,
            period_type: "day",
            count: count,
            avg_duration: p50,
            p50_duration: p50,
            p95_duration: p95,
            p99_duration: p99
          )
        end
      end
    end
  end
end
