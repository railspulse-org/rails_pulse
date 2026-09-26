require "test_helper"

class RailsPulse::TimeRangeTest < ActiveSupport::TestCase
  setup do
    @now = Time.current
    travel_to @now
  end

  teardown do
    travel_back
  end

  def resolve(q: {}, session: {}, default_key: :last_24_hours, duration_range_type: :route, extra_params: {})
    params = ActionController::Parameters.new({ q: q }.merge(extra_params))
    RailsPulse::TimeRange.resolve(
      params: params, session: session, default_key: default_key, duration_range_type: duration_range_type
    )
  end

  # Structure Tests

  test "resolve returns a frozen Result" do
    result = resolve

    assert_kind_of RailsPulse::TimeRange::Result, result
    assert_predicate result, :frozen?
  end

  test "resolve returns TimeWindow objects for window and table_window" do
    result = resolve

    assert_kind_of RailsPulse::TimeWindow, result.window
    assert_kind_of RailsPulse::TimeWindow, result.table_window
  end

  test "resolve returns a string for selected_time_range" do
    result = resolve

    assert_kind_of String, result.selected_time_range
  end

  # Default Behavior Tests

  test "resolve defaults to last_24_hours" do
    result = resolve

    assert_equal "last_24_hours", result.selected_time_range
    assert_in_delta 1.day.ago.beginning_of_hour.to_i, result.window.start_time.to_i, 10
    assert_in_delta @now.end_of_hour.to_i, result.window.end_time.to_i, 10
  end

  test "resolve uses default_key when given" do
    result = resolve(default_key: :last_7_days)

    assert_equal "last_7_days", result.selected_time_range
  end

  # Priority 1: Page-Specific Preset Tests

  test "page-specific preset from dropdown wins" do
    result = resolve(q: { period_start_range: "last_7_days" })

    assert_equal "last_7_days", result.selected_time_range
    assert_in_delta 1.week.ago.beginning_of_day.to_i, result.window.start_time.to_i, 10
    assert_in_delta @now.end_of_day.to_i, result.window.end_time.to_i, 10
  end

  test "page-specific preset accepts a symbol" do
    result = resolve(q: { period_start_range: :last_14_days })

    assert_equal "last_14_days", result.selected_time_range
  end

  test "page-specific preset falls back to last_24_hours start for an unknown preset, keeping the raw label" do
    result = resolve(q: { period_start_range: "unknown_range" })

    assert_equal "unknown_range", result.selected_time_range
    assert_in_delta 1.day.ago.beginning_of_hour.to_i, result.window.start_time.to_i, 10
  end

  # Priority 2: Page-Specific Custom Range Tests

  test "custom picker range wins when period_start_range is custom" do
    custom_start = 3.days.ago
    custom_end = 1.day.ago
    result = resolve(q: {
      period_start_range: "custom",
      custom_date_range: "#{custom_start.strftime("%Y-%m-%d %H:%M")} to #{custom_end.strftime("%Y-%m-%d %H:%M")}"
    })

    assert_equal "custom", result.selected_time_range
    assert_in_delta custom_start.beginning_of_day.to_i, result.window.start_time.to_i, 86400
    assert_in_delta custom_end.end_of_day.to_i, result.window.end_time.to_i, 86400
  end

  test "custom picker range is skipped when period_start_range is not custom" do
    result = resolve(q: {
      period_start_range: "last_7_days",
      custom_date_range: "2025-01-01 00:00 to 2025-01-07 23:59"
    })

    assert_equal "last_7_days", result.selected_time_range
  end

  test "custom picker range falls back to default when custom_date_range is missing" do
    result = resolve(q: { period_start_range: "custom" })

    assert_equal "last_24_hours", result.selected_time_range
  end

  test "custom picker range falls back to default when custom_date_range has no ' to ' separator" do
    result = resolve(q: { period_start_range: "custom", custom_date_range: "invalid-date-format" })

    assert_equal "last_24_hours", result.selected_time_range
  end

  test "custom picker range falls back to default when the dates do not parse" do
    result = resolve(q: { period_start_range: "custom", custom_date_range: "not-a-date to also-not-a-date" })

    assert_equal "last_24_hours", result.selected_time_range
  end

  # Priority 3: Chart Zoom Tests

  test "chart zoom params win over session and defaults" do
    zoom_start = 5.days.ago
    zoom_end = 3.days.ago
    result = resolve(q: { occurred_at_gteq: zoom_start, occurred_at_lt: zoom_end })

    assert_equal "custom", result.selected_time_range
    assert_in_delta zoom_start.beginning_of_day.to_i, result.window.start_time.to_i, 10
    assert_in_delta zoom_end.end_of_day.to_i, result.window.end_time.to_i, 10
  end

  test "chart zoom is ignored when a page-specific preset is present" do
    result = resolve(q: {
      period_start_range: "last_7_days",
      occurred_at_gteq: 2.days.ago,
      occurred_at_lt: 1.day.ago
    })

    assert_equal "last_7_days", result.selected_time_range
  end

  test "chart zoom ignores unparseable bounds" do
    result = resolve(q: { occurred_at_gteq: "yesterday-ish", occurred_at_lt: "later" })

    assert_equal "last_24_hours", result.selected_time_range
  end

  # Priority 4: Session Time Range Tests

  test "session preset wins over the default" do
    result = resolve(session: { time_range_preference: "last_14_days" })

    assert_equal "last_14_days", result.selected_time_range
  end

  test "session custom range with string type" do
    custom_start = 5.days.ago.to_i
    custom_end = 2.days.ago.to_i
    result = resolve(session: {
      time_range_preference: { "type" => "custom", "start_time" => custom_start, "end_time" => custom_end }
    })

    assert_equal "custom", result.selected_time_range
    assert_in_delta custom_start, result.window.start_time.to_i, 86400
    assert_in_delta custom_end, result.window.end_time.to_i, 86400
  end

  test "session custom range accepts symbol keys (Marshal-backed session stores)" do
    custom_start = 5.days.ago.to_i
    custom_end = 2.days.ago.to_i
    result = resolve(session: {
      time_range_preference: { type: "custom", start_time: custom_start, end_time: custom_end }
    })

    assert_equal "custom", result.selected_time_range
    assert_in_delta custom_start, result.window.start_time.to_i, 86400
    assert_in_delta custom_end, result.window.end_time.to_i, 86400
  end

  test "session hash without a custom type falls back to the default" do
    result = resolve(session: { time_range_preference: { "foo" => "bar" } })

    assert_equal "last_24_hours", result.selected_time_range
  end

  test "session preset accepts a symbol" do
    result = resolve(session: { time_range_preference: :last_30_days })

    assert_equal "last_30_days", result.selected_time_range
  end

  test "session preference is ignored when params take priority" do
    result = resolve(q: { period_start_range: "last_24_hours" }, session: { time_range_preference: "last_30_days" })

    assert_equal "last_24_hours", result.selected_time_range
  end

  # Priority 5: Global Filters Tests

  test "global filters start_time and end_time" do
    global_start = 14.days.ago.to_i
    global_end = 7.days.ago.to_i
    result = resolve(session: { global_filters: { "start_time" => global_start, "end_time" => global_end } })

    assert_equal "custom", result.selected_time_range
    assert_in_delta global_start, result.window.start_time.to_i, 86400
    assert_in_delta global_end, result.window.end_time.to_i, 86400
  end

  test "global filters are ignored when params take priority" do
    result = resolve(
      q: { period_start_range: "last_7_days" },
      session: { global_filters: { "start_time" => 30.days.ago.to_i, "end_time" => Time.current.to_i } }
    )

    assert_equal "last_7_days", result.selected_time_range
  end

  test "unparseable global filter values fall back to the default range but stay marked custom" do
    result = resolve(session: { global_filters: { "start_time" => "x" * 100, "end_time" => "nope" } })

    assert_equal "custom", result.selected_time_range
    assert_operator result.window.start_time, :<, result.window.end_time
  end

  # Normalization Tests

  test "normalizes to hour boundaries when the span is 25 hours or less" do
    start_at = 20.hours.ago
    end_at = Time.current
    result = resolve(q: { occurred_at_gteq: start_at, occurred_at_lt: end_at })

    assert_equal "hour", result.period_type
    assert_equal start_at.beginning_of_hour, result.window.start_time
    assert_equal end_at.end_of_hour, result.window.end_time
  end

  test "normalizes to day boundaries when the span exceeds 25 hours" do
    result = resolve(q: { period_start_range: "last_7_days" })

    assert_equal "day", result.period_type
    assert_equal 0, result.window.start_time.hour
    assert_equal 23, result.window.end_time.hour
  end

  test "normalizes exactly 25 hours to hour boundaries" do
    start_at = 25.hours.ago
    end_at = Time.current
    result = resolve(q: { occurred_at_gteq: start_at, occurred_at_lt: end_at })

    assert_equal "hour", result.period_type
  end

  test "normalizes 25.01 hours to day boundaries" do
    start_at = (25.hours + 1.minute).ago
    end_at = Time.current
    result = resolve(q: { occurred_at_gteq: start_at, occurred_at_lt: end_at })

    assert_equal "day", result.period_type
  end

  # Every custom-range input is interpreted in Time.zone rather than the
  # server OS's local zone (#278) — a server whose OS timezone differs from
  # Time.zone used to shift the parsed instant by that offset.
  test "custom range strings are parsed in Time.zone, not the server OS timezone" do
    original_tz = ENV["TZ"]
    ENV["TZ"] = "Asia/Bangkok" # UTC+7 — deliberately not Time.zone (UTC in tests)

    result = resolve(session: {
      time_range_preference: { "type" => "custom", "start_time" => "2025-01-01 12:00", "end_time" => "2025-01-01 13:00" }
    })

    # If the string were parsed as Bangkok wall-clock time, the instant would
    # land 7 hours earlier once represented in Time.zone (UTC in tests).
    assert_equal Time.zone.parse("2025-01-01 12:00:00"), Time.zone.parse("2025-01-01 12:00")
    assert_equal 12, Time.zone.at(result.window.start_time.to_i).hour
  ensure
    ENV["TZ"] = original_tz
  end

  # -- Zoom / table window --------------------------------------------------

  test "zoom params normalize the table window without moving the chart window" do
    result = resolve(
      q: { period_start_range: "last_30_days" },
      extra_params: { zoom_start_time: 10.days.ago.to_i * 1000, zoom_end_time: 5.days.ago.to_i * 1000 }
    )

    assert_kind_of Integer, result.zoom_start
    assert_kind_of Integer, result.zoom_end
    assert_equal result.zoom_start, result.table_window.start_time.to_i
    assert_equal result.zoom_end, result.table_window.end_time.to_i
    refute_equal result.window.start_time.to_i, result.table_window.start_time.to_i
  end

  test "zoom params are deleted from params, but selected_column_time is not" do
    params = ActionController::Parameters.new(
      q: {},
      zoom_start_time: 5.days.ago.to_i * 1000,
      zoom_end_time: 3.days.ago.to_i * 1000,
      selected_column_time: 3.days.ago.to_i * 1000
    )

    RailsPulse::TimeRange.resolve(params: params, session: {}, default_key: :last_24_hours, duration_range_type: :route)

    refute params.key?(:zoom_start_time)
    refute params.key?(:zoom_end_time)
    assert params.key?(:selected_column_time)
  end

  test "no zoom falls back to the main window for the table" do
    result = resolve(q: { period_start_range: "last_7_days" })

    assert_nil result.zoom_start
    assert_nil result.zoom_end
    assert_equal result.window.start_time.to_i, result.table_window.start_time.to_i
    assert_equal result.window.end_time.to_i, result.table_window.end_time.to_i
  end

  test "selected_column_time takes precedence over zoom for the table window" do
    column_time_ms = 3.days.ago.to_i * 1000
    result = resolve(
      q: { period_start_range: "last_7_days" },
      extra_params: {
        selected_column_time: column_time_ms,
        zoom_start_time: 5.days.ago.to_i * 1000,
        zoom_end_time: 4.days.ago.to_i * 1000
      }
    )

    # Column selection normalizes the table only; the chart keeps the full range.
    refute_equal result.table_window.start_time.to_i, result.window.start_time.to_i
  end

  # -- Duration threshold -----------------------------------------------------

  test "duration threshold defaults to 0 and :all" do
    result = resolve

    assert_equal 0, result.start_duration
    assert_equal :all, result.selected_response_range
  end

  test "duration threshold reads the page-specific avg_duration param" do
    result = resolve(q: { avg_duration: "slow" }, duration_range_type: :route)

    assert_equal RailsPulse.configuration.route_thresholds[:slow], result.start_duration
    assert_equal "slow", result.selected_response_range
  end

  test "duration threshold uses the type-specific thresholds" do
    result = resolve(q: { avg_duration: "slow" }, duration_range_type: :query)

    assert_equal RailsPulse.configuration.query_thresholds[:slow], result.start_duration
  end

  test "duration threshold falls back to the global performance_threshold filter" do
    result = resolve(session: { global_filters: { "performance_threshold" => "very_slow" } }, duration_range_type: :route)

    assert_equal RailsPulse.configuration.route_thresholds[:very_slow], result.start_duration
    assert_equal :very_slow, result.selected_response_range
  end

  test "duration threshold page-specific param wins over the global filter" do
    result = resolve(
      q: { avg_duration: "critical" },
      session: { global_filters: { "performance_threshold" => "slow" } },
      duration_range_type: :route
    )

    assert_equal RailsPulse.configuration.route_thresholds[:critical], result.start_duration
    assert_equal "critical", result.selected_response_range
  end

  test "duration threshold defaults to 0 for an unknown threshold name" do
    result = resolve(q: { avg_duration: "unknown" })

    assert_equal 0, result.start_duration
    assert_equal "unknown", result.selected_response_range
  end

  # Aggregation Zone Tests (#303 — surfacing the zone daily summaries are bucketed in)

  test "aggregation_zone_label is a bare UTC when Time.zone is UTC" do
    Time.use_zone("UTC") do
      assert_equal "UTC", RailsPulse::TimeRange.aggregation_zone_label
    end
  end

  test "aggregation_zone_label names the zone and its offset when Time.zone is not UTC" do
    Time.use_zone("Eastern Time (US & Canada)") do
      assert_equal "Eastern Time (US & Canada) (UTC#{Time.zone.now.formatted_offset})", RailsPulse::TimeRange.aggregation_zone_label
    end
  end

  test "aggregation_zone_short_label is a bare UTC when Time.zone is UTC" do
    Time.use_zone("UTC") do
      assert_equal "UTC", RailsPulse::TimeRange.aggregation_zone_short_label
    end
  end

  test "aggregation_zone_short_label uses the zone abbreviation when it has one" do
    Time.use_zone("Eastern Time (US & Canada)") do
      assert_includes %w[EST EDT], RailsPulse::TimeRange.aggregation_zone_short_label
    end
  end

  test "aggregation_zone_short_label falls back to the offset when the abbreviation is numeric" do
    Time.use_zone("Brasilia") do
      travel_to Time.utc(2024, 7, 1) do
        assert_equal "UTC-03:00", RailsPulse::TimeRange.aggregation_zone_short_label
      end
    end
  end

  test "aggregation_zone_iana returns the IANA identifier for Time.zone" do
    Time.use_zone("Eastern Time (US & Canada)") do
      assert_equal "America/New_York", RailsPulse::TimeRange.aggregation_zone_iana
    end
  end

  # Edge Cases

  test "handles a reversed custom range without raising" do
    start_at = 1.day.ago
    end_at = 3.days.ago
    result = resolve(q: { occurred_at_gteq: end_at, occurred_at_lt: start_at })

    assert_kind_of RailsPulse::TimeWindow, result.window
  end

  test "tolerates q that is not a hash" do
    params = ActionController::Parameters.new(q: "garbage")
    result = RailsPulse::TimeRange.resolve(params: params, session: {}, default_key: :last_24_hours, duration_range_type: :route)

    assert_equal "last_24_hours", result.selected_time_range
  end
end
