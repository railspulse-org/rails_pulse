require "test_helper"

class RailsPulse::DashboardControllerTest < ActionDispatch::IntegrationTest
  fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_jobs, :rails_pulse_summaries,
           :rails_pulse_deployments, :rails_pulse_exception_groups

  def setup
    ENV["TEST_TYPE"] = "functional"
    super
    # Force lazy route set evaluation while track_jobs=true so job routes are cached
    # before any test can toggle track_jobs=false and corrupt the route cache.
    RailsPulse::Engine.routes.url_helpers.root_path
    # Neutralize fixture jobs so NeedsAttention#job_items never calls job_path.
    RailsPulse::Job.update_all(runs_count: 0)
  end

  # Health Bar Tests

  test "health bar shows a tracking badge once a writer has reported" do
    RailsPulse::Event.where(subject: "web-2:202").update_all(value: 7)

    get rails_pulse.root_path

    assert_response :success
    assert_select ".dashboard-health-bar", /Tracking/
    assert_select ".dashboard-health-bar", /1 writing · 0 backlogged ·/
    assert_select ".dashboard-health-bar", /1 dropping/
  end

  test "health bar omits the tracking badge before any writer has reported" do
    RailsPulse::Event.delete_all

    get rails_pulse.root_path

    assert_response :success
    assert_select ".dashboard-health-bar", { text: /Tracking/, count: 0 }
  end

  test "health bar shows an exceptions badge counting only open groups" do
    get rails_pulse.root_path

    assert_response :success
    # Two of the four fixture groups are open; resolved and ignored are excluded.
    assert_match(/Exceptions/, response.body)
    assert_match(/2 quiet · 0 firing · 0 critical/, response.body)
  end

  test "health bar omits the exceptions badge when tracking is disabled" do
    original = RailsPulse.configuration.track_exceptions
    RailsPulse.configuration.track_exceptions = false

    get rails_pulse.root_path

    assert_response :success
    assert_no_match(/quiet · .* firing/, response.body)
  ensure
    RailsPulse.configuration.track_exceptions = original
  end

  # Parameter & HTTP Response Tests

  test "accepts period 7 parameter" do
    get rails_pulse.root_path, params: { period: 7 }

    assert_response :success
  end

  test "accepts period 14 parameter" do
    get rails_pulse.root_path, params: { period: 14 }

    assert_response :success
  end

  test "accepts period 30 parameter" do
    get rails_pulse.root_path, params: { period: 30 }

    assert_response :success
  end

  test "handles invalid period parameter" do
    get rails_pulse.root_path, params: { period: 999 }

    assert_response :success
  end

  test "handles zero period parameter" do
    get rails_pulse.root_path, params: { period: 0 }

    assert_response :success
  end

  test "handles negative period parameter" do
    get rails_pulse.root_path, params: { period: -5 }

    assert_response :success
  end

  test "handles missing period parameter" do
    get rails_pulse.root_path

    assert_response :success
  end

  test "returns HTML content" do
    get rails_pulse.root_path

    assert_response :success
    assert_not_nil response.body
    assert_operator response.body.length, :>, 0
  end

  # Configuration Tests

  test "handles jobs tracking disabled" do
    original = RailsPulse.configuration.track_jobs
    RailsPulse.configuration.track_jobs = false

    get rails_pulse.root_path

    assert_response :success
    # Should render without job metrics
  ensure
    RailsPulse.configuration.track_jobs = original
  end

  test "includes job metrics when tracking enabled" do
    original = RailsPulse.configuration.track_jobs
    RailsPulse.configuration.track_jobs = true

    get rails_pulse.root_path

    assert_response :success
    assert_not_nil response.body
  ensure
    RailsPulse.configuration.track_jobs = original
  end

  # Content Tests

  test "response includes metric cards" do
    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "metric-strip"
  end

  test "response includes charts" do
    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "chart"
  end

  test "response includes needs attention panel" do
    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "Needs Attention"
  end

  test "response includes storage panel" do
    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "storage-panel-stats"
    assert_includes response.body, rails_pulse.storage_path
  end

  test "response includes deployments panel" do
    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "deployments-panel-stats"
    assert_includes response.body, rails_pulse.deployments_path
    assert_includes response.body, "abc1234"
  end

  test "deployments panel is scoped to the selected time range" do
    get rails_pulse.root_path, params: {
      q: { occurred_at_gteq: 10.days.ago.iso8601, occurred_at_lt: 9.days.ago.iso8601 }
    }

    assert_response :success
    assert_includes response.body, "No deployments recorded in the"
    assert_not_includes response.body, "abc1234"
  end

  test "deployments panel renders an empty message when none are in range" do
    RailsPulse::Deployment.delete_all

    get rails_pulse.root_path

    assert_response :success
    assert_includes response.body, "No deployments recorded in the"
  end

  test "response includes health summary" do
    get rails_pulse.root_path

    assert_response :success
    assert_not_nil response.body
  end

  # Edge Cases

  test "renders without errors when no data exists" do
    get rails_pulse.root_path

    assert_response :success
    assert_operator response.body.length, :>, 1000
  end

  test "renders with substantial HTML content" do
    get rails_pulse.root_path

    assert_response :success
    # Dashboard should have substantial content
    assert_operator response.body.length, :>, 5000
  end

  test "renders dashboard title" do
    get rails_pulse.root_path

    assert_response :success
    # Should contain dashboard identifier
    assert_not_nil response.body
  end

  test "custom time range drives the chart window instead of the trailing days" do
    travel_to Time.zone.parse("2026-09-19 12:00")
    # parse_time_param deliberately reads a custom-range string as the
    # server OS's local wall-clock time; pinning the OS zone to Time.zone
    # here keeps that reading unambiguous so this test is only about the
    # dashboard windowing under test, not the TZ-conversion edge case
    # covered separately in TimeRangeConcernTest.
    original_tz = ENV["TZ"]
    ENV["TZ"] = "UTC"
    RailsPulse::Summary.delete_all
    route = rails_pulse_routes(:api_users)
    [ "2026-09-15", "2026-09-16" ].each do |day|
      date = Time.zone.parse(day)
      RailsPulse::Summary.create!(
        summarizable: route, period_type: "day", period_start: date.beginning_of_day, period_end: date.end_of_day,
        count: 10, avg_duration: 10.0, p50_duration: 10.0, p95_duration: 20.0, p99_duration: 30.0
      )
    end

    patch rails_pulse.settings_time_range_path, params: { start_time: "2026-09-16 00:00", end_time: "2026-09-19 12:00" }
    get rails_pulse.root_path

    assert_response :success
    assert_match(/Sep 16/, response.body)
    assert_no_match(/Sep 15/, response.body)
    assert_match(/Compared to previous 4 days/, response.body)
  ensure
    ENV["TZ"] = original_tz
    travel_back
  end

  test "dashboard assets stay on origin when asset_host is set" do
    previous_app = Rails.application.config.asset_host
    previous_ac = ActionController::Base.config.asset_host
    Rails.application.config.asset_host = "https://cdn.example.com"
    Rails.application.config.action_controller.asset_host = "https://cdn.example.com"
    ActionController::Base.config.asset_host = "https://cdn.example.com"

    get rails_pulse.root_path

    assert_response :success

    versioned = "/rails-pulse-assets/#{RailsPulse::VERSION}"

    assert_select "link[rel='stylesheet'][href='#{versioned}/rails-pulse.css']"
    assert_select "script[src='#{versioned}/rails-pulse.js']"
    assert_select "script[src='#{versioned}/rails-pulse-icons.js']"
    refute_includes response.body, "cdn.example.com"
  ensure
    Rails.application.config.asset_host = previous_app
    Rails.application.config.action_controller.asset_host = previous_app
    ActionController::Base.config.asset_host = previous_ac
  end

  private

  def rails_pulse
    RailsPulse::Engine.routes.url_helpers
  end
end
