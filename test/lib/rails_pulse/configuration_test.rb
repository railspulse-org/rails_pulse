require "test_helper"

module RailsPulse
  class ConfigurationTest < ActiveSupport::TestCase
    def build_config(&block)
      config = Configuration.new
      config.instance_eval(&block) if block
      config.validate_configuration!
      config
    end

    # Store Full Details Tests

    test "store_full_details defaults to :all" do
      config = Configuration.new

      assert_equal :all, config.store_full_details
      assert_nil config.detail_capture_settings
    end

    test "store_full_details above a threshold reads that threshold's durations with a 1% default sample" do
      config = Configuration.new
      config.store_full_details = { above_threshold: :slow }

      settings = config.detail_capture_settings

      assert_predicate settings, :frozen?
      assert_equal :slow, settings.threshold
      assert_in_delta 700.0, settings.requests_slower_than
      assert_in_delta 100.0, settings.queries_slower_than
      assert_in_delta 0.01, settings.sample_rate
    end

    test "store_full_details accepts any threshold key and a sample rate" do
      config = Configuration.new
      config.store_full_details = { above_threshold: "critical", sample_rate_below: 0.001 }

      settings = config.detail_capture_settings

      assert_equal :critical, settings.threshold
      assert_in_delta 4000.0, settings.requests_slower_than
      assert_in_delta 1000.0, settings.queries_slower_than
      assert_in_delta 0.001, settings.sample_rate
    end

    test "store_full_details follows custom thresholds set in either order" do
      config = build_config do
        self.store_full_details = { above_threshold: :warning }
        self.request_thresholds = { warning: 400, slow: 1000 }
        self.query_thresholds = { warning: 50, slow: 200 }
      end

      assert_in_delta 400.0, config.detail_capture_settings.requests_slower_than
      assert_in_delta 50.0, config.detail_capture_settings.queries_slower_than

      config.request_thresholds = { warning: 600, slow: 1000 }

      assert_in_delta 600.0, config.detail_capture_settings.requests_slower_than
    end

    test "store_full_details describes itself for status and the storage page" do
      config = Configuration.new
      config.store_full_details = { above_threshold: :slow, sample_rate_below: 0.015 }

      assert_equal "above :slow (requests over 700ms, queries over 100ms), 1.5% sample, errors", config.detail_capture_settings.description

      config.store_full_details = { above_threshold: :slow, sample_rate_below: 0 }

      assert_equal "above :slow (requests over 700ms, queries over 100ms), errors", config.detail_capture_settings.description
    end

    test "setting store_full_details back to :all clears the settings" do
      config = Configuration.new
      config.store_full_details = { above_threshold: :slow }
      config.store_full_details = :all

      assert_nil config.detail_capture_settings
    end

    test "store_full_details rejects anything but :all or a hash" do
      config = Configuration.new

      [ nil, :slow, true ].each do |bad|
        error = assert_raises(ArgumentError) { config.store_full_details = bad }
        assert_includes error.message, "store_full_details must be :all or a hash like { above_threshold: :slow }"
      end
    end

    test "store_full_details rejects unknown keys, a number for above and a bad sample rate" do
      config = Configuration.new

      error = assert_raises(ArgumentError) { config.store_full_details = { above_threshold: :slow, errors: false } }
      assert_includes error.message, "unknown keys [:errors]"

      error = assert_raises(ArgumentError) { config.store_full_details = { above_threshold: 500 } }
      assert_includes error.message, "must be a key from request_thresholds and query_thresholds, such as :slow"

      [ -0.1, 1.5, "0.1" ].each do |bad|
        error = assert_raises(ArgumentError) { config.store_full_details = { above_threshold: :slow, sample_rate_below: bad } }
        assert_includes error.message, "store_full_details[:sample_rate_below]"
      end
    end

    test "store_full_details names a threshold missing from either hash once configuration is validated" do
      config = Configuration.new
      config.request_thresholds = { warning: 400, slow: 1000 }
      config.store_full_details = { above_threshold: :warning }

      assert_nil config.detail_capture_settings

      error = assert_raises(ArgumentError) { config.validate_configuration! }
      assert_includes error.message, "query_thresholds has no :warning (it has :slow, :very_slow, :critical)"
    end

    # Default Values Tests

    test "event_retention_period defaults to 90 days with no exempt kinds, and both are validated" do
      config = Configuration.new

      assert_equal 90.days, config.event_retention_period
      assert_empty config.event_retention_exempt_kinds
      assert_raises(ArgumentError) { build_config { @event_retention_period = 90 } }
      assert_raises(ArgumentError) { build_config { @event_retention_exempt_kinds = [ :job_heartbeat ] } }
    end

    test "cloud is off by default, pointed at production ingestion, in this Rails environment" do
      cloud = Configuration.new.cloud

      assert_not cloud.enabled?
      assert_nil cloud.api_key
      assert_nil cloud.application
      assert_equal "https://ingest.railspulse.com", cloud.url
      assert_equal Rails.env.to_s, cloud.environment
    end

    test "cloud is enabled only when both the key and the application are set" do
      config = Configuration.new
      config.cloud.api_key = "rpc_4f9Kx2mQ8vTzL1nB7wYc3HdR6sJe5PaU"

      assert_not config.cloud.enabled?

      config.cloud.application = "shop"

      assert_predicate config.cloud, :enabled?
    end

    test "cloud host_label defaults to RAILS_PULSE_HOST_LABEL" do
      ENV["RAILS_PULSE_HOST_LABEL"] = "web-1"

      assert_equal "web-1", Configuration.new.cloud.host_label
    ensure
      ENV.delete("RAILS_PULSE_HOST_LABEL")
    end

    test "cloud settings are validated" do
      assert_raises(ArgumentError) { build_config { @cloud.api_key = "test-api-token" } }
      assert_raises(ArgumentError) { build_config { @cloud.api_key = "rpc_" } }
      assert_raises(ArgumentError) { build_config { @cloud.url = "ingest.railspulse.com" } }
      assert_raises(ArgumentError) { build_config { @cloud.application = "My Shop" } }
      assert_raises(ArgumentError) { build_config { @cloud.environment = "" } }
      assert_raises(ArgumentError) { build_config { @cloud.host_label = "x" * 256 } }
      assert_nothing_raised do
        build_config do
          @cloud.api_key = "rpc_4f9Kx2mQ8vTzL1nB7wYc3HdR6sJe5PaU"
          @cloud.application = "shop"
          @cloud.url = "https://staging.railspulse.com/ingest"
        end
      end
    end

    test "cloud settings never show the key when inspected" do
      config = Configuration.new
      config.cloud.api_key = "rpc_4f9Kx2mQ8vTzL1nB7wYc3HdR6sJe5PaU"

      assert_not_includes config.cloud.inspect, "4f9Kx2mQ"
      assert_includes config.cloud.inspect, "[FILTERED]"
    end

    test "enabled defaults to true" do
      config = Configuration.new

      assert config.enabled
    end

    test "api_token and deployment_token default to nil" do
      config = Configuration.new

      assert_nil config.api_token
      assert_nil config.deployment_token
    end

    # deployment_api_token only ever authorized deployment writes, so the
    # pre-0.5 name keeps doing that rather than granting API reads.
    test "deployment_api_token is an alias for deployment_token" do
      config = Configuration.new
      config.deployment_api_token = "legacy-token"

      assert_equal "legacy-token", config.deployment_token
      assert_equal "legacy-token", config.deployment_api_token
      assert_nil config.api_token
    end

    test "the read token does not authorize deployment writes" do
      config = Configuration.new
      config.api_token = "read-only"

      assert_nil config.deployment_token
    end

    test "track_jobs defaults to false" do
      config = Configuration.new

      refute config.track_jobs
    end

    test "track_assets defaults to false" do
      config = Configuration.new

      refute config.track_assets
    end

    test "async defaults to true" do
      config = Configuration.new

      assert config.async
    end

    test "archiving_enabled defaults to true" do
      config = Configuration.new

      assert config.archiving_enabled
    end

    test "capture_job_arguments defaults to false" do
      config = Configuration.new

      refute config.capture_job_arguments
    end

    test "warn_on_stale_summaries defaults to true" do
      config = Configuration.new

      assert config.warn_on_stale_summaries
    end

    test "mount_dashboard defaults to true" do
      config = Configuration.new

      assert config.mount_dashboard
    end

    test "return_to_app_url defaults to the host app root and accepts nil or a non-empty string" do
      assert_equal "/", Configuration.new.return_to_app_url
      assert_nil build_config { @return_to_app_url = nil }.return_to_app_url
      assert_equal "/admin", build_config { @return_to_app_url = "/admin" }.return_to_app_url
      assert_raises(ArgumentError) { build_config { @return_to_app_url = "" } }
      assert_raises(ArgumentError) { build_config { @return_to_app_url = :root } }
    end

    test "route_thresholds has slow very_slow and critical keys" do
      config = Configuration.new

      assert_includes config.route_thresholds.keys, :slow
      assert_includes config.route_thresholds.keys, :very_slow
      assert_includes config.route_thresholds.keys, :critical
    end

    test "max_table_records has all expected table keys" do
      config = Configuration.new

      expected_tables = %i[
        rails_pulse_operations rails_pulse_requests rails_pulse_job_runs
        rails_pulse_queries rails_pulse_routes rails_pulse_jobs
        rails_pulse_exception_occurrences rails_pulse_exception_groups
        rails_pulse_deployments
      ]

      expected_tables.each do |key|
        assert_includes config.max_table_records.keys, key
      end
    end

    test "max_table_records merges configured limits with defaults" do
      config = Configuration.new

      config.max_table_records = { rails_pulse_requests: 1_000 }

      assert_equal 1_000, config.max_table_records[:rails_pulse_requests]
      assert_equal 100_000, config.max_table_records[:rails_pulse_operations]
    end

    test "max_table_records accepts nil to disable count-based cleanup" do
      config = Configuration.new

      config.max_table_records = nil

      assert_nil config.max_table_records
    end

    test "full_retention_period defaults to 30 days" do
      config = Configuration.new

      assert_equal 30.days, config.full_retention_period
    end

    test "tags defaults to an array of strings" do
      config = Configuration.new

      assert_kind_of Array, config.tags
      config.tags.each { |tag| assert_kind_of String, tag }
    end

    test "service_level_objectives defaults to empty array" do
      config = Configuration.new

      assert_empty config.service_level_objectives
    end

    # ignored_routes Tests

    test "ignored_routes merges user routes with default asset patterns when track_assets is false" do
      config = Configuration.new
      config.instance_variable_set(:@ignored_routes, [ "/custom" ])
      config.instance_variable_set(:@track_assets, false)

      routes = config.ignored_routes

      assert_includes routes, "/custom"
      # Default asset patterns include common asset file extensions
      assert routes.any? { |r| r.is_a?(Regexp) }
    end

    test "ignored_routes does not add asset patterns when track_assets is true" do
      config = Configuration.new
      config.instance_variable_set(:@ignored_routes, [ "/custom" ])
      config.instance_variable_set(:@track_assets, true)
      config.instance_variable_set(:@custom_asset_patterns, [])

      routes = config.ignored_routes

      assert_equal [ "/custom" ], routes
    end

    test "ignored_routes includes custom_asset_patterns when track_assets is false" do
      config = Configuration.new
      config.instance_variable_set(:@ignored_routes, [])
      config.instance_variable_set(:@track_assets, false)
      config.instance_variable_set(:@custom_asset_patterns, [ "/my-cdn" ])

      routes = config.ignored_routes

      assert_includes routes, "/my-cdn"
    end

    # Validation Tests

    test "validate_configuration! raises for non-positive route threshold" do
      config = Configuration.new
      config.instance_variable_set(:@route_thresholds, { slow: -1, very_slow: 1500, critical: 3000 })

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-numeric threshold" do
      config = Configuration.new
      config.instance_variable_set(:@route_thresholds, { slow: "fast", very_slow: 1500, critical: 3000 })

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for invalid pattern type" do
      config = Configuration.new
      config.instance_variable_set(:@ignored_routes, [ 42 ])

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! accepts string and regexp patterns" do
      config = Configuration.new
      config.instance_variable_set(:@ignored_routes, [ "/health", /^\/api/ ])

      assert_nothing_raised { config.validate_configuration! }
    end

    test "validate_configuration! raises for non-boolean track_jobs" do
      config = Configuration.new
      config.instance_variable_set(:@track_jobs, "yes")

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-boolean track_exceptions" do
      config = Configuration.new
      config.instance_variable_set(:@track_exceptions, "yes")

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-boolean capture_exception_params" do
      config = Configuration.new
      config.instance_variable_set(:@capture_exception_params, "yes")

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "track_exceptions defaults to false" do
      config = Configuration.new

      refute config.track_exceptions
    end

    test "capture_exception_params defaults to true" do
      config = Configuration.new

      assert config.capture_exception_params
    end

    test "validate_configuration! raises for non-array tags" do
      config = Configuration.new
      config.instance_variable_set(:@tags, "invalid")

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-string tag entries" do
      config = Configuration.new
      config.instance_variable_set(:@tags, [ :symbol_tag ])

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "default_disabled_tags defaults to an empty array" do
      assert_equal [], Configuration.new.default_disabled_tags
    end

    test "validate_configuration! accepts default_disabled_tags drawn from tags" do
      config = Configuration.new
      config.default_disabled_tags = [ "ignored" ]

      config.validate_configuration!

      assert_equal [ "ignored" ], config.default_disabled_tags
    end

    test "validate_configuration! raises for invalid default_disabled_tags" do
      [
        [ "ignored", /must be an array/ ],
        [ [ :ignored ], /only tags from config\.tags/ ],
        [ [ "non_tagged" ], /only tags from config\.tags/ ],
        [ [ "unknown" ], /only tags from config\.tags/ ]
      ].each do |value, message|
        config = Configuration.new
        config.default_disabled_tags = value

        error = assert_raises(ArgumentError) { config.validate_configuration! }
        assert_match message, error.message
      end
    end

    test "exception_message_filter defaults to nil" do
      assert_nil Configuration.new.exception_message_filter
    end

    test "validate_configuration! accepts a callable exception_message_filter" do
      config = build_config { self.exception_message_filter = ->(message, _exception) { message } }

      assert_respond_to config.exception_message_filter, :call
    end

    test "validate_configuration! raises for a non-callable exception_message_filter" do
      config = Configuration.new
      config.exception_message_filter = "not callable"

      error = assert_raises(ArgumentError) { config.validate_configuration! }
      assert_match "exception_message_filter", error.message
    end

    test "validate_configuration! raises for invalid authentication_method type" do
      config = Configuration.new
      config.instance_variable_set(:@authentication_method, 42)

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! accepts proc as authentication_method" do
      config = Configuration.new
      config.instance_variable_set(:@authentication_method, -> { true })

      assert_nothing_raised { config.validate_configuration! }
    end

    test "authorize defaults to nil" do
      assert_nil Configuration.new.authorize
    end

    test "validate_configuration! accepts a callable authorize" do
      config = build_config { self.authorize = ->(controller) { controller.present? } }

      assert_respond_to config.authorize, :call
    end

    test "standalone_authentication_method defaults to nil" do
      assert_nil Configuration.new.standalone_authentication_method
    end

    test "validate_configuration! accepts a proc standalone_authentication_method" do
      config = build_config { self.standalone_authentication_method = proc { true } }

      assert_kind_of Proc, config.standalone_authentication_method
    end

    test "validate_configuration! raises for a non-proc standalone_authentication_method" do
      config = Configuration.new
      config.standalone_authentication_method = :not_a_proc

      error = assert_raises(ArgumentError) { config.validate_configuration! }

      assert_match "standalone_authentication_method", error.message
    end

    test "schema_check_enabled defaults to true" do
      assert Configuration.new.schema_check_enabled
    end

    test "validate_configuration! raises for a non-boolean schema_check_enabled" do
      config = Configuration.new
      config.schema_check_enabled = "yes"

      error = assert_raises(ArgumentError) { config.validate_configuration! }

      assert_match "schema_check_enabled", error.message
    end

    test "validate_configuration! raises for a non-callable authorize" do
      config = Configuration.new
      config.authorize = true

      error = assert_raises(ArgumentError) { config.validate_configuration! }
      assert_match "authorize", error.message
    end

    test "validate_authentication_settings! does not warn when authorize is configured" do
      config = Configuration.new
      config.authentication_enabled = true
      config.authorize = ->(_controller) { true }

      RailsPulse.logger.expects(:warn).never

      config.validate_configuration!
    end

    test "validate_configuration! raises for SLO entry missing percentile key" do
      config = Configuration.new
      config.instance_variable_set(:@service_level_objectives, [ { threshold: 200 } ])

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for SLO percentile not 95 or 99" do
      config = Configuration.new
      config.instance_variable_set(:@service_level_objectives, [ { percentile: 50, threshold: 200 } ])

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! accepts valid SLO entries" do
      config = Configuration.new
      config.instance_variable_set(:@service_level_objectives, [
        { percentile: 95, threshold: 200 },
        { percentile: 99, threshold: 500 }
      ])

      assert_nothing_raised { config.validate_configuration! }
    end

    test "async_queue_size defaults to 1000" do
      config = Configuration.new

      assert_equal 1_000, config.async_queue_size
    end

    test "validate_configuration! raises for a non-positive async_queue_size" do
      config = Configuration.new
      config.async_queue_size = 0

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-boolean async" do
      config = Configuration.new
      config.instance_variable_set(:@async, "true")

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    test "validate_configuration! raises for non-integer max_table_records value" do
      config = Configuration.new
      config.instance_variable_set(:@max_table_records, { rails_pulse_operations: "lots" })

      assert_raises ArgumentError do
        config.validate_configuration!
      end
    end

    # Threshold Setter Validation Tests (Security Fix)

    test "route_thresholds= validates hash type" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.route_thresholds = "not a hash"
      end

      assert_match(/must be a hash/i, error.message)
    end

    test "route_thresholds= validates numeric values" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.route_thresholds = { slow: "fast", very_slow: 1500, critical: 3000 }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "route_thresholds= validates positive values" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.route_thresholds = { slow: -100, very_slow: 1500, critical: 3000 }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "route_thresholds= accepts valid thresholds" do
      config = Configuration.new

      assert_nothing_raised do
        config.route_thresholds = { slow: 500, very_slow: 1500, critical: 3000 }
      end

      assert_equal 500, config.route_thresholds[:slow]
    end

    test "request_thresholds= validates hash type" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.request_thresholds = [ 100, 200 ]
      end

      assert_match(/must be a hash/i, error.message)
    end

    test "request_thresholds= validates numeric values" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.request_thresholds = { slow: 700, very_slow: nil, critical: 4000 }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "request_thresholds= accepts valid thresholds" do
      config = Configuration.new

      assert_nothing_raised do
        config.request_thresholds = { slow: 700, very_slow: 2000, critical: 4000 }
      end

      assert_equal 2000, config.request_thresholds[:very_slow]
    end

    test "query_thresholds= validates numeric values" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.query_thresholds = { slow: 100, very_slow: "500", critical: 1000 }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "query_thresholds= accepts valid thresholds" do
      config = Configuration.new

      assert_nothing_raised do
        config.query_thresholds = { slow: 100, very_slow: 500, critical: 1000 }
      end

      assert_equal 1000, config.query_thresholds[:critical]
    end

    test "job_thresholds= validates numeric values" do
      config = Configuration.new

      error = assert_raises ArgumentError do
        config.job_thresholds = { slow: 5_000, very_slow: 30_000, critical: {} }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "job_thresholds= accepts valid thresholds" do
      config = Configuration.new

      assert_nothing_raised do
        config.job_thresholds = { slow: 5_000, very_slow: 30_000, critical: 60_000 }
      end

      assert_equal 30_000, config.job_thresholds[:very_slow]
    end

    test "threshold setters prevent SQL injection via configuration" do
      config = Configuration.new

      # Attempt to set a malicious threshold that could be used in SQL injection
      error = assert_raises ArgumentError do
        config.request_thresholds = { slow: "500; DROP TABLE users;", very_slow: 2000, critical: 4000 }
      end

      assert_match(/must be a positive number/i, error.message)
    end

    test "validate_authentication_settings! tolerates nil Rails.logger" do
      config = Configuration.new
      config.authentication_enabled = true
      config.instance_variable_set(:@authentication_method, nil)

      original_logger = Rails.logger
      Rails.logger = nil
      RailsPulse.instance_variable_set(:@logger, nil)

      begin
        out, _err = capture_io { config.validate_configuration! }

        assert_match(/no authentication method is configured/, out)
      ensure
        Rails.logger = original_logger
        RailsPulse.instance_variable_set(:@logger, nil)
      end
    end
  end
end
