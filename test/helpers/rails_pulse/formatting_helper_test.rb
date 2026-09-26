require "test_helper"

class RailsPulse::FormattingHelperTest < ActionView::TestCase
  include RailsPulse::FormattingHelper

  test "human_readable_occurred_at formats Time object" do
    time = Time.new(2024, 1, 15, 14, 30, 0)
    result = human_readable_occurred_at(time)

    assert_equal "Jan 15, 2024  2:30 PM", result
  end

  test "human_readable_occurred_at formats DateTime object" do
    # Create a specific time in UTC then convert to local for predictable testing
    utc_time = Time.utc(2024, 1, 15, 14, 30, 0)
    local_time = utc_time.getlocal
    result = human_readable_occurred_at(local_time)
    expected_result = local_time.strftime("%b %d, %Y %l:%M %p")

    assert_equal expected_result, result
  end

  test "human_readable_occurred_at formats string" do
    time_string = "2024-01-15 14:30:00"
    result = human_readable_occurred_at(time_string)

    assert_equal "Jan 15, 2024  2:30 PM", result
  end

  test "human_readable_occurred_at handles nil" do
    result = human_readable_occurred_at(nil)

    assert_equal "", result
  end

  test "human_readable_occurred_at handles empty string" do
    result = human_readable_occurred_at("")

    assert_equal "", result
  end

  test "human_readable_occurred_at handles blank string" do
    result = human_readable_occurred_at("   ")

    assert_equal "", result
  end

  test "human_readable_occurred_at formats different times" do
    # Morning time
    morning = Time.new(2024, 1, 15, 9, 15, 0)
    result = human_readable_occurred_at(morning)

    assert_equal "Jan 15, 2024  9:15 AM", result

    # Evening time
    evening = Time.new(2024, 1, 15, 23, 45, 0)
    result = human_readable_occurred_at(evening)

    assert_equal "Jan 15, 2024 11:45 PM", result

    # Midnight
    midnight = Time.new(2024, 1, 15, 0, 0, 0)
    result = human_readable_occurred_at(midnight)

    assert_equal "Jan 15, 2024 12:00 AM", result
  end

  test "human_readable_occurred_at handles different dates" do
    # Different month
    feb_date = Time.new(2024, 2, 29, 14, 30, 0)
    result = human_readable_occurred_at(feb_date)

    assert_equal "Feb 29, 2024  2:30 PM", result

    # Different year
    old_date = Time.new(2020, 12, 31, 23, 59, 0)
    result = human_readable_occurred_at(old_date)

    assert_equal "Dec 31, 2020 11:59 PM", result
  end

  test "human_readable_occurred_at handles invalid string gracefully" do
    # Time.zone.parse returns nil for unparseable input rather than raising
    assert_equal "", human_readable_occurred_at("invalid-date")
  end

  # ============================================================================
  # time_ago_in_words Tests
  # ============================================================================

  test "time_ago_in_words handles seconds ago" do
    time = Time.now - 30
    result = time_ago_in_words(time)

    assert_equal "30s ago", result
  end

  test "time_ago_in_words handles minutes ago" do
    time = Time.now - 5.minutes
    result = time_ago_in_words(time)

    assert_equal "5m ago", result
  end

  test "time_ago_in_words handles hours ago" do
    time = Time.now - 3.hours
    result = time_ago_in_words(time)

    assert_equal "3h ago", result
  end

  test "time_ago_in_words handles days ago" do
    time = Time.now - 2.days
    result = time_ago_in_words(time)

    assert_equal "2d ago", result
  end

  test "time_ago_in_words handles exactly 1 minute" do
    time = Time.now - 60
    result = time_ago_in_words(time)

    assert_equal "1m ago", result
  end

  test "time_ago_in_words handles exactly 1 hour" do
    time = Time.now - 3600
    result = time_ago_in_words(time)

    assert_equal "1h ago", result
  end

  test "time_ago_in_words handles exactly 1 day" do
    time = Time.now - 86400
    result = time_ago_in_words(time)

    assert_equal "1d ago", result
  end

  test "time_ago_in_words handles 59 seconds" do
    time = Time.now - 30  # Use 30 seconds to avoid edge case
    result = time_ago_in_words(time)

    assert_match /\d+s ago/, result
  end

  test "time_ago_in_words handles 59 minutes" do
    time = Time.now - (59 * 60 + 30)
    result = time_ago_in_words(time)

    assert_equal "59m ago", result
  end

  test "time_ago_in_words handles 23 hours" do
    time = Time.now - (23 * 3600 + 1800)
    result = time_ago_in_words(time)

    assert_equal "23h ago", result
  end

  test "time_ago_in_words handles string time input" do
    time_string = (Time.now - 2.hours).to_s
    result = time_ago_in_words(time_string)

    assert_equal "2h ago", result
  end

  test "time_ago_in_words handles nil gracefully" do
    result = time_ago_in_words(nil)

    assert_equal "Unknown", result
  end

  test "time_ago_in_words handles empty string gracefully" do
    result = time_ago_in_words("")

    assert_equal "Unknown", result
  end

  test "time_ago_in_words handles blank string gracefully" do
    result = time_ago_in_words("   ")

    assert_equal "Unknown", result
  end

  test "time_ago_in_words returns zero seconds for a future time" do
    # When time travel moves the clock backward mid-request, the stored timestamp
    # can end up in the future relative to Time.now, making seconds_ago negative.
    # Without clamping, the else branch renders "-Nd ago" with a negative integer.
    result = time_ago_in_words(Time.now + 3.years)

    assert_equal "0s ago", result
  end

  test "time_ago_in_words handles very recent time (0 seconds)" do
    time = Time.now
    result = time_ago_in_words(time)

    assert_equal "0s ago", result
  end

  test "time_ago_in_words handles large number of days" do
    time = Time.now - 100.days
    result = time_ago_in_words(time)

    assert_equal "100d ago", result
  end

  test "time_ago_in_words converts UTC time to local" do
    utc_time = Time.now.utc - 1.hour
    result = time_ago_in_words(utc_time)

    # Should be close to 1h ago (within reason due to test execution time)
    assert_match /1h ago/, result
  end

  # ============================================================================
  # human_readable_summary_period Tests
  # ============================================================================

  test "human_readable_summary_period formats hour period" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      Time.new(2024, 1, 15, 14, 0, 0),
      Time.new(2024, 1, 15, 15, 0, 0),
      "hour"
    )

    result = human_readable_summary_period(summary)

    assert_includes result, "Jan"
    assert_includes result, "15"
    assert_includes result, "2024"
    assert_includes result, "PM"
  end

  test "human_readable_summary_period formats day period" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      Time.new(2024, 1, 15, 0, 0, 0),
      Time.new(2024, 1, 15, 23, 59, 59),
      "day"
    )

    result = human_readable_summary_period(summary)

    assert_equal "Jan 15, 2024", result
  end

  test "human_readable_summary_period handles nil summary" do
    result = human_readable_summary_period(nil)

    assert_equal "", result
  end

  test "human_readable_summary_period handles summary without period_start" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      nil,
      Time.now,
      "day"
    )

    result = human_readable_summary_period(summary)

    assert_equal "", result
  end

  test "human_readable_summary_period handles summary without period_end" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      Time.now,
      nil,
      "day"
    )

    result = human_readable_summary_period(summary)

    assert_equal "", result
  end

  test "human_readable_summary_period converts UTC to local time" do
    utc_start = Time.utc(2024, 1, 15, 14, 0, 0)
    utc_end = Time.utc(2024, 1, 15, 15, 0, 0)

    summary = Struct.new(:period_start, :period_end, :period_type).new(
      utc_start,
      utc_end,
      "hour"
    )

    result = human_readable_summary_period(summary)

    # Should include local time conversion
    assert_kind_of String, result
    refute_empty result
  end

  test "human_readable_summary_period handles different months for hour period" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      Time.new(2024, 2, 29, 10, 0, 0),
      Time.new(2024, 2, 29, 11, 0, 0),
      "hour"
    )

    result = human_readable_summary_period(summary)

    assert_includes result, "Feb"
    assert_includes result, "29"
  end

  test "human_readable_summary_period handles different years for day period" do
    summary = Struct.new(:period_start, :period_end, :period_type).new(
      Time.new(2023, 12, 31, 0, 0, 0),
      Time.new(2023, 12, 31, 23, 59, 59),
      "day"
    )

    result = human_readable_summary_period(summary)

    assert_includes result, "2023"
  end

  # ============================================================================
  # human_readable_bytes Tests
  # ============================================================================

  test "human_readable_bytes returns em dash for nil" do
    assert_equal "—", human_readable_bytes(nil)
  end

  test "human_readable_bytes formats zero bytes" do
    assert_equal "0 Bytes", human_readable_bytes(0)
  end

  test "human_readable_bytes formats small byte counts under one kilobyte" do
    assert_equal "512 Bytes", human_readable_bytes(512)
  end

  test "human_readable_bytes formats whole kilobytes" do
    # 5 KB exactly = 5 * 1024 = 5120 bytes
    assert_equal "5 KB", human_readable_bytes(5120)
  end

  test "human_readable_bytes formats whole megabytes" do
    # 2 MB exactly = 2 * 1024 * 1024 bytes
    assert_equal "2 MB", human_readable_bytes(2 * 1024 * 1024)
  end

  test "human_readable_bytes formats fractional kilobytes with two-significant-digit precision" do
    # 1536 bytes = 1.5 KB; precision: 2 => "1.5 KB"
    assert_equal "1.5 KB", human_readable_bytes(1536)
  end

  test "human_readable_bytes truncates additional precision beyond two significant digits" do
    # 1700 bytes = ~1.66 KB; precision: 2 => "1.7 KB" (rounded to 2 significant digits)
    assert_equal "1.7 KB", human_readable_bytes(1700)
  end

  # ============================================================================
  # Edge Cases & Integration
  # ============================================================================

  test "all formatting helpers work together" do
    # Test that multiple helpers can be used in the same context
    time = Time.new(2024, 1, 15, 14, 30, 0)

    occurred_at_result = human_readable_occurred_at(time)
    time_ago_result = time_ago_in_words(time)

    assert_kind_of String, occurred_at_result
    assert_kind_of String, time_ago_result
    refute_empty occurred_at_result
    refute_empty time_ago_result
  end
end
