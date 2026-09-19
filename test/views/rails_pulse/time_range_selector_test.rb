require "test_helper"

# Renders the real time range selector partial against the real session helper,
# so a preference shape that survives any session serializer is exercised
# end to end rather than only through the controller concern.
class RailsPulse::TimeRangeSelectorTest < ActionView::TestCase
  helper RailsPulse::ApplicationHelper, RailsPulse::IconHelper

  class PreferenceController < ActionController::Base
    include SessionFiltersConcern

    attr_accessor :session
  end

  def render_selector(preference)
    preference_controller = PreferenceController.new
    preference_controller.session = { time_range_preference: preference }
    view.define_singleton_method(:session_time_range_preference) do
      preference_controller.send(:session_time_range_preference)
    end
    view.define_singleton_method(:rails_pulse) { RailsPulse::Engine.routes.url_helpers }

    render partial: "layouts/rails_pulse/time_range_selector"
  end

  # Structure Tests

  test "renders the default label with no preference" do
    render_selector(nil)

    assert_select "[data-rails-pulse--time-range-target=label]", text: "Last 14 days"
  end

  test "renders a preset preference" do
    render_selector("last_7_days")

    assert_select "[data-rails-pulse--time-range-target=label]", text: "Last 7 days"
    assert_select "button.menu__item--active[data-preset=last_7_days]"
  end

  test "renders a string-keyed custom preference" do
    render_selector("type" => "custom", "start_time" => "2024-01-01 00:00", "end_time" => "2024-01-31 23:59")

    assert_select "[data-rails-pulse--time-range-target=label]", text: "2024-01-01 00:00 to 2024-01-31 23:59"
  end

  test "renders a symbol-keyed custom preference from a Marshal-backed session" do
    render_selector(type: "custom", start_time: "2024-01-01 00:00", end_time: "2024-01-31 23:59")

    assert_select "[data-rails-pulse--time-range-target=label]", text: "2024-01-01 00:00 to 2024-01-31 23:59"
  end

  # Edge Cases

  test "falls back to the default label for an unrecognized hash" do
    render_selector("foo" => "bar")

    assert_select "[data-rails-pulse--time-range-target=label]", text: "Last 14 days"
  end

  test "falls back to the default label for an unrecognized value" do
    render_selector(42)

    assert_select "[data-rails-pulse--time-range-target=label]", text: "Last 14 days"
  end
end
