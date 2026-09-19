require "test_helper"

class TimeRangeConcernTest < ActionController::TestCase
  class TestController < ActionController::Base
    include TimeRangeConcern

    attr_accessor :params, :session

    def initialize
      super
      @params = ActionController::Parameters.new({})
      @session = {}
    end

    def session_global_filters
      @session[:global_filters] || {}
    end
  end

  setup do
    @controller = TestController.new
    @now = Time.current
    travel_to @now
  end

  teardown do
    travel_back
  end

  # Structure Tests

  test "setup_time_range returns array with 4 elements" do
    result = @controller.send(:setup_time_range)

    assert_kind_of Array, result
    assert_equal 4, result.length
  end

  test "setup_time_range returns integers for start and end times" do
    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  test "setup_time_range returns string for selected_range" do
    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_kind_of String, selected_range
  end

  test "setup_time_range returns float for time_diff" do
    _start_time, _end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    assert_kind_of Float, time_diff
  end

  # Default Behavior Tests

  test "setup_time_range returns last_24_hours by default" do
    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range
  end

  test "default_time_range_key returns :last_24_hours" do
    result = @controller.send(:default_time_range_key)

    assert_equal :last_24_hours, result
  end

  test "setup_time_range uses default_time_range_key when no params" do
    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 1.day.ago.beginning_of_hour.to_i
    expected_end = @now.end_of_hour.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "last_24_hours", selected_range
  end

  # Priority 1: Page-Specific Preset Tests

  test "setup_time_range uses page-specific preset from dropdown" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_7_days" })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 1.week.ago.beginning_of_day.to_i
    expected_end = @now.end_of_day.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "last_7_days", selected_range
  end

  test "setup_time_range handles last_7_days preset" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: :last_7_days })

    _start_time, _end_time, selected_range, time_diff = @controller.send(:setup_time_range)

    assert_equal "last_7_days", selected_range
    assert_operator time_diff, :>, 25  # Should use day boundaries
  end

  test "setup_time_range handles last_14_days preset" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_14_days" })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 2.weeks.ago.beginning_of_day.to_i
    expected_end = @now.end_of_day.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "last_14_days", selected_range
  end

  test "setup_time_range handles last_30_days preset" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_30_days" })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 1.month.ago.beginning_of_day.to_i
    expected_end = @now.end_of_day.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "last_30_days", selected_range
  end

  test "setup_time_range falls back to default for unknown preset" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "unknown_range" })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 1.day.ago.beginning_of_hour.to_i
    expected_end = @now.end_of_hour.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "unknown_range", selected_range
  end

  # Priority 2: Page-Specific Custom Range Tests

  test "setup_time_range uses custom range when period_start_range is custom" do
    custom_start = 3.days.ago
    custom_end = 1.day.ago
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "custom",
      custom_date_range: "#{custom_start.strftime("%Y-%m-%d %H:%M")} to #{custom_end.strftime("%Y-%m-%d %H:%M")}"
    })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    # Custom ranges are normalized to day boundaries
    assert_in_delta custom_start.beginning_of_day.to_i, start_time, 86400
    assert_in_delta custom_end.end_of_day.to_i, end_time, 86400
  end

  test "setup_time_range parses custom_date_range with 'to' separator" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "custom",
      custom_date_range: "2025-01-01 00:00 to 2025-01-07 23:59"
    })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  test "setup_time_range handles whitespace in custom range" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "custom",
      custom_date_range: "  2025-01-01 00:00   to   2025-01-07 23:59  "
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
  end

  test "setup_time_range skips custom range when period_start_range not custom" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "last_7_days",
      custom_date_range: "2025-01-01 00:00 to 2025-01-07 23:59"
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_7_days", selected_range  # Should use preset, not custom
  end

  test "setup_time_range skips custom range when custom_date_range missing" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "custom" })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    # Should fall back to default preset since custom_date_range missing
    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range skips custom range when custom_date_range malformed" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "custom",
      custom_date_range: "invalid-date-format"
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    # Falls back to default when custom_date_range doesn't contain " to "
    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range falls back to the default when custom dates do not parse" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "custom",
      custom_date_range: "not-a-date to also-not-a-date"
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range tolerates q that is not a hash" do
    @controller.params = ActionController::Parameters.new(q: "garbage")

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range ignores unparseable zoom bounds" do
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: "yesterday-ish",
      occurred_at_lt: "later"
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range ignores unparseable session filters" do
    @controller.session[:global_filters] = { "start_time" => "x" * 100, "end_time" => "nope" }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_operator start_time, :<, end_time
  end

  # Priority 3: Chart Zoom Tests

  test "setup_time_range uses occurred_at_gteq and occurred_at_lt" do
    zoom_start = 5.days.ago
    zoom_end = 3.days.ago
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: zoom_start,
      occurred_at_lt: zoom_end
    })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta zoom_start.beginning_of_day.to_i, start_time, 10
    assert_in_delta zoom_end.end_of_day.to_i, end_time, 10
  end

  test "setup_time_range parses zoom times correctly" do
    zoom_start = "2025-01-10 12:00:00"
    zoom_end = "2025-01-11 12:00:00"
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: zoom_start,
      occurred_at_lt: zoom_end
    })

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  test "setup_time_range sets selected_range to custom for zoom" do
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: 2.days.ago,
      occurred_at_lt: 1.day.ago
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
  end

  test "setup_time_range ignores zoom when higher priority params present" do
    @controller.params = ActionController::Parameters.new(q: {
      period_start_range: "last_7_days",
      occurred_at_gteq: 2.days.ago,
      occurred_at_lt: 1.day.ago
    })

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_7_days", selected_range  # Preset takes priority
  end

  # Priority 4: Session Time Range Tests

  test "setup_time_range uses session time_range_preference preset" do
    @controller.session[:time_range_preference] = "last_14_days"

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_14_days", selected_range
  end

  test "setup_time_range handles session custom range with type custom" do
    custom_start = 5.days.ago.to_i
    custom_end = 2.days.ago.to_i
    @controller.session[:time_range_preference] = {
      "type" => "custom",
      "start_time" => custom_start,
      "end_time" => custom_end
    }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta custom_start, start_time, 86400  # Within a day
    assert_in_delta custom_end, end_time, 86400
  end

  test "setup_time_range parses session custom start_time and end_time" do
    @controller.session[:time_range_preference] = {
      "type" => "custom",
      "start_time" => 7.days.ago.to_s,
      "end_time" => Time.current.to_s
    }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  test "setup_time_range handles session custom range with symbol keys" do
    # Marshal-backed session stores (e.g. activerecord-session_store) keep the
    # symbol keys the writer used; the cookie store's JSON round trip does not.
    custom_start = 5.days.ago.to_i
    custom_end = 2.days.ago.to_i
    @controller.session[:time_range_preference] = {
      type: "custom",
      start_time: custom_start,
      end_time: custom_end
    }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta custom_start, start_time, 86400
    assert_in_delta custom_end, end_time, 86400
  end

  test "setup_time_range falls back to default for a session hash without a custom type" do
    @controller.session[:time_range_preference] = { "foo" => "bar" }

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range
  end

  test "setup_time_range handles session preset symbols" do
    @controller.session[:time_range_preference] = :last_30_days

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_30_days", selected_range
  end

  test "setup_time_range converts session string preset to symbol" do
    @controller.session[:time_range_preference] = "last_7_days"

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    expected_start = 1.week.ago.beginning_of_day.to_i
    expected_end = @now.end_of_day.to_i

    assert_in_delta expected_start, start_time, 10
    assert_in_delta expected_end, end_time, 10
    assert_equal "last_7_days", selected_range
  end

  test "setup_time_range ignores session when higher priority params present" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_24_hours" })
    @controller.session[:time_range_preference] = "last_30_days"

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_24_hours", selected_range  # Params take priority
  end

  # Priority 5: Global Filters Tests

  test "setup_time_range uses global filters start_time" do
    global_start = 10.days.ago.to_i
    @controller.session[:global_filters] = { "start_time" => global_start }

    start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta global_start, start_time, 86400  # Within a day
  end

  test "setup_time_range uses global filters end_time" do
    global_end = 2.days.ago.to_i
    @controller.session[:global_filters] = { "end_time" => global_end }

    _start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta global_end, end_time, 86400  # Within a day
  end

  test "setup_time_range uses both global filter times when present" do
    global_start = 14.days.ago.to_i
    global_end = 7.days.ago.to_i
    @controller.session[:global_filters] = {
      "start_time" => global_start,
      "end_time" => global_end
    }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_in_delta global_start, start_time, 86400
    assert_in_delta global_end, end_time, 86400
  end

  test "setup_time_range ignores global filters when higher priority params present" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_7_days" })
    @controller.session[:global_filters] = {
      "start_time" => 30.days.ago.to_i,
      "end_time" => Time.current.to_i
    }

    _start_time, _end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "last_7_days", selected_range  # Params take priority
  end

  # Normalization Tests

  test "setup_time_range normalizes a custom range to Time.zone's day boundary regardless of the server OS timezone" do
    # Reproduces a real failure mode: parse_time_param deliberately treats a
    # custom-range string as the server OS's local wall-clock time (see its
    # comment), but Summary buckets are always anchored to Time.zone. Without
    # converting into Time.zone before rounding, a server whose OS timezone
    # differs from Time.zone rounds to a boundary that never matches a stored
    # summary row's period_start, so every chart on the page renders empty
    # even though the metric cards and table (which query differently) show
    # data fine.
    original_tz = ENV["TZ"]
    ENV["TZ"] = "Asia/Bangkok" # UTC+7 — deliberately not Time.zone (UTC in tests)

    @controller.session[:time_range_preference] = {
      "type" => "custom", "start_time" => "2025-01-01 12:00", "end_time" => "2025-01-04 12:00"
    }

    start_time, end_time, selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal "custom", selected_range
    assert_equal Time.zone.parse("2025-01-01 00:00:00"), Time.zone.at(start_time)
    assert_equal Time.zone.parse("2025-01-04 23:59:59"), Time.zone.at(end_time)
  ensure
    ENV["TZ"] = original_tz
  end

  test "setup_time_range normalizes to hour boundaries when time_diff <= 25 hours" do
    start_at = 20.hours.ago
    end_at = Time.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: start_at,
      occurred_at_lt: end_at
    })

    start_time, end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    assert_operator time_diff, :<=, 25
    assert_equal start_at.beginning_of_hour.to_i, start_time
    assert_equal end_at.end_of_hour.to_i, end_time
  end

  test "setup_time_range normalizes to day boundaries when time_diff > 25 hours" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_7_days" })

    start_time, end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    assert_operator time_diff, :>, 25
    # Should be day boundaries - check using Time.zone for consistency
    start_obj = Time.zone.at(start_time)
    end_obj = Time.zone.at(end_time)

    assert_equal 0, start_obj.hour
    assert_equal 23, end_obj.hour
  end

  test "setup_time_range normalizes exactly 25 hours to hour boundaries" do
    start_at = 25.hours.ago
    end_at = Time.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: start_at,
      occurred_at_lt: end_at
    })

    start_time, end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    assert_in_delta 25.0, time_diff, 0.1
    assert_equal start_at.beginning_of_hour.to_i, start_time
    assert_equal end_at.end_of_hour.to_i, end_time
  end

  test "setup_time_range normalizes 25.01 hours to day boundaries" do
    start_at = (25.hours + 1.minute).ago
    end_at = Time.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: start_at,
      occurred_at_lt: end_at
    })

    start_time, end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    assert_operator time_diff, :>, 25
    # Should be day boundaries
    assert_equal start_at.beginning_of_day.to_i, start_time
    assert_equal end_at.end_of_day.to_i, end_time
  end

  test "setup_time_range normalizes 1 hour to hour boundaries" do
    start_at = 1.hour.ago
    end_at = Time.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: start_at,
      occurred_at_lt: end_at
    })

    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_equal start_at.beginning_of_hour.to_i, start_time
    assert_equal end_at.end_of_hour.to_i, end_time
  end

  test "setup_time_range normalizes 7 days to day boundaries" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_7_days" })

    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    # Check it's day boundaries (hour 0 and hour 23) using Time.zone
    start_hour = Time.zone.at(start_time).hour
    end_hour = Time.zone.at(end_time).hour

    assert_equal 0, start_hour
    assert_equal 23, end_hour
  end

  test "setup_time_range calculates time_diff correctly in hours" do
    @controller.params = ActionController::Parameters.new(q: { period_start_range: "last_7_days" })

    _start_time, _end_time, _selected_range, time_diff = @controller.send(:setup_time_range)

    # 7 days = 168 hours (approximately, accounting for normalization)
    assert_in_delta 168.0, time_diff, 1.0
  end

  test "setup_time_range returns normalized times as unix timestamps" do
    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
    assert_operator start_time, :>, 1_600_000_000  # After Sept 2020
    assert_operator end_time, :>, start_time
  end

  # parse_time_param Tests

  test "parse_time_param handles Time objects" do
    time_obj = Time.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: time_obj,
      occurred_at_lt: Time.current
    })

    result = @controller.send(:setup_time_range)

    assert_kind_of Array, result
    assert_equal 4, result.length
  end

  test "parse_time_param handles DateTime objects" do
    datetime_obj = DateTime.current
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: datetime_obj,
      occurred_at_lt: DateTime.current
    })

    result = @controller.send(:setup_time_range)

    assert_kind_of Array, result
  end

  test "parse_time_param handles String with Time.parse" do
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: "2025-01-15 10:30:00",
      occurred_at_lt: "2025-01-15 12:30:00"
    })

    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  test "parse_time_param handles integer timestamps" do
    timestamp_start = 1.day.ago.to_i
    timestamp_end = Time.current.to_i
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: timestamp_start,
      occurred_at_lt: timestamp_end
    })

    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end

  # Edge Cases

  test "setup_time_range handles empty ransack params" do
    @controller.params = ActionController::Parameters.new({})

    result = @controller.send(:setup_time_range)

    assert_kind_of Array, result
    assert_equal 4, result.length
  end

  test "setup_time_range handles reversed time range" do
    # User might accidentally reverse the times
    start_at = 1.day.ago
    end_at = 3.days.ago  # Reversed!
    @controller.params = ActionController::Parameters.new(q: {
      occurred_at_gteq: end_at,  # Later time
      occurred_at_lt: start_at   # Earlier time
    })

    start_time, end_time, _selected_range, _time_diff = @controller.send(:setup_time_range)

    # Should still return valid times (even if reversed)
    assert_kind_of Integer, start_time
    assert_kind_of Integer, end_time
  end
end
