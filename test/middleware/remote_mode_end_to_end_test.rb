require "test_helper"

# Remote mode from request to the wire: real requests through the dummy app,
# collected as always, queued on the writer and posted from its thread, with
# no Rails Pulse table read or written in this process.
class RailsPulse::Middleware::RemoteModeEndToEndTest < ActionDispatch::IntegrationTest
  include ApiClientTestHelpers
  include RemoteTestHelpers

  setup do
    RailsPulse::SchemaCheck.reset!
  end

  teardown do
    RailsPulse::SchemaCheck.reset!
  end

  # Request Tests

  test "a request is sent to the central from the writer thread, and nothing is written here" do
    posts = capture_remote_posts

    rails_pulse_sql = nil
    assert_no_difference -> { RailsPulse::Request.count } do
      rails_pulse_sql = rails_pulse_sql_during do
        with_remote_mode(async: true) do
          get "/fast"

          assert_response :success
          RailsPulse::Tracker.flush!
        end
      end
    end

    request = remote_items(posts).find { |item| item["type"] == "request" }

    assert_equal "GET", request["method"]
    assert_equal "/fast", request["path"]
    assert_equal "home#fast", request["controller_action"]
    assert_equal 200, request["status"]
    assert_predicate request["request_uuid"], :present?
    assert(request["operations"].any? { |op| op["operation_type"] == "sql" && op["actual_sql"].include?("users") })
    assert(request["operations"].none? { |op| op.key?("request_id") }, "local ids stay here")
    assert_equal "#{RemoteTestHelpers::REMOTE_URL}/rails_pulse/v1/batches", posts.first[:uri].to_s
    assert_empty rails_pulse_sql, "remote mode must not read or write Rails Pulse tables"
  end

  test "an exception raised by a request is sent with the request" do
    posts = capture_remote_posts

    rails_pulse_sql = rails_pulse_sql_during do
      with_remote_mode(async: true) do
        post "/exceptions_test/raise", params: { type: "record_not_found" }

        assert_response :not_found
        RailsPulse::Tracker.flush!
      end
    end

    types = remote_items(posts).map { |item| item["type"] }
    exception = remote_items(posts).find { |item| item["type"] == "exception" }

    assert_includes types, "request"
    assert_equal "ActiveRecord::RecordNotFound", exception["exception_class"]
    assert_match %r{\Aapp/controllers/exceptions_test_controller\.rb}, exception["location"]
    assert_equal "/exceptions_test/raise", exception["request_url"]
    assert_equal "POST", exception["request_method"]
    assert_equal "record_not_found", exception.dig("request_params", "type")
    assert_kind_of Array, exception["backtrace"]
    assert_empty rails_pulse_sql
  end

  test "requests detail capture folds are sent slimmed, for the central to fold" do
    posts = capture_remote_posts
    config = RailsPulse.configuration
    original = config.store_full_details
    original_thresholds = config.request_thresholds
    config.request_thresholds = config.request_thresholds.merge(slow: 60_000)
    config.store_full_details = { above_threshold: :slow, sample_rate_below: 0 }

    with_remote_mode(async: true) do
      get "/fast"
      RailsPulse::Tracker.flush!
    end

    request = remote_items(posts).find { |item| item["type"] == "request" }

    refute request["detail"]
    assert request.key?("detail")
    assert_nil request["request_uuid"]
    assert(request["operations"].all? { |op| op.keys.sort == %w[actual_sql duration label operation_type] })
  ensure
    config.store_full_details = original
    config.request_thresholds = original_thresholds
  end

  # Dashboard Tests

  test "the dashboard and its API answer 404 here, since the central serves them" do
    with_remote_mode do
      with_configuration(api_token: "api-token") do
        rails_pulse_sql = rails_pulse_sql_during do
          get "/rails_pulse/"

          assert_response :not_found
          assert_includes response.body, "its dashboard is served there"

          get "/rails_pulse/api/v1/routes", headers: { "X-Rails-Pulse-Token" => "api-token" }

          assert_response :not_found

          # The token is still checked first, so an anonymous caller learns nothing.
          get "/rails_pulse/api/v1/routes"

          assert_response :unauthorized
        end

        assert_empty rails_pulse_sql
      end
    end
  end

  # Failure Tests

  test "a central that is down never reaches the request, which is served as usual" do
    stub_http_failure(Errno::ECONNREFUSED)

    with_remote_mode(async: true) do
      get "/fast"

      assert_response :success
      assert_nothing_raised { RailsPulse::Tracker.flush! }
      # The request's batch, and the heartbeat sent after it, wait for a retry.
      assert_operator RailsPulse::Remote.sender.stats[:pending_batches], :>=, 1
    end
  end

  test "inline sending (async off) still never raises to the request" do
    stub_http_failure(Net::ReadTimeout)

    with_remote_mode(async: false) do
      get "/fast"

      assert_response :success
    end
  end

  private

  # The SQL statements against Rails Pulse tables run during the block.
  def rails_pulse_sql_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].to_s.include?("rails_pulse_")
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
