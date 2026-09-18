require "test_helper"

module RailsPulse
  module Dashboard
    module Concerns
      class TimeRangeHelperTest < ActiveSupport::TestCase
        # Test class that includes the concern
        class TestClass
          include TimeRangeHelper

          attr_reader :period

          def initialize(period:)
            @period = period
          end
        end

        def setup
          @now = Time.current
          travel_to @now
        end

        def teardown
          travel_back
        end

        # Structure Tests

        test "period_range returns array with start and end times" do
          instance = TestClass.new(period: 7)
          result = instance.send(:period_range)

          assert_kind_of Array, result
          assert_equal 2, result.length
        end

        test "period_range returns Time objects" do
          instance = TestClass.new(period: 7)
          start_time, end_time = instance.send(:period_range)

          assert_kind_of Time, start_time
          assert_kind_of Time, end_time
        end

        # Calculation Tests

        test "period_range start is N days ago at beginning of day" do
          instance = TestClass.new(period: 7)
          start_time, _end_time = instance.send(:period_range)

          expected_start = 7.days.ago.beginning_of_day

          assert_equal expected_start, start_time
        end

        test "period_range end is current time" do
          instance = TestClass.new(period: 7)
          _start_time, end_time = instance.send(:period_range)

          assert_in_delta @now.to_f, end_time.to_f, 1.0
        end

        test "period_range respects custom period values" do
          instance = TestClass.new(period: 30)
          start_time, _end_time = instance.send(:period_range)

          expected_start = 30.days.ago.beginning_of_day

          assert_equal expected_start, start_time
        end

        test "period_range with period 14 returns 14 days ago" do
          instance = TestClass.new(period: 14)
          start_time, _end_time = instance.send(:period_range)

          expected_start = 14.days.ago.beginning_of_day

          assert_equal expected_start, start_time
        end

        # Time Difference Tests

        test "period_range span matches period in days" do
          instance = TestClass.new(period: 7)
          start_time, end_time = instance.send(:period_range)

          # Span is N days ago at midnight to now, so it's >= N days but < N+1 days
          days_difference = ((end_time - start_time) / 1.day).floor

          assert_equal 7, days_difference
        end

        test "period_range span matches period for 30 days" do
          instance = TestClass.new(period: 30)
          start_time, end_time = instance.send(:period_range)

          # Span is N days ago at midnight to now, so it's >= N days but < N+1 days
          days_difference = ((end_time - start_time) / 1.day).floor

          assert_equal 30, days_difference
        end

        # Edge Cases

        test "period_range handles period of 1 day" do
          instance = TestClass.new(period: 1)
          start_time, end_time = instance.send(:period_range)

          assert_equal 1.day.ago.beginning_of_day, start_time
          assert_in_delta @now.to_f, end_time.to_f, 1.0
        end

        test "period_range handles period of 0 days" do
          instance = TestClass.new(period: 0)
          start_time, end_time = instance.send(:period_range)

          # 0 days ago = start of today
          assert_equal Time.current.beginning_of_day, start_time
          assert_in_delta @now.to_f, end_time.to_f, 1.0
        end

        test "period_range handles large periods" do
          instance = TestClass.new(period: 365)
          start_time, _end_time = instance.send(:period_range)

          expected_start = 365.days.ago.beginning_of_day

          assert_equal expected_start, start_time
        end

        test "period_range start time is always at beginning_of_day" do
          instance = TestClass.new(period: 7)
          start_time, _end_time = instance.send(:period_range)

          assert_equal start_time, start_time.beginning_of_day
        end

        test "period_range end time is not modified" do
          specific_time = Time.zone.parse("2025-04-08 14:30:00")
          travel_to specific_time

          instance = TestClass.new(period: 7)
          _start_time, end_time = instance.send(:period_range)

          assert_equal specific_time, end_time
          refute_equal end_time, end_time.beginning_of_day
        end

        # Explicit Range Tests

        class RangedTestClass < TestClass
          def initialize(period:, start_time:, end_time:)
            super(period: period)
            @start_time = start_time
            @end_time = end_time
          end
        end

        test "period_range uses the explicit range when one is given" do
          start_time = Time.zone.parse("2026-09-16 00:00")
          end_time = Time.zone.parse("2026-09-19 23:59:59")
          instance = RangedTestClass.new(period: 3, start_time: start_time.to_i, end_time: end_time.to_i)

          assert_equal [ start_time, end_time ], instance.send(:period_range)
        end

        test "HealthSummary and NeedsAttention accept an explicit range" do
          start_time = Time.zone.parse("2026-09-16 00:00")
          end_time = Time.zone.parse("2026-09-19 23:59:59")

          [ RailsPulse::Dashboard::HealthSummary, RailsPulse::Dashboard::NeedsAttention ].each do |klass|
            instance = klass.new(period: 3, start_time: start_time.to_i, end_time: end_time.to_i)

            assert_equal [ start_time, end_time ], instance.send(:period_range), klass.name
          end
        end

        # Integration Tests

        test "period_range works with actual dashboard classes" do
          # HealthSummary includes TimeRangeHelper
          health_summary = RailsPulse::Dashboard::HealthSummary.new(period: 7)
          result = health_summary.send(:period_range)

          assert_kind_of Array, result
          assert_equal 2, result.length
        end

        test "period_range is private method" do
          instance = TestClass.new(period: 7)

          refute_respond_to instance, :period_range
        end
      end
    end
  end
end
