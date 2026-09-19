require "test_helper"

class RailsPulse::ApplicationControllerTest < ActionDispatch::IntegrationTest
  fixtures :rails_pulse_requests, :rails_pulse_summaries

  def setup
    ENV["TEST_TYPE"] = "functional"
    super
  end

  # Pagination Tests

  test "set_pagination_limit updates session with validated limit" do
    patch rails_pulse.pagination_limit_path, params: { limit: 25 }

    assert_response :success
    assert_equal 25, session[:pagination_limit]
    assert_equal({ "status" => "ok" }, JSON.parse(response.body))
  end

  test "set_pagination_limit clamps limit to minimum of 5" do
    patch rails_pulse.pagination_limit_path, params: { limit: 1 }

    assert_response :success
    assert_equal 5, session[:pagination_limit]
  end

  test "set_pagination_limit clamps limit to maximum of 50" do
    patch rails_pulse.pagination_limit_path, params: { limit: 100 }

    assert_response :success
    assert_equal 50, session[:pagination_limit]
  end

  test "set_pagination_limit handles invalid limit by clamping to 5" do
    patch rails_pulse.pagination_limit_path, params: { limit: "invalid" }

    assert_response :success
    assert_equal 5, session[:pagination_limit]  # "invalid".to_i returns 0, clamped to 5
  end

  test "set_pagination_limit handles zero limit by clamping to 5" do
    patch rails_pulse.pagination_limit_path, params: { limit: 0 }

    assert_response :success
    assert_equal 5, session[:pagination_limit]
  end

  test "set_pagination_limit handles negative limit by clamping to 5" do
    patch rails_pulse.pagination_limit_path, params: { limit: -10 }

    assert_response :success
    assert_equal 5, session[:pagination_limit]
  end

  test "authentication is disabled by default" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(false)
    get rails_pulse.root_path

    assert_response :success
  end

  test "authentication fallback with valid credentials" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    ENV["RAILS_PULSE_USERNAME"] = "admin"
    ENV["RAILS_PULSE_PASSWORD"] = "secret"

    get rails_pulse.root_path, headers: basic_auth_headers("admin", "secret")

    assert_response :success
  end

  test "authentication fallback denies invalid credentials" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    ENV["RAILS_PULSE_USERNAME"] = "admin"
    ENV["RAILS_PULSE_PASSWORD"] = "secret"

    get rails_pulse.root_path, headers: basic_auth_headers("admin", "wrong")

    assert_response :unauthorized
  end

  test "authentication denies access when password not set" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    ENV["RAILS_PULSE_USERNAME"] = "admin"
    ENV["RAILS_PULSE_PASSWORD"] = nil

    get rails_pulse.root_path

    assert_response :unauthorized
  end

  # Authentication Method: Proc

  test "authentication executes Proc authentication method successfully" do
    auth_proc = proc do
      # Simulate successful authentication (no action needed, request proceeds)
      @authenticated_by_proc = true
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)

    get rails_pulse.root_path

    assert_response :success
  end

  test "authentication executes Proc that denies access" do
    auth_proc = proc do
      render plain: "Unauthorized", status: :unauthorized
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)

    get rails_pulse.root_path

    assert_response :unauthorized
  end

  test "authentication executes Proc that raises exception" do
    auth_proc = proc do
      raise StandardError, "Authentication failed"
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)
    RailsPulse.configuration.stubs(:authentication_redirect_path).returns("/login")

    get rails_pulse.root_path

    assert_redirected_to "/login"
  end

  # Authentication Method: Symbol/String

  test "authentication calls Symbol authentication method successfully" do
    # Create a custom authentication method
    RailsPulse::ApplicationController.class_eval do
      def custom_auth_method
        @authenticated_by_symbol = true
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(:custom_auth_method)

    get rails_pulse.root_path

    assert_response :success
  ensure
    # Clean up custom method
    RailsPulse::ApplicationController.send(:remove_method, :custom_auth_method) if RailsPulse::ApplicationController.method_defined?(:custom_auth_method)
  end

  test "authentication calls String authentication method successfully" do
    RailsPulse::ApplicationController.class_eval do
      def string_auth_method
        @authenticated_by_string = true
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns("string_auth_method")

    get rails_pulse.root_path

    assert_response :success
  ensure
    RailsPulse::ApplicationController.send(:remove_method, :string_auth_method) if RailsPulse::ApplicationController.method_defined?(:string_auth_method)
  end

  test "authentication handles missing Symbol authentication method" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(:non_existent_method)

    get rails_pulse.root_path

    assert_response :internal_server_error
    assert_match "Authentication configuration error", response.body
  end

  test "authentication handles missing String authentication method" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns("non_existent_method")

    get rails_pulse.root_path

    assert_response :internal_server_error
    assert_match "Authentication configuration error", response.body
  end

  # Invalid Authentication Type

  test "authentication handles invalid authentication method type Integer" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(12345)

    get rails_pulse.root_path

    assert_response :internal_server_error
    assert_match "Authentication configuration error", response.body
  end

  test "authentication handles invalid authentication method type Array" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns([ :invalid ])

    get rails_pulse.root_path

    assert_response :internal_server_error
  end

  # Exception Handling

  test "authentication rescues StandardError and redirects to configured path" do
    auth_proc = proc do
      raise StandardError, "Authentication failed unexpectedly"
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)
    RailsPulse.configuration.stubs(:authentication_redirect_path).returns("/custom_login")

    get rails_pulse.root_path

    assert_redirected_to "/custom_login"
  end

  test "authentication rescues and uses root redirect path" do
    auth_proc = proc do
      raise StandardError, "Test error"
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)
    RailsPulse.configuration.stubs(:authentication_redirect_path).returns("/")

    get rails_pulse.root_path

    assert_redirected_to "/"
  end

  # Edge Cases

  test "authentication with Symbol method that calls render" do
    RailsPulse::ApplicationController.class_eval do
      def auth_with_render
        render plain: "Custom auth response", status: :forbidden
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(:auth_with_render)

    get rails_pulse.root_path

    assert_response :forbidden
    assert_equal "Custom auth response", response.body
  ensure
    RailsPulse::ApplicationController.send(:remove_method, :auth_with_render) if RailsPulse::ApplicationController.method_defined?(:auth_with_render)
  end

  test "authentication with Symbol method that redirects" do
    RailsPulse::ApplicationController.class_eval do
      def auth_with_redirect
        redirect_to "/external_auth"
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(:auth_with_redirect)

    get rails_pulse.root_path

    assert_redirected_to "/external_auth"
  ensure
    RailsPulse::ApplicationController.send(:remove_method, :auth_with_redirect) if RailsPulse::ApplicationController.method_defined?(:auth_with_redirect)
  end

  test "authentication Proc with context access" do
    auth_proc = proc do
      # Proc has access to controller instance via instance_exec
      if params[:token] == "valid_token"
        @authenticated = true
      else
        render plain: "Invalid token", status: :unauthorized
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)

    get rails_pulse.root_path, params: { token: "valid_token" }

    assert_response :success
  end

  test "authentication Proc denies access with invalid context" do
    auth_proc = proc do
      if params[:token] == "valid_token"
        @authenticated = true
      else
        render plain: "Invalid token", status: :unauthorized
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)

    get rails_pulse.root_path, params: { token: "invalid_token" }

    assert_response :unauthorized
    assert_match "Invalid token", response.body
  end

  # Fail-closed Hook Semantics

  test "authentication denies when the Proc returns false without responding" do
    # `proc { current_user&.admin? }` for a non-admin. Before this was
    # enforced, the request went straight through.
    auth_proc = proc { false }

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)
    RailsPulse.configuration.stubs(:authorize).returns(nil)

    get rails_pulse.root_path

    assert_response :forbidden
  end

  test "authentication allows when the Proc returns nil without responding" do
    # The documented `unless signed_in? then redirect_to … end` style returns
    # nil on success; that must keep working.
    auth_proc = proc { redirect_to "/login" unless true }

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(auth_proc)
    RailsPulse.configuration.stubs(:authorize).returns(nil)

    get rails_pulse.root_path

    assert_response :success
  end

  test "authentication denies when a Symbol method returns false without responding" do
    RailsPulse::ApplicationController.class_eval do
      def predicate_style_auth
        false
      end
    end

    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(:predicate_style_auth)
    RailsPulse.configuration.stubs(:authorize).returns(nil)

    get rails_pulse.root_path

    assert_response :forbidden
  ensure
    RailsPulse::ApplicationController.send(:remove_method, :predicate_style_auth) if RailsPulse::ApplicationController.method_defined?(:predicate_style_auth)
  end

  # authorize Predicate

  test "authorize allows when the predicate is truthy" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(->(controller) { controller.params[:role] == "admin" })

    get rails_pulse.root_path, params: { role: "admin" }

    assert_response :success
  end

  test "authorize denies when the predicate is false" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(->(controller) { controller.params[:role] == "admin" })

    get rails_pulse.root_path, params: { role: "viewer" }

    assert_response :forbidden
  end

  test "authorize denies when the predicate is nil" do
    # current_user&.admin? with no signed-in user.
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(->(_controller) { nil })

    get rails_pulse.root_path

    assert_response :forbidden
  end

  test "authorize runs a zero-arity proc in the controller context" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(proc { params[:role] == "admin" })

    get rails_pulse.root_path, params: { role: "admin" }

    assert_response :success
  end

  test "authorize alone does not fall back to HTTP Basic" do
    ENV["RAILS_PULSE_PASSWORD"] = nil
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(->(_c) { true })

    get rails_pulse.root_path

    assert_response :success
  end

  test "authorize is skipped when authentication_method already responded" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(proc { redirect_to "/login" })
    RailsPulse.configuration.stubs(:authorize).returns(->(_c) { true })

    get rails_pulse.root_path

    assert_redirected_to "/login"
  end

  test "authorize runs after an authentication_method that allowed" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(proc { @signed_in = true })
    RailsPulse.configuration.stubs(:authorize).returns(->(_c) { false })

    get rails_pulse.root_path

    assert_response :forbidden
  end

  test "authorize raising is rescued and redirects" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(true)
    RailsPulse.configuration.stubs(:authentication_method).returns(nil)
    RailsPulse.configuration.stubs(:authorize).returns(->(_c) { raise "boom" })
    RailsPulse.configuration.stubs(:authentication_redirect_path).returns("/login")

    get rails_pulse.root_path

    assert_redirected_to "/login"
  end

  test "authorize is not consulted when authentication is disabled" do
    RailsPulse.configuration.stubs(:authentication_enabled).returns(false)
    RailsPulse.configuration.stubs(:authorize).returns(->(_c) { false })

    get rails_pulse.root_path

    assert_response :success
  end

  # set_global_filters Tests

  test "set_global_filters clears filters when clear param is true" do
    # Set some initial filters
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "2024-01-01",
      end_time: "2024-01-31"
    }

    assert_predicate session[:global_filters], :present?

    # Clear filters
    patch rails_pulse.settings_global_filters_path, params: { clear: "true" }

    assert_nil session[:global_filters]
    assert session[:show_non_tagged]
    assert_redirected_to rails_pulse.root_path
  end

  test "set_global_filters sets time filters" do
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "2024-01-01 00:00",
      end_time: "2024-01-31 23:59"
    }

    assert_equal "2024-01-01 00:00", session[:global_filters]["start_time"]
    assert_equal "2024-01-31 23:59", session[:global_filters]["end_time"]
    assert_redirected_to rails_pulse.root_path
  end

  test "set_global_filters sets performance threshold" do
    patch rails_pulse.settings_global_filters_path, params: {
      performance_threshold: "slow"
    }

    assert_equal "slow", session[:global_filters]["performance_threshold"]
  end

  test "set_global_filters removes performance threshold when empty" do
    # Set initial threshold
    patch rails_pulse.settings_global_filters_path, params: {
      performance_threshold: "slow"
    }

    assert_predicate session[:global_filters]["performance_threshold"], :present?

    # Remove threshold by sending empty value
    patch rails_pulse.settings_global_filters_path, params: {
      performance_threshold: ""
    }

    refute_includes session[:global_filters].keys, "performance_threshold"
  end

  test "set_global_filters converts enabled tags to disabled tags" do
    RailsPulse.configuration.stubs(:tags).returns([ "api", "admin", "maintenance" ])

    patch rails_pulse.settings_global_filters_path, params: {
      enabled_tags: [ "api", "admin" ]
    }

    # Only maintenance should be disabled
    assert_equal [ "maintenance" ], session[:global_filters]["disabled_tags"]
  end

  test "set_global_filters handles non_tagged separately" do
    RailsPulse.configuration.stubs(:tags).returns([ "api", "admin" ])

    patch rails_pulse.settings_global_filters_path, params: {
      enabled_tags: [ "api", "non_tagged" ]
    }

    assert session[:show_non_tagged]
    assert_equal [ "admin" ], session[:global_filters]["disabled_tags"]
  end

  test "set_global_filters removes disabled_tags when all enabled" do
    RailsPulse.configuration.stubs(:tags).returns([ "api", "admin" ])

    patch rails_pulse.settings_global_filters_path, params: {
      enabled_tags: [ "api", "admin" ]
    }

    refute_includes session[:global_filters].keys, "disabled_tags"
  end

  test "set_global_filters handles no enabled_tags param" do
    RailsPulse.configuration.stubs(:tags).returns([ "api", "admin", "maintenance" ])

    patch rails_pulse.settings_global_filters_path, params: {}

    # All tags should be disabled when none enabled
    assert_equal [ "api", "admin", "maintenance" ], session[:global_filters]["disabled_tags"]
    refute session[:show_non_tagged]
  end

  test "set_global_filters preserves existing filters when updating" do
    # Set initial filters
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "2024-01-01",
      end_time: "2024-01-31"
    }

    # Update with performance threshold (should preserve time filters)
    patch rails_pulse.settings_global_filters_path, params: {
      performance_threshold: "slow"
    }

    assert_equal "2024-01-01", session[:global_filters]["start_time"]
    assert_equal "2024-01-31", session[:global_filters]["end_time"]
    assert_equal "slow", session[:global_filters]["performance_threshold"]
  end

  test "set_global_filters redirects back to referrer" do
    patch rails_pulse.settings_global_filters_path,
          params: { start_time: "2024-01-01" },
          headers: { "HTTP_REFERER" => rails_pulse.routes_path }

    assert_redirected_to rails_pulse.routes_path
  end

  # set_time_range Tests

  test "set_time_range stores preset selection" do
    patch rails_pulse.settings_time_range_path, params: {
      preset: "last_7_days"
    }

    assert_equal "last_7_days", session[:time_range_preference]
    assert_redirected_to rails_pulse.root_path
  end

  test "set_time_range stores custom range" do
    patch rails_pulse.settings_time_range_path, params: {
      start_time: "2024-01-01 00:00",
      end_time: "2024-01-31 23:59"
    }

    assert_kind_of Hash, session[:time_range_preference]
    assert_equal "custom", session[:time_range_preference]["type"]
    assert_equal "2024-01-01 00:00", session[:time_range_preference]["start_time"]
    assert_equal "2024-01-31 23:59", session[:time_range_preference]["end_time"]
  end

  test "set_time_range preset takes precedence over custom times" do
    patch rails_pulse.settings_time_range_path, params: {
      preset: "last_24_hours",
      start_time: "2024-01-01 00:00",
      end_time: "2024-01-31 23:59"
    }

    # Should store preset, not custom range
    assert_equal "last_24_hours", session[:time_range_preference]
    refute_kind_of Hash, session[:time_range_preference]
  end

  test "set_time_range handles no params gracefully" do
    # Set initial preference
    patch rails_pulse.settings_time_range_path, params: {
      preset: "last_7_days"
    }
    initial_preference = session[:time_range_preference]

    # Send request with no params
    patch rails_pulse.settings_time_range_path, params: {}

    # Should not change existing preference
    assert_equal initial_preference, session[:time_range_preference]
  end

  test "set_time_range redirects back to referrer" do
    patch rails_pulse.settings_time_range_path,
          params: { preset: "last_24_hours" },
          headers: { "HTTP_REFERER" => rails_pulse.requests_path }

    assert_redirected_to rails_pulse.requests_path
  end

  # set_onboarding_state Tests
  # Note: These tests verify the behavior indirectly by checking response success
  # Rails 8 integration tests don't support assigns(), so we verify the before_action runs without errors

  test "set_onboarding_state runs successfully when requests exist" do
    # Fixture should have requests
    get rails_pulse.root_path

    assert_response :success
  end

  test "set_onboarding_state runs successfully when summaries exist" do
    # Create a summary with updated_at
    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.hour.ago,
      period_end: Time.current,
      period_type: "hour",
      count: 10,
      updated_at: 30.minutes.ago
    )

    get rails_pulse.root_path

    assert_response :success
  end

  test "set_onboarding_state runs successfully with stale summaries" do
    RailsPulse.configuration.stubs(:warn_on_stale_summaries).returns(true)

    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.day.ago,
      period_end: 1.day.ago + 1.hour,
      period_type: "hour",
      count: 10,
      updated_at: 3.hours.ago  # Stale (> 2 hours)
    )

    get rails_pulse.root_path

    assert_response :success
  end

  test "set_onboarding_state runs successfully with recent summaries" do
    RailsPulse.configuration.stubs(:warn_on_stale_summaries).returns(true)

    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.hour.ago,
      period_end: Time.current,
      period_type: "hour",
      count: 10,
      updated_at: 30.minutes.ago  # Recent (< 2 hours)
    )

    get rails_pulse.root_path

    assert_response :success
  end

  test "set_onboarding_state runs successfully with warn_on_stale_summaries disabled" do
    RailsPulse.configuration.stubs(:warn_on_stale_summaries).returns(false)

    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.day.ago,
      period_end: 1.day.ago + 1.hour,
      period_type: "hour",
      count: 10,
      updated_at: 3.hours.ago  # Old but warning disabled
    )

    get rails_pulse.root_path

    assert_response :success
  end

  test "shows migrate_routes banner when a live route has no controller_action" do
    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.hour.ago,
      period_end: Time.current,
      period_type: "hour",
      count: 10,
      updated_at: 30.minutes.ago
    )
    RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: "/slow",
      controller_action: nil,
      tags: "[]"
    )

    get rails_pulse.root_path

    assert_response :success
    assert_match(/Route actions have not been backfilled/, response.body)
    assert_match(/rails_pulse:migrate_routes/, response.body)
  end

  test "does not show migrate_routes banner when blank-action routes are unrecognized" do
    RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Route",
      summarizable_id: 1,
      period_start: 1.hour.ago,
      period_end: Time.current,
      period_type: "hour",
      count: 10,
      updated_at: 30.minutes.ago
    )
    RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: "/ghost-banner-#{SecureRandom.hex(4)}",
      controller_action: nil,
      tags: "[]"
    )

    get rails_pulse.root_path

    assert_response :success
    assert_no_match(/Route actions have not been backfilled/, response.body)
  end

  # Edge Cases

  # Session Input Validation

  test "set_global_filters ignores unparseable time params" do
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "not a time",
      end_time: "2024-01-31 23:59"
    }

    assert_response :redirect
    refute_includes session[:global_filters].keys, "start_time"
  end

  test "set_global_filters ignores oversized time params" do
    # Time.parse is lenient about trailing words, so this parses — but it
    # must not be allowed into the 4 KB cookie session.
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "2024-01-01 00:00 " + ("padding " * 8),
      end_time: "2024-01-31 23:59"
    }

    refute_includes session[:global_filters].keys, "start_time"
  end

  test "set_global_filters drops an unknown performance threshold" do
    patch rails_pulse.settings_global_filters_path, params: { performance_threshold: "<script>" }

    refute_includes session[:global_filters].keys, "performance_threshold"
  end

  test "set_global_filters tolerates enabled_tags sent as a string" do
    RailsPulse.configuration.stubs(:tags).returns([ "api", "critical" ])

    patch rails_pulse.settings_global_filters_path, params: { enabled_tags: "critical" }

    assert_response :redirect
    assert_equal [ "api" ], session[:global_filters]["disabled_tags"]
  end

  test "set_time_range ignores an unknown preset" do
    patch rails_pulse.settings_time_range_path, params: { preset: "x" * 2_000 }

    assert_response :redirect
    assert_nil session[:time_range_preference]
  end

  test "set_time_range ignores an unparseable custom range" do
    patch rails_pulse.settings_time_range_path, params: { start_time: "garbage", end_time: "2024-01-31" }

    assert_nil session[:time_range_preference]
  end

  test "set_global_filters handles empty time params" do
    patch rails_pulse.settings_global_filters_path, params: {
      start_time: "",
      end_time: ""
    }

    # Empty strings should not be added to filters
    refute_includes session[:global_filters].keys, "start_time"
    refute_includes session[:global_filters].keys, "end_time"
  end

  test "set_time_range handles empty custom time params" do
    patch rails_pulse.settings_time_range_path, params: {
      start_time: "",
      end_time: "2024-01-31"
    }

    # Should not set custom range if start_time is empty
    assert_nil session[:time_range_preference]
  end

  private

  def rails_pulse
    RailsPulse::Engine.routes.url_helpers
  end

  def basic_auth_headers(username, password)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end
end
