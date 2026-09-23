require "test_helper"

module RailsPulse
  module Jobs
    module Charts
      class FailureRateTest < ActiveSupport::TestCase
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
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_kind_of Hash, result
          assert_includes result.keys, :series
        end

        test "series data contains timestamp/value pairs in milliseconds" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data
          first_point = result[:series].first[:data].first

          assert_kind_of Array, first_point
          assert_operator first_point[0], :>, 1_000_000_000_000
        end

        test "series contains exactly one entry" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_equal 1, result[:series].length
        end

        test "series name is Failure Rate" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_equal "Failure Rate", result[:series].first[:name]
        end

        test "series type is bar" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_equal "bar", result[:series].first[:type]
        end

        test "series color is ChartColors::P95" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_equal RailsPulse::ChartColors::P95, result[:series].first[:color]
        end

        test "data array contains points" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_operator result[:series].first[:data].length, :>, 0
        end

        # Calculation Tests

        test "calculates failure rate as percentage of errors to total" do
          # 10 errors out of 100 runs = 10.0%
          create_summary(days_ago: 1, count: 100, error_count: 10)

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          non_nil = result[:series].first[:data].reject { |v| v[1].nil? }

          assert_operator non_nil.length, :>, 0
          assert_in_delta 10.0, non_nil.first[1]
        end

        test "calculates 100% failure rate when all runs fail" do
          create_summary(days_ago: 1, count: 50, error_count: 50)

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          non_nil = result[:series].first[:data].reject { |v| v[1].nil? }

          assert_in_delta 100.0, non_nil.first[1]
        end

        test "calculates 0% failure rate when no errors" do
          create_summary(days_ago: 1, count: 80, error_count: 0)

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          non_nil = result[:series].first[:data].reject { |v| v[1].nil? }

          assert_in_delta 0.0, non_nil.first[1]
        end

        test "sums counts and errors across multiple summaries in same period" do
          # 5/50 + 5/50 = 10/100 = 10.0%
          create_summary(days_ago: 1, count: 50, error_count: 5)
          create_summary(days_ago: 1, count: 50, error_count: 5, job: rails_pulse_jobs(:mailer_job))

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          non_nil = result[:series].first[:data].reject { |v| v[1].nil? }

          assert_in_delta 10.0, non_nil.first[1]
        end

        test "filters by job when subject provided" do
          other_job = rails_pulse_jobs(:mailer_job)
          create_summary(days_ago: 1, count: 100, error_count: 10)
          create_summary(days_ago: 1, count: 100, error_count: 99, job: other_job)

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data
          non_nil = result[:series].first[:data].reject { |v| v[1].nil? }

          refute_includes non_nil.map { |v| v[1] }, 99.0
          assert_in_delta 10.0, non_nil.first[1]
        end

        test "daily step size is 86400 seconds" do
          chart = FailureRate.new(
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
          chart = FailureRate.new(
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

        test "periods with no data return nil" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert result[:series].first[:data].all? { |v| v[1].nil? }, "expected nil for all empty periods"
        end

        test "handles empty result set" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          result = chart.to_chart_data

          assert_kind_of Hash, result
          assert_operator result[:series].first[:data].length, :>, 0
        end

        test "handles zero count summary without dividing by zero" do
          create_summary(days_ago: 1, count: 0, error_count: 0)

          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            subject: @job,
            window: RailsPulse::TimeWindow.new(2.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          assert_nothing_raised { chart.to_chart_data }
        end

        test "handles large time range" do
          chart = FailureRate.new(
            ransack_query: @ransack_query,
            period_type: "day",
            window: RailsPulse::TimeWindow.new(90.days.ago.beginning_of_day, Time.current.end_of_day)
          )

          result = chart.to_chart_data

          assert_operator result[:series].first[:data].length, :>, 90
        end

        private

        def create_summary(days_ago:, count:, error_count: 0, job: @job)
          period_start = days_ago.days.ago.beginning_of_day
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Job",
            summarizable_id: job.id,
            period_start: period_start,
            period_end: period_start.end_of_day,
            period_type: "day",
            count: count,
            error_count: error_count,
            avg_duration: 100.0
          )
        end
      end
    end
  end
end
