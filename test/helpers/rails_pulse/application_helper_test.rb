require "test_helper"
require "ostruct"

class RailsPulse::ApplicationHelperTest < ActionView::TestCase
  include RailsPulse::ApplicationHelper

  # ============================================================================
  # rails_pulse_task_command Tests
  # ============================================================================

  test "rails_pulse_task_command is the plain rake command outside a central" do
    assert_equal "bin/rails rails_pulse:backfill_summaries", rails_pulse_task_command("rails_pulse:backfill_summaries")
  end

  test "rails_pulse_task_command names the application being shown on a central" do
    RailsPulse::Central.stubs(:current_application).returns(:shop)

    assert_equal "RAILS_PULSE_APPLICATION=shop bin/rails rails_pulse:backfill_summaries",
                 rails_pulse_task_command("rails_pulse:backfill_summaries")
  end

  # ============================================================================
  # humanize_time_range Tests
  # ============================================================================

  test "humanize_time_range converts :last_day to 'last 24 hours'" do
    assert_equal "last 24 hours", humanize_time_range(:last_day)
  end

  test "humanize_time_range converts :last_week to 'last week'" do
    assert_equal "last week", humanize_time_range(:last_week)
  end

  test "humanize_time_range converts :last_two_weeks to 'last 2 weeks'" do
    assert_equal "last 2 weeks", humanize_time_range(:last_two_weeks)
  end

  test "humanize_time_range converts :last_month to 'last month'" do
    assert_equal "last month", humanize_time_range(:last_month)
  end

  test "humanize_time_range converts :last_24_hours to 'last 24 hours'" do
    assert_equal "last 24 hours", humanize_time_range(:last_24_hours)
  end

  test "humanize_time_range converts :last_7_days to 'last 7 days'" do
    assert_equal "last 7 days", humanize_time_range(:last_7_days)
  end

  test "humanize_time_range converts :last_14_days to 'last 14 days'" do
    assert_equal "last 14 days", humanize_time_range(:last_14_days)
  end

  test "humanize_time_range converts :last_30_days to 'last 30 days'" do
    assert_equal "last 30 days", humanize_time_range(:last_30_days)
  end

  test "humanize_time_range converts :custom to 'custom range'" do
    assert_equal "custom range", humanize_time_range(:custom)
  end

  test "humanize_time_range accepts string symbols" do
    assert_equal "last week", humanize_time_range("last_week")
  end

  test "humanize_time_range handles unknown symbols with humanized fallback" do
    assert_equal "some other range", humanize_time_range(:some_other_range)
  end

  # ============================================================================
  # page_url Tests
  # ============================================================================

  test "page_url merges page parameter into query string" do
    # Setup a mock request with query parameters
    @request = OpenStruct.new(query_parameters: { search: "test" })

    # Stub url_for to return a formatted URL
    define_singleton_method(:url_for) do |params|
      "/test?#{params.to_query}"
    end

    result = page_url(2)

    assert_includes result, "page=2"

    # Clean up
    singleton_class.remove_method(:url_for)
  end
end
