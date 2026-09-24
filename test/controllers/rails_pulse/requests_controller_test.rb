require "test_helper"

class RailsPulse::RequestsControllerTest < ActionDispatch::IntegrationTest
  include Rails::Controller::Testing::TestProcess
  include Rails::Controller::Testing::TemplateAssertions
  include Rails::Controller::Testing::Integration

  def setup
    ENV["TEST_TYPE"] = "functional"
    super
    @request_record = rails_pulse_requests(:users_request_1)
  end

  # Controller Structure Tests

  test "index tolerates a non-hash q param" do
    get rails_pulse.requests_path, params: { q: "garbage" }

    assert_response :success
  end

  test "index tolerates an unparseable occurred_at filter" do
    get rails_pulse.requests_path, params: { q: { occurred_at_gteq: "not-a-time" } }

    assert_response :success
  end

  test "controller includes required concerns" do
    assert_includes RailsPulse::RequestsController.included_modules, ChartTableConcern
    assert_includes RailsPulse::RequestsController.included_modules, TagFilterConcern
  end

  test "controller has index and show actions" do
    controller = RailsPulse::RequestsController.new

    assert_respond_to controller, :index
    assert_respond_to controller, :show
  end

  test "controller inherits from ApplicationController" do
    assert_operator RailsPulse::RequestsController, :<, RailsPulse::ApplicationController
  end

  test "uses correct chart and table models" do
    controller = RailsPulse::RequestsController.new

    assert_equal RailsPulse::Summary, controller.send(:chart_model)
    assert_equal RailsPulse::Request, controller.send(:table_model)
  end

  test "chart options are empty for requests index" do
    controller = RailsPulse::RequestsController.new
    options = controller.send(:chart_options)

    assert_empty options
  end

  test "default table sort is by occurred_at descending" do
    controller = RailsPulse::RequestsController.new

    assert_equal "occurred_at desc", controller.send(:default_table_sort)
  end

  # Index Action Tests

  test "index action loads successfully" do
    get rails_pulse.requests_path

    assert_response :success
    # ChartTableConcern should set up table variables (requests page has no charts)
    assert_not_nil assigns(:table_data)
    assert_not_nil assigns(:pagination)
  end

  test "index action with ransack search by status" do
    get rails_pulse.requests_path, params: { q: { status_eq: 200 } }

    assert_response :success
    requests = assigns(:table_data)

    # All returned requests should have status 200
    assert requests.all? { |req| req.status == 200 }
  end

  test "index action with ransack search by controller_action" do
    get rails_pulse.requests_path, params: { q: { controller_action_cont: "Users" } }

    assert_response :success
    requests = assigns(:table_data)

    # Should have at least one request with "Users" in controller_action
    assert requests.any? { |req| req.controller_action.include?("Users") }
  end

  test "index action with error filter" do
    get rails_pulse.requests_path, params: { q: { is_error_eq: true } }

    assert_response :success
    requests = assigns(:table_data)

    # Should have at least one error request
    assert requests.any?(&:is_error)
  end

  test "index action respects pagination" do
    get rails_pulse.requests_path, params: { limit: 5 }

    assert_response :success
    pagination = assigns(:pagination)
    requests = assigns(:table_data)

    assert_not_nil pagination
    assert_operator requests.size, :<=, 5
  end

  test "index action with custom sorting" do
    get rails_pulse.requests_path, params: { q: { s: "duration asc" } }

    assert_response :success
    requests = assigns(:table_data)

    # Verify requests are ordered by duration asc
    if requests.size > 1
      requests.each_cons(2) do |current, next_req|
        assert_operator current.duration, :<=, next_req.duration
      end
    end
  end

  # Show Action Tests

  test "show action loads successfully" do
    get rails_pulse.request_path(@request_record)

    assert_response :success
    assert_not_nil assigns(:request)
    assert_not_nil assigns(:operation_timeline)
    assert_equal @request_record, assigns(:request)
  end

  test "show action creates operation timeline chart" do
    get rails_pulse.request_path(@request_record)

    assert_response :success
    operation_timeline = assigns(:operation_timeline)

    assert_instance_of RailsPulse::Charts::OperationsChart, operation_timeline
  end

  # Custom Chart Ransack Params Tests

  test "requests page loads without charts" do
    get rails_pulse.requests_path

    assert_response :success
    # Requests page doesn't have charts, only table data
    assert_nil assigns(:chart_data)
    assert_not_nil assigns(:table_data)
  end

  # Recent Mode Tests

  test "index with recent mode omits time filters" do
    get rails_pulse.requests_path, params: { q: { period_start_range: "recent" } }

    assert_response :success
    # Recent mode should work without time constraints
    assert_not_nil assigns(:table_data)
    requests = assigns(:table_data)

    assert_operator requests.size, :>, 0
  end

  test "index with no time params defaults to recent mode" do
    get rails_pulse.requests_path

    assert_response :success
    # Should handle no time filtering (recent mode)
    assert_not_nil assigns(:table_data)
  end

  test "index recent mode uses default sort by occurred_at desc" do
    get rails_pulse.requests_path, params: { q: { period_start_range: "recent" } }

    assert_response :success
    requests = assigns(:table_data)

    # Verify recent mode sorts by occurred_at descending
    if requests.size > 1
      requests.each_cons(2) do |current, next_req|
        assert_operator current.occurred_at, :>=, next_req.occurred_at
      end
    end
  end

  # Duration Threshold Conversion Tests

  test "index with slow duration as symbol converts to threshold" do
    get rails_pulse.requests_path, params: { q: { duration_gteq: "slow" } }

    assert_response :success
    requests = assigns(:table_data)

    # All returned requests should meet the slow threshold
    slow_threshold = RailsPulse.configuration.request_thresholds[:slow] || 500

    requests.each do |req|
      assert_operator req.duration, :>=, slow_threshold
    end
  end

  test "index with very_slow duration as symbol converts to threshold" do
    get rails_pulse.requests_path, params: { q: { duration_gteq: "very_slow" } }

    assert_response :success
    requests = assigns(:table_data)

    # All returned requests should meet the very_slow threshold
    very_slow_threshold = RailsPulse.configuration.request_thresholds[:very_slow] || 1000

    requests.each do |req|
      assert_operator req.duration, :>=, very_slow_threshold
    end
  end

  test "index with critical duration as symbol converts to threshold" do
    get rails_pulse.requests_path, params: { q: { duration_gteq: "critical" } }

    assert_response :success
    requests = assigns(:table_data)

    # All returned requests should meet the critical threshold
    critical_threshold = RailsPulse.configuration.request_thresholds[:critical] || 2000

    requests.each do |req|
      assert_operator req.duration, :>=, critical_threshold
    end
  end

  test "index with numeric duration parameter is preserved" do
    get rails_pulse.requests_path, params: { q: { duration_gteq: 1000 } }

    assert_response :success
    requests = assigns(:table_data)

    # All returned requests should meet the numeric threshold
    requests.each do |req|
      assert_operator req.duration, :>=, 1000
    end
  end

  # Route Path Join Tests

  test "index with route_path sort applies join" do
    get rails_pulse.requests_path, params: { q: { s: "route_path asc" } }

    assert_response :success
    # Should not raise error - JOIN is applied when sorting by route_path
    assert_not_nil assigns(:table_data)
  end

  test "index with route_path filter applies join" do
    get rails_pulse.requests_path, params: { q: { route_path_cont: "users" } }

    assert_response :success
    # Should not raise error - JOIN is applied when filtering by route_path
    assert_not_nil assigns(:table_data)
  end

  test "index without route_path criteria works without join" do
    get rails_pulse.requests_path

    assert_response :success
    # Should work fine without JOIN when not filtering/sorting by route_path
    assert_not_nil assigns(:table_data)
  end

  # Response Size Filter & Sort Tests

  test "index sortable by response_size_bytes asc" do
    get rails_pulse.requests_path, params: { q: { s: "response_size_bytes asc" } }

    assert_response :success
    requests = assigns(:table_data)

    # Verify non-nil sizes are in ascending order; nil values may sort to either end depending on DB
    sizes = requests.map(&:response_size_bytes).compact
    if sizes.size > 1
      sizes.each_cons(2) do |current, nxt|
        assert_operator current, :<=, nxt
      end
    end
  end

  test "index sortable by response_size_bytes desc" do
    get rails_pulse.requests_path, params: { q: { s: "response_size_bytes desc" } }

    assert_response :success
    requests = assigns(:table_data)

    sizes = requests.map(&:response_size_bytes).compact
    if sizes.size > 1
      sizes.each_cons(2) do |current, nxt|
        assert_operator current, :>=, nxt
      end
    end
  end

  test "index with min_size_kb filter converts KB to bytes and excludes smaller requests" do
    # Filter to >= 100 KB (102400 bytes); fixtures with response_size_bytes 1024, 5120, 10240, 51200 should be excluded
    get rails_pulse.requests_path, params: { min_size_kb: "100" }

    assert_response :success
    requests = assigns(:table_data)

    requests.each do |req|
      assert_not_nil req.response_size_bytes,
                     "Filter should exclude rows with nil response_size_bytes"
      assert_operator req.response_size_bytes, :>=, 100 * 1024
    end
  end

  test "index with min_size_kb filter at 1 MB excludes mid-size fixtures" do
    # Filter to >= 1024 KB (1 MB) — only critical_request (2 MB) qualifies
    get rails_pulse.requests_path, params: { min_size_kb: "1024" }

    assert_response :success
    requests = assigns(:table_data)

    requests.each do |req|
      assert_operator req.response_size_bytes, :>=, 1024 * 1024
    end
  end

  test "index with blank min_size_kb applies no size filter" do
    small_request = rails_pulse_requests(:error_request) # 1024 bytes (1 KB)

    get rails_pulse.requests_path, params: { min_size_kb: "" }

    assert_response :success
    requests = assigns(:table_data)

    # Verify a 1 KB fixture is still eligible (i.e. no size filter was applied)
    assert_includes requests.map(&:id), small_request.id
  end

  test "index with min_size_kb of zero applies no size filter" do
    small_request = rails_pulse_requests(:error_request) # 1024 bytes (1 KB)
    nil_size_request = rails_pulse_requests(:slow_request_1) # response_size_bytes: nil

    get rails_pulse.requests_path, params: { min_size_kb: "0" }

    assert_response :success
    request_ids = assigns(:table_data).map(&:id)

    # Zero is treated as "no filter": nil rows and small rows both remain eligible
    assert_includes request_ids, small_request.id
    assert_includes request_ids, nil_size_request.id
  end

  test "index with non-numeric min_size_kb is coerced safely with no filter applied" do
    small_request = rails_pulse_requests(:error_request) # 1024 bytes (1 KB)

    get rails_pulse.requests_path, params: { min_size_kb: "not-a-number" }

    assert_response :success
    requests = assigns(:table_data)

    # to_i on non-numeric returns 0, which is treated as no filter — small fixture still eligible
    assert_includes requests.map(&:id), small_request.id
  end

  # Custom Time Range Handling Tests

  test "index with custom time range applies time filters" do
    get rails_pulse.requests_path, params: {
      q: {
        period_start_range: "last_24_hours"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
    # Time filters should be applied for non-recent mode
  end

  test "index handles time mode parameter correctly" do
    # Test that period_start_range parameter is respected
    get rails_pulse.requests_path, params: {
      q: {
        period_start_range: "last_7_days"
      }
    }

    assert_response :success
    assert_not_nil assigns(:table_data)
  end

  private

  def rails_pulse
    RailsPulse::Engine.routes.url_helpers
  end
end
