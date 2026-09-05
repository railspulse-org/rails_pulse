require "test_helper"

module RailsPulse
  class ConfigurationTest < ActiveSupport::TestCase
    def build_config(&block)
      config = Configuration.new
      config.instance_eval(&block) if block
      config.validate_configuration!
      config
    end

    # Default Values Tests

    test "enabled defaults to true" do
      config = Configuration.new

      assert config.enabled
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
