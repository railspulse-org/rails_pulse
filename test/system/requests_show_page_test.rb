require "test_helper"

class RequestsShowPageTest < ApplicationSystemTestCase
  include SharedTestData

  def setup
    super
    load_shared_test_data
  end

  def test_request_show_page_loads_and_displays_operations
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    assert_text @users_request_1.route.path_and_method
    assert_text "#{@users_request_1.duration.round(2)} ms"

    assert_selector "table.operations-table"
    assert_selector "table tbody tr", minimum: 1
  end

  def test_request_trace_panel_is_present
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    assert_text /request trace/i
    assert_selector ".flame-trace"
    assert_selector ".flame-bar", minimum: 1
  end

  def test_request_trace_shows_lane_labels
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    # users_request_1 has controller and sql operations
    assert_selector ".flame-lane-label", minimum: 1
  end

  def test_operations_panel_title_is_operations
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    assert_text "Operations"
    assert_no_text "Event Sequence"
  end

  def test_operations_table_timeline_uses_flame_bars
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    # The timeline column in the Operations table should use flame-bar styling
    within "table.operations-table" do
      assert_selector ".flame-bar", minimum: 1
    end
  end

  def test_empty_state_displays_when_no_operations_exist
    route_without_ops = RailsPulse::Route.create!(path: "/test/no-ops", http_methods: '["GET"]', tags: "[]")
    request_without_operations = RailsPulse::Request.create!(
      route: route_without_ops,
      duration: 100,
      status: 200,
      is_error: false,
      request_uuid: "test-no-ops",
      controller_action: "TestController#no_ops",
      occurred_at: 1.hour.ago
    )

    visit_rails_pulse_path "/requests/#{request_without_operations.id}"

    assert_text request_without_operations.route.path_and_method
    assert_text "No operations found for this request."
    assert_text "This request may not have had any tracked operations."
    assert_selector "img[src*='search.svg']"
    assert_no_selector "table.operations-table"
  end

  def test_operations_duration_and_impact_fit_a_phone_screen
    page.driver.browser.manage.window.resize_to(390, 844)
    visit_rails_pulse_path "/requests/#{@users_request_1.id}"

    assert_selector "table.operations-table"
    viewport = page.evaluate_script("document.documentElement.clientWidth")

    [ "Duration", "Impact" ].each do |header|
      right = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("table.operations-table th"))
          .find(th => th.textContent.trim() === #{header.to_json})
          .getBoundingClientRect().right
      JS

      assert_operator right, :<=, viewport, "#{header} column ends at #{right}px, past the #{viewport}px viewport"
    end
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end
end
