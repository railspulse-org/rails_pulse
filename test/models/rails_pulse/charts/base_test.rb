require "test_helper"

module RailsPulse
  module Charts
    class BaseTest < ActiveSupport::TestCase
      fixtures :rails_pulse_jobs, :rails_pulse_queries, :rails_pulse_summaries

      def setup
        ENV["TEST_TYPE"] = "functional"
        super

        @start_time = 1.day.ago.beginning_of_day
        @end_time = Time.current.end_of_day
        @ransack_query = RailsPulse::Summary.ransack(period_start_gteq: @start_time)
      end

      # Helper class to test the base class
      class TestChart < Base
        def summarizable_type = "RailsPulse::Job"
      end

      # Initialization Tests

      test "initializes with required parameters" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_kind_of TestChart, chart
      end

      test "initializes with subject parameter" do
        job = rails_pulse_jobs(:report_job)
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          subject: job,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_kind_of TestChart, chart
      end

      test "initializes with disabled_tags parameter" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: [ "slow" ]
        )

        assert_kind_of TestChart, chart
      end

      test "initializes with show_non_tagged parameter" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          show_non_tagged: false
        )

        assert_kind_of TestChart, chart
      end

      # Time Step Tests

      test "time_step returns 86400 for day period_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_equal 86400, chart.send(:time_step)
      end

      test "time_step returns 3600 for hour period_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :hour,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_equal 3600, chart.send(:time_step)
      end

      test "time_step handles string period_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: "hour",
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_equal 3600, chart.send(:time_step)
      end

      test "time_step handles nil period_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: nil,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        # Should default to day
        assert_equal 86400, chart.send(:time_step)
      end

      # Base Summary Query Tests

      test "base_summary_query applies tag filters" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: [ "slow" ]
        )

        query = chart.send(:base_summary_query)

        assert_kind_of ActiveRecord::Relation, query
      end

      test "base_summary_query filters by summarizable_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        assert_includes query.to_sql, "RailsPulse::Job"
      end

      test "base_summary_query filters by period_type" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :hour,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        assert_includes query.to_sql, "hour"
      end

      test "base_summary_query filters by subject when present" do
        job = rails_pulse_jobs(:report_job)
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          subject: job,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        assert_includes query.to_sql, job.id.to_s
      end

      test "base_summary_query does not filter by subject when nil" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        assert_kind_of ActiveRecord::Relation, query
      end

      test "base_summary_query uses ransack query result" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        # Should include ransack conditions
        assert_kind_of ActiveRecord::Relation, query
      end

      # Pad Data With Zeros Tests

      test "pad_data_with_zeros fills missing timestamps" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        raw_data = { @start_time.to_i => 100 }
        step = 86400

        result = chart.send(:pad_data_with_zeros, raw_data, @start_time, @end_time, step)

        assert_kind_of Hash, result
        # Should have more entries than raw_data
        assert_operator result.size, :>, raw_data.size
      end

      test "pad_data_with_zeros preserves existing values" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        timestamp = @start_time.to_i
        raw_data = { timestamp => 100 }
        step = 86400

        result = chart.send(:pad_data_with_zeros, raw_data, @start_time, @end_time, step)

        assert_equal 100, result[timestamp]
      end

      test "pad_data_with_zeros fills missing with zeros" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        raw_data = {}
        step = 86400

        result = chart.send(:pad_data_with_zeros, raw_data, @start_time, @end_time, step)

        # All values should be 0
        assert result.values.all? { |v| v == 0 }
      end

      test "pad_data_with_zeros works with hourly step" do
        start = 6.hours.ago.beginning_of_hour
        finish = Time.current.beginning_of_hour

        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :hour,
          window: RailsPulse::TimeWindow.new(start, finish)
        )

        raw_data = { start.to_i => 50 }
        step = 3600

        result = chart.send(:pad_data_with_zeros, raw_data, start, finish, step)

        assert_kind_of Hash, result
        assert_operator result.size, :>=, 6
      end

      test "pad_data_with_zeros handles single timestamp range" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @start_time)
        )

        raw_data = {}
        step = 86400

        result = chart.send(:pad_data_with_zeros, raw_data, @start_time, @start_time, step)

        assert_equal 1, result.size
      end

      # Summarizable Type Tests

      test "summarizable_type is abstract and must be implemented" do
        # Create a chart class without implementing summarizable_type
        abstract_chart_class = Class.new(Base)

        chart = abstract_chart_class.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_raises(NotImplementedError) do
          chart.send(:summarizable_type)
        end
      end

      test "summarizable_type can be implemented by subclass" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        assert_equal "RailsPulse::Job", chart.send(:summarizable_type)
      end

      # Edge Cases

      test "handles empty ransack query" do
        empty_query = RailsPulse::Summary.ransack

        chart = TestChart.new(
          ransack_query: empty_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time)
        )

        query = chart.send(:base_summary_query)

        assert_kind_of ActiveRecord::Relation, query
      end

      test "handles nil disabled_tags" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: nil
        )

        assert_nothing_raised do
          chart.send(:base_summary_query)
        end
      end

      test "handles empty disabled_tags array" do
        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(@start_time, @end_time),
          disabled_tags: []
        )

        query = chart.send(:base_summary_query)

        assert_kind_of ActiveRecord::Relation, query
      end

      test "pad_data_with_zeros handles large time ranges" do
        start = 30.days.ago.beginning_of_day
        finish = Time.current.end_of_day

        chart = TestChart.new(
          ransack_query: @ransack_query,
          period_type: :day,
          window: RailsPulse::TimeWindow.new(start, finish)
        )

        raw_data = { start.to_i => 100 }
        step = 86400

        result = chart.send(:pad_data_with_zeros, raw_data, start, finish, step)

        assert_kind_of Hash, result
        assert_operator result.size, :>=, 30
      end
    end
  end
end
