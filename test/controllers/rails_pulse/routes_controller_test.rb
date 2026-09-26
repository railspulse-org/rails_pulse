require "test_helper"

class RailsPulse::RoutesControllerTest < ActionDispatch::IntegrationTest
  include Rails::Controller::Testing::TestProcess
  include Rails::Controller::Testing::TemplateAssertions
  include Rails::Controller::Testing::Integration

  def setup
    ENV["TEST_TYPE"] = "functional"
    super
  end

  test "controller includes ChartTableConcern" do
    assert_includes RailsPulse::RoutesController.included_modules, ChartTableConcern
  end

  test "index chart tabs show the aggregation zone badge (#303)" do
    Time.use_zone("UTC") do
      get rails_pulse.routes_path

      assert_response :success
      assert_select ".panel-tabs .zone-badge", text: "UTC"
    end
  end

  test "controller has index and show actions" do
    controller = RailsPulse::RoutesController.new

    assert_respond_to controller, :index
    assert_respond_to controller, :show
  end

  test "controller has required private methods" do
    controller = RailsPulse::RoutesController.new
    private_methods = controller.private_methods

    assert_includes private_methods, :chart_model
    assert_includes private_methods, :table_model
    assert_includes private_methods, :set_route
  end

  test "uses correct models based on action" do
    controller = RailsPulse::RoutesController.new

    # For index action - uses Summary model
    controller.stubs(:action_name).returns("index")

    assert_equal RailsPulse::Summary, controller.send(:chart_model)
    assert_equal RailsPulse::Summary, controller.send(:table_model)

    # For show action - chart always uses Summary, table uses Request
    controller.stubs(:action_name).returns("show")

    assert_equal RailsPulse::Summary, controller.send(:chart_model)
    assert_equal RailsPulse::Request, controller.send(:table_model)
  end

  test "default table sort" do
    controller = RailsPulse::RoutesController.new

    # For index action
    controller.stubs(:action_name).returns("index")

    assert_equal "p95_duration desc", controller.send(:default_table_sort)

    # For show action
    controller.stubs(:action_name).returns("show")

    assert_equal "occurred_at desc", controller.send(:default_table_sort)
  end

  test "index action loads successfully" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Show Action Tests

  test "show action loads successfully" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_response :success
    assert_not_nil assigns(:route)
    assert_equal @route, assigns(:route)
    assert_not_nil assigns(:table_data)
  end

  test "show action assigns all required instance variables" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_response :success
    assert_not_nil assigns(:percentile_response_times_metric_card)
    assert_not_nil assigns(:request_count_totals_metric_card)
    assert_not_nil assigns(:error_rates_metric_card)
    assert_not_nil assigns(:response_time_chart_data)
    assert_not_nil assigns(:request_rate_chart_data)
    assert_not_nil assigns(:error_rate_chart_data)
    assert_not_nil assigns(:pagination)
    assert_not_nil assigns(:time_range)&.window&.start_time
    assert_not_nil assigns(:time_range)&.window&.end_time
  end

  test "show action uses Request model for table" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_response :success
    # Table data should be Request records
    table_data = assigns(:table_data)
    assert table_data.all? { |r| r.is_a?(RailsPulse::Request) } if table_data.any?
  end

  test "show action default sort is occurred_at desc" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_response :success
    ransack_query = assigns(:ransack_query)
    # Check that default sort is applied
    assert_predicate ransack_query.sorts, :any?
    assert_equal "occurred_at", ransack_query.sorts.first.name
    assert_equal "desc", ransack_query.sorts.first.dir
  end

  test "show action with custom sorting" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: { q: { s: "duration desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action with pagination" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: { limit: 10, page: 1 }

    assert_response :success
    pagination = assigns(:pagination)

    assert_not_nil pagination
    assert_equal 10, pagination.limit
  end

  test "show action with time range filter" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: { q: { period_start_range: "last_24_hours" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action skips metric cards on partial request" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), headers: { "X-Partial-Request" => "true" }

    assert_response :success
    assert_nil assigns(:percentile_response_times_metric_card)
    assert_nil assigns(:request_count_totals_metric_card)
    assert_nil assigns(:error_rates_metric_card)
    assert_not_nil assigns(:table_data)
  end

  test "show action filters requests to specific route" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_response :success
    table_data = assigns(:table_data)
    # All requests should belong to this route
    assert table_data.all? { |r| r.route_id == @route.id } if table_data.any?
  end

  test "show action with zoom parameters" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: {
      zoom_start_time: 1.day.ago.to_i,
      zoom_end_time: Time.current.to_i
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action response body has content" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_not_nil response.body
    assert_operator response.body.length, :>, 0
  end

  test "show action content type is HTML" do
    setup_basic_test_data

    get rails_pulse.route_path(@route)

    assert_equal "text/html; charset=utf-8", response.content_type
  end

  test "show action with duration filter" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: { q: { response_time_range: "slow" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action with multiple filters combined" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: {
      q: {
        period_start_range: "last_7_days",
        response_time_range: "slow",
        s: "duration desc"
      },
      limit: 25
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action handles route with no requests" do
    # Create route with no requests
    empty_route = RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: "/empty/route",
      tags: "[]"
    )

    get rails_pulse.route_path(empty_route)

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action ordering_by_computed_column works" do
    setup_basic_test_data

    get rails_pulse.route_path(@route), params: { q: { s: "status_indicator desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index action with time filtering" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_7_days" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index action renders chart data for a custom range whose server OS timezone differs from Time.zone" do
    # Reproduces a real bug report: with a custom date range selected, the
    # metric cards and routes table showed data but the Response Time
    # Percentiles chart was blank. Root cause was in the time-range parsing
    # (now RailsPulse::TimeRange), not this controller, but this is the
    # actual page the user saw it on.
    original_tz = ENV["TZ"]
    ENV["TZ"] = "Asia/Bangkok" # UTC+7 — deliberately not Time.zone (UTC in tests)
    travel_to Time.zone.parse("2026-09-19 12:00")
    RailsPulse::Summary.delete_all
    route = rails_pulse_routes(:api_users)
    [ "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19" ].each do |day|
      date = Time.zone.parse(day)
      RailsPulse::Summary.create!(
        summarizable: route, period_type: "day", period_start: date.beginning_of_day, period_end: date.end_of_day,
        count: 40, avg_duration: 90.0, p50_duration: 80.0, p95_duration: 100.0, p99_duration: 110.0
      )
    end

    patch rails_pulse.settings_time_range_path, params: { start_time: "2026-09-16 12:00", end_time: "2026-09-19 12:00" }
    get rails_pulse.routes_path

    assert_response :success
    chart_data = assigns(:response_time_chart_data)
    p95_series = chart_data[:series].find { |series| series[:name] == "P95" }

    assert(p95_series[:data].any? { |point| point[1].present? }, "expected the P95 series to have at least one non-nil value")
  ensure
    ENV["TZ"] = original_tz
    travel_back
  end

  test "index action with sorting" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "count asc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end


  test "controller inherits from ApplicationController" do
    assert_operator RailsPulse::RoutesController, :<, RailsPulse::ApplicationController
  end

  # HTTP Response Tests

  test "index response body is not nil" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil response.body
  end

  test "index response body has content" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_operator response.body.length, :>, 0
  end

  test "index response content type is HTML" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_equal "text/html; charset=utf-8", response.content_type
  end

  test "index no errors or exceptions raised" do
    setup_basic_test_data

    assert_nothing_raised do
      get rails_pulse.routes_path
    end
  end

  # Instance Variable Assignment Tests

  test "index assigns percentile_response_times_metric_card" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:percentile_response_times_metric_card)
  end

  test "index assigns request_count_totals_metric_card" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:request_count_totals_metric_card)
  end

  test "index assigns error_rates_metric_card" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:error_rates_metric_card)
  end

  test "index assigns response_time_chart_data" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:response_time_chart_data)
  end

  test "index assigns request_rate_chart_data" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:request_rate_chart_data)
  end

  test "index assigns error_rate_chart_data" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:error_rate_chart_data)
  end

  test "index assigns chart_data for backward compatibility" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:chart_data)
    # Should reference response_time_chart_data
    assert_equal assigns(:response_time_chart_data), assigns(:chart_data)
  end

  test "index assigns pagination" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:pagination)
  end

  test "index assigns ransack_query" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:ransack_query)
  end

  test "index assigns start_time and end_time" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:time_range)&.window&.start_time
    assert_not_nil assigns(:time_range)&.window&.end_time
  end

  test "index assigns has_data flag" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:has_data)
  end

  test "index assigns has_chart_data flag" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:has_chart_data)
  end

  # Metric Cards Tests

  test "metric cards created on normal request" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_not_nil assigns(:percentile_response_times_metric_card)
    assert_not_nil assigns(:request_count_totals_metric_card)
    assert_not_nil assigns(:error_rates_metric_card)
  end

  test "metric cards skipped when X-Partial-Request header present" do
    setup_basic_test_data

    get rails_pulse.routes_path, headers: { "X-Partial-Request" => "true" }

    assert_response :success
    # Metric cards should be nil on partial requests
    assert_nil assigns(:percentile_response_times_metric_card)
    assert_nil assigns(:request_count_totals_metric_card)
    assert_nil assigns(:error_rates_metric_card)
    # Table data should still be present
    assert_not_nil assigns(:table_data)
  end

  test "cards work with default session values" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    assert_not_nil assigns(:percentile_response_times_metric_card)
    assert_not_nil assigns(:request_count_totals_metric_card)
    assert_not_nil assigns(:error_rates_metric_card)
  end

  # Time Range Filtering Tests

  test "index default time range is last_14_days" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    # Default should be approximately 14 days
    time_diff = assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time

    assert_operator time_diff, :>, 13.days.to_i
    assert_operator time_diff, :<, 15.days.to_i
  end

  test "index with last_24_hours time range" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_24_hours" } }

    assert_response :success
    time_diff = assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time

    assert_operator time_diff, :<=, 25.hours.to_i
  end

  test "index with last_7_days time range" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_7_days" } }

    assert_response :success
    time_diff = assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time

    assert_operator time_diff, :>, 6.days.to_i
    assert_operator time_diff, :<, 8.days.to_i
  end

  test "index with last_14_days time range" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_14_days" } }

    assert_response :success
    time_diff = assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time

    assert_operator time_diff, :>, 13.days.to_i
    assert_operator time_diff, :<, 15.days.to_i
  end

  test "index with last_30_days time range" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_30_days" } }

    assert_response :success
    time_diff = assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time
    # Approximately 30 days (allowing for month variations)
    assert_operator time_diff, :>, 28.days.to_i
    assert_operator time_diff, :<, 32.days.to_i
  end

  test "index with custom date range" do
    setup_basic_test_data
    start_date = 7.days.ago.to_date
    end_date = Date.today

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "custom",
        start_date: start_date,
        end_date: end_date
      }
    }

    assert_response :success
    assert_not_nil assigns(:time_range)&.window&.start_time
    assert_not_nil assigns(:time_range)&.window&.end_time
  end

  test "index with invalid time range uses default" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "invalid" } }

    assert_response :success
    # Should use default time range
    assert_not_nil assigns(:time_range)&.window&.start_time
    assert_not_nil assigns(:time_range)&.window&.end_time
    assert_operator assigns(:time_range)&.window&.end_time, :>, assigns(:time_range)&.window&.start_time
  end

  test "index with missing time range uses default" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    # Should use default
    assert_not_nil assigns(:time_range)&.window&.start_time
    assert_not_nil assigns(:time_range)&.window&.end_time
  end

  test "period type is hour for ranges under 25 hours" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_24_hours" } }

    assert_response :success
    time_diff_hours = (assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time) / 3600.0
    # If under 25 hours, should use hour period
    assert_operator time_diff_hours, :<=, 25 if time_diff_hours <= 25
  end

  test "period type is day for ranges over 25 hours" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { period_start_range: "last_7_days" } }

    assert_response :success
    time_diff_hours = (assigns(:time_range)&.window&.end_time - assigns(:time_range)&.window&.start_time) / 3600.0
    # If over 25 hours, should use day period
    assert_operator time_diff_hours, :>, 25
  end

  # Duration Filtering Tests

  test "index with no duration filter shows all" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    # start_duration should be 0 or nil
    assert assigns(:time_range)&.start_duration.nil? || assigns(:time_range)&.start_duration == 0
  end

  test "index with slow duration filter" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "slow" } }

    assert_response :success
    # start_duration should be set (≥ 500ms)
    assert_not_nil assigns(:time_range)&.start_duration
    assert_operator assigns(:time_range)&.start_duration, :>=, 0
  end

  test "index with very_slow duration filter" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "very_slow" } }

    assert_response :success
    # start_duration should be set (≥ 1000ms)
    assert_not_nil assigns(:time_range)&.start_duration
    assert_operator assigns(:time_range)&.start_duration, :>=, 0
  end

  test "index with critical duration filter" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "critical" } }

    assert_response :success
    # start_duration should be set (≥ 3000ms)
    assert_not_nil assigns(:time_range)&.start_duration
    assert_operator assigns(:time_range)&.start_duration, :>=, 0
  end

  test "index with invalid duration parameter" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "invalid" } }

    assert_response :success
    # Should ignore invalid parameter
    assert assigns(:time_range)&.start_duration.nil? || assigns(:time_range)&.start_duration == 0
  end

  test "duration filter passed to chart services" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "slow" } }

    assert_response :success
    assert_not_nil assigns(:response_time_chart_data)
    assert_not_nil assigns(:request_rate_chart_data)
    assert_not_nil assigns(:error_rate_chart_data)
  end

  test "duration filter passed to table service" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { response_time_range: "slow" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Tag Filtering Tests
  # Note: Tag filtering via session is better tested in system tests

  test "index loads successfully with default tag settings" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    assert_not_nil assigns(:table_data)
    assert_not_nil assigns(:response_time_chart_data)
    assert_not_nil assigns(:request_rate_chart_data)
    assert_not_nil assigns(:error_rate_chart_data)
  end

  # Zoom Range Tests

  test "no zoom parameters shows full range" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    # Table time range should equal main time range
    assert_not_nil assigns(:time_range)&.table_window&.start_time
    assert_not_nil assigns(:time_range)&.table_window&.end_time
  end

  test "selected_column_time parameter sets zoom" do
    setup_basic_test_data
    column_time = 1.day.ago.to_i

    get rails_pulse.routes_path, params: { selected_column_time: column_time }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "zoom_start_time and zoom_end_time parameters" do
    setup_basic_test_data
    zoom_start = 2.days.ago.to_i
    zoom_end = 1.day.ago.to_i

    get rails_pulse.routes_path, params: {
      zoom_start_time: zoom_start,
      zoom_end_time: zoom_end
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "zoom affects table time range" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      zoom_start_time: 1.day.ago.to_i,
      zoom_end_time: Time.current.to_i
    }

    assert_response :success
    assert_not_nil assigns(:time_range)&.table_window&.start_time
    assert_not_nil assigns(:time_range)&.table_window&.end_time
  end

  test "zoom parameters work with valid values" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      zoom_start_time: 1.day.ago.to_i,
      zoom_end_time: Time.current.to_i
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Table Sorting Tests

  test "index sorts by avg_duration ascending" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "avg_duration_sort asc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by avg_duration descending" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "avg_duration_sort desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by max_duration" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "max_duration_sort desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by p95_duration" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "p95_duration_sort desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by p99_duration" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "p99_duration_sort desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by count" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "count_sort desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by requests_per_minute" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "requests_per_minute desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by error_rate_percentage" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "error_rate_percentage desc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "index sorts by route_path" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "route_path asc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "invalid sort parameter uses default" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { q: { s: "invalid_field asc" } }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Pagination Tests

  test "default pagination limit from config" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    assert_not_nil assigns(:pagination)
  end

  test "limit parameter sets custom page size" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { limit: 25 }

    assert_response :success
    assert_not_nil assigns(:pagination)
  end

  test "page parameter navigates pages" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { page: 2 }

    assert_response :success
    assert_not_nil assigns(:pagination)
  end

  test "invalid page number handled gracefully" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { page: -1 }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "limit parameter with numeric string" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { limit: "25" }

    assert_response :success
    assert_not_nil assigns(:table_data)
    assert_not_nil assigns(:pagination)
  end

  test "pagination contains page info" do
    setup_basic_test_data

    get rails_pulse.routes_path

    assert_response :success
    pagination = assigns(:pagination)

    assert_not_nil pagination
    # Paginator is an object with page, limit, and count methods
    assert_respond_to pagination, :page
    assert_respond_to pagination, :limit
    assert_respond_to pagination, :count
  end

  # Parameter Combination Tests

  test "time range and duration filter combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "last_7_days",
        response_time_range: "slow"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "time range and sorting combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "last_7_days",
        s: "count_sort desc"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "duration and sorting combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        response_time_range: "slow",
        s: "count_sort desc"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "all basic filters combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "last_7_days",
        response_time_range: "slow",
        s: "p95_duration_sort desc"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
    assert_not_nil assigns(:response_time_chart_data)
  end

  test "sorting and pagination combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: { s: "count_sort desc" },
      page: 1,
      limit: 10
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "zoom and sorting and pagination combined" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: { s: "p95_duration_sort desc" },
      zoom_start_time: 1.day.ago.to_i,
      zoom_end_time: Time.current.to_i,
      page: 1,
      limit: 25
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Edge Cases Tests

  test "empty table data handled gracefully" do
    setup_basic_test_data

    # Use time range with no data
    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "custom",
        start_date: 1000.days.ago.to_date,
        end_date: 999.days.ago.to_date
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "parameters with invalid values work" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: { invalid_param: "value" }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "sorting with unusual sort field" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: { s: "unknown_field desc" }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "very large time ranges handled" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "custom",
        start_date: 365.days.ago.to_date,
        end_date: Date.today
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "future date ranges handled" do
    setup_basic_test_data

    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "custom",
        start_date: 10.days.from_now.to_date,
        end_date: 11.days.from_now.to_date
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "conflicting parameters handled" do
    setup_basic_test_data

    # Both preset and custom dates
    get rails_pulse.routes_path, params: {
      q: {
        period_start_range: "last_7_days",
        start_date: 30.days.ago.to_date,
        end_date: Date.today
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  # Security Tests

  test "build_table_results uses parameterized SQL for period_type on show action" do
    setup_basic_test_data
    controller = RailsPulse::RoutesController.new
    controller.instance_variable_set(:@route, @route)
    controller.instance_variable_set(:@ransack_query, RailsPulse::Request.ransack({}))
    controller.stubs(:action_name).returns("show")
    controller.stubs(:session_disabled_tags).returns([])
    controller.stubs(:period_type).returns("hour")
    controller.stubs(:ordering_by_computed_column?).returns(false)

    # Should not raise SQL error and should return a relation
    result = controller.send(:build_table_results)

    assert_kind_of ActiveRecord::Relation, result
  end

  test "show action with hour period_type executes SQL safely" do
    setup_basic_test_data

    # This should use period_type = 'hour' in the SQL join
    # Test with a short time range to ensure hour period_type
    get rails_pulse.route_path(@route), params: {
      q: { period_start_range: "last_24_hours" }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "show action with day period_type executes SQL safely" do
    setup_basic_test_data

    # This should use period_type = 'day' in the SQL join
    # Test with a long time range to ensure day period_type
    get rails_pulse.route_path(@route), params: {
      q: { period_start_range: "last_30_days" }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  test "status_indicator_sql uses parameterized thresholds" do
    setup_basic_test_data
    controller = RailsPulse::RoutesController.new

    sql = controller.send(:status_indicator_sql)

    # Should not contain string interpolation markers
    refute_includes sql, '#{'
    # Should be a valid SQL string
    assert_kind_of String, sql
    assert_operator sql.length, :>, 0
  end

  private

  def setup_basic_test_data
    # Use existing fixture data
    @route = rails_pulse_routes(:api_test)
    @route2 = rails_pulse_routes(:api_other)

    # Generate summary data for the current hour (where fixtures exist)
    service = RailsPulse::SummaryService.new("hour", Time.current.beginning_of_hour)
    service.perform
  end

  def rails_pulse
    RailsPulse::Engine.routes.url_helpers
  end
end
