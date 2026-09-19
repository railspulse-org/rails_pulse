require "test_helper"

module RailsPulse
  class TimeWindowTest < ActiveSupport::TestCase
    # Structure Tests

    test "build returns nil when either bound is missing" do
      assert_nil RailsPulse::TimeWindow.build(nil, Time.current.to_i)
      assert_nil RailsPulse::TimeWindow.build(Time.current.to_i, nil)
    end

    test "coerces epoch seconds into Time.zone" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-16 00:00").to_i, Time.zone.parse("2026-09-19 23:59:59").to_i)

      assert_equal Time.zone.parse("2026-09-16 00:00"), window.start_time
      assert_equal Time.zone.parse("2026-09-19 23:59:59"), window.end_time
      assert_equal Time.zone, window.start_time.time_zone
    end

    test "accepts Time bounds" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-16 00:00"), Time.zone.parse("2026-09-19 12:00"))

      assert_equal Time.zone.parse("2026-09-16 00:00"), window.start_time
    end

    # Calculation Tests

    test "days rounds rather than truncating a range one second short of whole days" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-16 00:00"), Time.zone.parse("2026-09-19 23:59:59"))

      assert_equal 4, window.days
    end

    test "days is never below one" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-19 06:00"), Time.zone.parse("2026-09-19 12:00"))

      assert_equal 1, window.days
    end

    test "dates covers every calendar day whose midnight is inside the window" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-16 00:00"), Time.zone.parse("2026-09-19 23:59:59"))

      assert_equal [ Date.new(2026, 9, 16), Date.new(2026, 9, 17), Date.new(2026, 9, 18), Date.new(2026, 9, 19) ], window.dates
    end

    test "dates skips a partial first day when the start is not on a day boundary" do
      # A start parsed in a system zone ahead of Time.zone lands mid-day; the
      # day bucket for that date starts before the window and is excluded.
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-15 17:00"), Time.zone.parse("2026-09-19 16:59:59"))

      assert_equal Date.new(2026, 9, 16), window.dates.first
      assert_equal Date.new(2026, 9, 19), window.dates.last
    end

    test "hour_starts covers every whole hour inside the window" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-19 06:00"), Time.zone.parse("2026-09-19 08:59:59"))

      assert_equal [ Time.zone.parse("2026-09-19 06:00"), Time.zone.parse("2026-09-19 07:00"), Time.zone.parse("2026-09-19 08:00") ], window.hour_starts
    end

    test "previous returns the same number of days immediately before" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-16 00:00"), Time.zone.parse("2026-09-19 23:59:59"))
      previous = window.previous("day")

      assert_equal Time.zone.parse("2026-09-12 00:00"), previous.start_time
      assert_equal window.start_time, previous.end_time
    end

    test "previous for hours returns the same number of hours immediately before" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-19 06:00"), Time.zone.parse("2026-09-19 12:00"))
      previous = window.previous("hour")

      assert_equal Time.zone.parse("2026-09-19 00:00"), previous.start_time
    end

    # Edge Cases

    test "dates is empty when no midnight falls inside the window" do
      window = RailsPulse::TimeWindow.new(Time.zone.parse("2026-09-19 06:00"), Time.zone.parse("2026-09-19 12:00"))

      assert_empty window.dates
    end
  end
end
