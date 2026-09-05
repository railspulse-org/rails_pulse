module RailsPulse
  class Configuration
    attr_writer   :ignored_routes
    attr_accessor :enabled,
                  :deployment_api_token,
                  :ignored_requests,
                  :ignored_queries,
                  :ignored_jobs,
                  :ignored_queues,
                  :track_assets,
                  :track_jobs,
                  :track_exceptions,
                  :capture_exception_params,
                  :exception_message_filter,
                  :capture_actual_sql,
                  :custom_asset_patterns,
                  :mount_path,
                  :full_retention_period,
                  :archiving_enabled,
                  :connects_to,
                  :authentication_enabled,
                  :authentication_method,
                  :authorize,
                  :standalone_authentication_method,
                  :authentication_redirect_path,
                  :tags,
                  :job_tracking_mode,
                  :job_adapters,
                  :capture_job_arguments,
                  :mount_dashboard,
                  :logger,
                  :async,
                  :service_level_objectives,
                  :query_service_level_objectives,
                  :warn_on_stale_summaries,
                  :schema_check_enabled,
                  :baseline_window,
                  :comparison_window,
                  :hourly_summary_retention

    # Override the attr_accessor setter to track explicit assignment.
    # The default (enabled in production) should not trigger a warning
    # when no authentication_method is configured — only an explicit
    # opt-in without a method should warn.
    def authentication_enabled=(value)
      @authentication_enabled_explicitly_set = true
      @authentication_enabled = value
    end

    # Read-only access to thresholds (use setters for validation)
    attr_reader :route_thresholds,
                :request_thresholds,
                :query_thresholds,
                :job_thresholds,
                :exception_thresholds,
                :max_table_records,
                :regression_thresholds

    def initialize
      @enabled = true
      @route_thresholds = { slow: 500, very_slow: 1500, critical: 3000 }
      @request_thresholds = { slow: 700, very_slow: 2000, critical: 4000 }
      @query_thresholds = { slow: 100, very_slow: 500, critical: 1000 }
      @job_thresholds = { slow: 5_000, very_slow: 30_000, critical: 60_000 }
      # Exception thresholds are occurrence counts over the dashboard period,
      # not durations — an exception has no duration.
      @exception_thresholds = { warning: 10, critical: 100 }
      @ignored_routes = []
      @ignored_requests = []
      @ignored_queries = []
      @ignored_jobs = []
      @ignored_queues = []
      @track_assets = false
      @track_jobs = false
      # Off unless the host initializer opts in. The install template sets true
      # for new apps; existing 0.3.3 initializers omit this key, so a true
      # default would start capturing exception messages (unfiltered) on upgrade.
      @track_exceptions = false
      @capture_exception_params = true
      # Optional host hook applied to every captured exception message after
      # the built-in filter_parameters redaction. nil means no extra filtering.
      @exception_message_filter = nil
      # Off by default — actual_sql contains unparameterized SQL on mysql2
      # (prepared_statements: false) and PG behind PgBouncer transaction mode.
      # Inline literals (emails, passwords) would be stored in plaintext.
      @capture_actual_sql = false
      @custom_asset_patterns = []
      @mount_path = nil
      @full_retention_period = 30.days
      @archiving_enabled = true
      @max_table_records = {
        rails_pulse_operations: 100_000,
        rails_pulse_requests: 50_000,
        rails_pulse_job_runs: 50_000,
        rails_pulse_queries: 10_000,
        rails_pulse_routes: 1_000,
        rails_pulse_jobs: 1_000,
        rails_pulse_exception_occurrences: 50_000,
        rails_pulse_exception_groups: 10_000,
        rails_pulse_deployments: 1_000
      }
      @connects_to = nil
      @authentication_enabled = !(Rails.env.development? || Rails.env.test?)
      @authentication_enabled_explicitly_set = false
      @authentication_method = nil
      # Fail-closed predicate: ->(controller) { true to allow }. Anything
      # falsy is a 403. Runs after authentication_method, if both are set.
      @authorize = nil
      # Used instead of authentication_method / authorize by the standalone
      # dashboard server, where host session helpers are unavailable. nil
      # means HTTP Basic against RAILS_PULSE_USERNAME / RAILS_PULSE_PASSWORD.
      @standalone_authentication_method = nil
      @authentication_redirect_path = "/"
      @tags = [ "ignored", "critical", "experimental" ]
      @job_tracking_mode = :universal
      @job_adapters = {
        sidekiq: { enabled: true, track_queue_depth: false },
        solid_queue: { enabled: true, track_recurring: false },
        good_job: { enabled: true, track_cron: false },
        delayed_job: { enabled: true },
        resque: { enabled: true }
      }
      @capture_job_arguments = false

      # Dashboard settings
      @mount_dashboard = true
      @logger = nil

      # Tracking mode settings
      @async = true

      # Service Level Objectives (default: [] = no SLOs configured)
      @service_level_objectives = []
      @query_service_level_objectives = []

      # Show a warning banner when summaries haven't been generated recently
      @warn_on_stale_summaries = true

      # Pause tracking and gate the dashboard when the tables are behind this
      # gem version (see RailsPulse::SchemaCheck). Off only as an escape hatch.
      @schema_check_enabled = true

      # Historical comparison. The baseline is the traffic-weighted metric across
      # `baseline_window` of day summaries; `comparison_window` is the recent
      # slice measured against it.
      @baseline_window   = 28.days
      @comparison_window = 1.day

      # Hourly summaries are what give a change point its precision. They are
      # pruned aggressively because the 1-day UI view is all that reads them, so
      # raising this is the knob that buys hour-accurate change points further
      # back, at the cost of summary-table growth.
      @hourly_summary_retention = 2.days

      # Deterministic regression rules. A change must clear both the ratio and
      # the absolute floor: without the floor, 2ms to 4ms reports as a 100%
      # regression. min_samples keeps low-traffic routes from generating noise.
      @regression_thresholds = {
        ratio:                1.5,
        min_delta_ms:         50.0,
        min_delta_rate:       1.0,
        min_samples:          100,
        min_baseline_periods: 3
      }

      # Validate defaults eagerly so that a misconfigured initializer raises at
      # boot time rather than at the first request. Auth settings are not
      # validated against defaults — only when the user explicitly enables
      # authentication without configuring a method.
      validate_configuration!
    end

    # Custom setters for thresholds with validation to prevent SQL injection
    # via configuration values interpolated into queries
    def route_thresholds=(value)
      validate_threshold_hash!(value, "route_thresholds")
      @route_thresholds = value
    end

    def request_thresholds=(value)
      validate_threshold_hash!(value, "request_thresholds")
      @request_thresholds = value
    end

    def query_thresholds=(value)
      validate_threshold_hash!(value, "query_thresholds")
      @query_thresholds = value
    end

    def job_thresholds=(value)
      validate_threshold_hash!(value, "job_thresholds")
      @job_thresholds = value
    end

    # Merge user-supplied caps into the defaults so tables added in newer
    # versions still have a cap when the user carries an older explicit hash.
    # A nil value explicitly disables count-based cleanup.
    def max_table_records=(value)
      return @max_table_records = nil if value.nil?

      @max_table_records = (@max_table_records || {}).merge(value)
    end

    # Get all routes to ignore, including asset patterns if track_assets is false
    def ignored_routes
      routes = @ignored_routes.dup

      unless @track_assets
        routes.concat(default_asset_patterns)
        routes.concat(@custom_asset_patterns)
      end

      routes
    end

    # Validate configuration settings
    def validate_configuration!
      validate_thresholds!
      validate_retention_settings!
      validate_patterns!
      validate_database_settings!
      validate_authentication_settings!
      validate_tags!
      validate_job_settings!
      validate_dashboard_settings!
      validate_tracking_settings!
      validate_exception_settings!
      validate_service_level_objectives_settings!
      validate_query_service_level_objectives_settings!
      validate_comparison_settings!
      validate_schema_check_settings!
    end

    private

    def validate_threshold_hash!(thresholds, name)
      unless thresholds.is_a?(Hash)
        raise ArgumentError, "#{name} must be a hash, got #{thresholds.class}"
      end

      thresholds.each do |key, value|
        unless value.is_a?(Numeric) && value > 0
          raise ArgumentError, "#{name}[:#{key}] must be a positive number, got #{value.inspect}"
        end
      end
    end

    def validate_thresholds!
      validate_threshold_hash!(@route_thresholds, "route_thresholds")
      validate_threshold_hash!(@request_thresholds, "request_thresholds")
      validate_threshold_hash!(@query_thresholds, "query_thresholds")
      validate_threshold_hash!(@job_thresholds, "job_thresholds")
      validate_threshold_hash!(@exception_thresholds, "exception_thresholds")
    end

    def validate_retention_settings!
      unless @full_retention_period.respond_to?(:seconds)
        raise ArgumentError, "full_retention_period must be a time duration (e.g., 2.weeks), got #{@full_retention_period}"
      end

      @max_table_records.each do |table, count|
        unless count.is_a?(Integer) && count > 0
          raise ArgumentError, "max_table_records[#{table}] must be a positive integer, got #{count}"
        end
      end
    end

    def validate_comparison_settings!
      {
        baseline_window:          @baseline_window,
        comparison_window:        @comparison_window,
        hourly_summary_retention: @hourly_summary_retention
      }.each do |name, value|
        unless value.respond_to?(:seconds) && value.to_i > 0
          raise ArgumentError, "#{name} must be a positive time duration (e.g., 7.days), got #{value.inspect}"
        end
      end

      if @baseline_window.to_i <= @comparison_window.to_i
        raise ArgumentError,
          "baseline_window (#{@baseline_window.inspect}) must be longer than " \
          "comparison_window (#{@comparison_window.inspect})"
      end

      unless @regression_thresholds.is_a?(Hash)
        raise ArgumentError, "regression_thresholds must be a hash, got #{@regression_thresholds.class}"
      end

      %i[ratio min_delta_ms min_delta_rate min_samples min_baseline_periods].each do |key|
        value = @regression_thresholds[key]
        unless value.is_a?(Numeric) && value > 0
          raise ArgumentError, "regression_thresholds[:#{key}] must be a positive number, got #{value.inspect}"
        end
      end

      if @regression_thresholds[:ratio] <= 1
        raise ArgumentError,
          "regression_thresholds[:ratio] must be greater than 1 — it is a multiple of the baseline, " \
          "got #{@regression_thresholds[:ratio].inspect}"
      end
    end

    def validate_patterns!
      [ @ignored_routes, @ignored_requests, @ignored_queries, @custom_asset_patterns ].each do |patterns|
        patterns.each do |pattern|
          unless pattern.is_a?(String) || pattern.is_a?(Regexp)
            raise ArgumentError, "Ignored patterns must be strings or regular expressions, got #{pattern.class}"
          end

          # Test regex patterns to ensure they're valid
          if pattern.is_a?(Regexp)
            begin
              "test" =~ pattern
            rescue RegexpError => e
              raise ArgumentError, "Invalid regular expression pattern: #{e.message}"
            end
          end
        end
      end
    end

    def validate_database_settings!
      if @connects_to && !@connects_to.is_a?(Hash)
        raise ArgumentError, "connects_to must be a hash with database connection configuration"
      end
    end

    def validate_authentication_settings!
      if @authentication_enabled && @authentication_enabled_explicitly_set && @authentication_method.nil? && @authorize.nil?
        RailsPulse.logger.warn "Authentication is enabled but no authentication method is configured. This will deny all access."
      end

      if @authentication_method && ![ Proc, Symbol, String ].include?(@authentication_method.class)
        raise ArgumentError, "authentication_method must be a Proc, Symbol, String, or nil, got #{@authentication_method.class}"
      end

      if @authorize && !@authorize.respond_to?(:call)
        raise ArgumentError, "authorize must respond to #call (a proc or lambda receiving the controller and returning true to allow), got #{@authorize.class}"
      end

      if @standalone_authentication_method && !@standalone_authentication_method.is_a?(Proc)
        raise ArgumentError, "standalone_authentication_method must be a Proc or nil, got #{@standalone_authentication_method.class}"
      end
    end

    def validate_schema_check_settings!
      return if [ true, false ].include?(@schema_check_enabled)

      raise ArgumentError, "schema_check_enabled must be true or false, got #{@schema_check_enabled.inspect}"
    end

    def validate_tags!
      unless @tags.is_a?(Array)
        raise ArgumentError, "tags must be an array, got #{@tags.class}"
      end

      @tags.each do |tag|
        unless tag.is_a?(String)
          raise ArgumentError, "tags must be strings, got #{tag.class}"
        end
      end
    end

    def validate_job_settings!
      unless @ignored_jobs.is_a?(Array) && @ignored_queues.is_a?(Array)
        raise ArgumentError, "ignored_jobs and ignored_queues must be arrays"
      end

      unless [ true, false ].include?(@track_jobs)
        raise ArgumentError, "track_jobs must be a boolean"
      end

      unless @job_adapters.is_a?(Hash)
        raise ArgumentError, "job_adapters must be a hash"
      end

      unless @job_thresholds.is_a?(Hash)
        raise ArgumentError, "job_thresholds must be a hash"
      end

      unless @job_tracking_mode.is_a?(Symbol)
        raise ArgumentError, "job_tracking_mode must be a symbol"
      end

      unless [ true, false ].include?(@capture_job_arguments)
        raise ArgumentError, "capture_job_arguments must be a boolean"
      end
    end

    def validate_dashboard_settings!
      unless [ true, false ].include?(@mount_dashboard)
        raise ArgumentError, "mount_dashboard must be true or false, got #{@mount_dashboard}"
      end
    end

    def validate_tracking_settings!
      unless [ true, false ].include?(@async)
        raise ArgumentError, "async must be true or false, got #{@async}"
      end
    end

    def validate_exception_settings!
      unless [ true, false ].include?(@track_exceptions)
        raise ArgumentError, "track_exceptions must be a boolean"
      end

      unless [ true, false ].include?(@capture_exception_params)
        raise ArgumentError, "capture_exception_params must be a boolean"
      end

      if @exception_message_filter && !@exception_message_filter.respond_to?(:call)
        raise ArgumentError, "exception_message_filter must respond to #call (a proc or lambda taking the message and the exception), got #{@exception_message_filter.class}"
      end
    end

    def validate_service_level_objectives_settings!
      unless @service_level_objectives.is_a?(Array)
        raise ArgumentError, "service_level_objectives must be an array, got #{@service_level_objectives.class}"
      end

      @service_level_objectives.each do |slo|
        validate_slo_entry!(slo, "service_level_objectives")
      end
    end

    def validate_query_service_level_objectives_settings!
      unless @query_service_level_objectives.is_a?(Array)
        raise ArgumentError, "query_service_level_objectives must be an array, got #{@query_service_level_objectives.class}"
      end

      @query_service_level_objectives.each do |slo|
        validate_slo_entry!(slo, "query_service_level_objectives")
      end
    end

    def validate_slo_entry!(slo, config_name)
      unless slo.is_a?(Hash)
        raise ArgumentError, "#{config_name} entries must be hashes with :percentile and :threshold keys, got #{slo.class}"
      end

      unless slo.key?(:percentile) && slo.key?(:threshold)
        raise ArgumentError, "#{config_name} entries must contain both :percentile and :threshold keys"
      end

      percentile = slo[:percentile]
      threshold = slo[:threshold]

      unless [ 95, 99 ].include?(percentile)
        raise ArgumentError, "#{config_name} entry :percentile must be 95 or 99, got #{percentile}"
      end

      unless threshold.is_a?(Numeric) && threshold > 0
        raise ArgumentError, "#{config_name} entry :threshold must be a positive number, got #{threshold}"
      end
    end

    # Default patterns for common asset types and paths
    def default_asset_patterns
      [
        # Asset file extensions
        %r{\.(png|jpg|jpeg|gif|svg|css|js|ico|woff|woff2|ttf|eot|map)$}i,

        # Common Rails asset paths
        %r{^/assets/},
        %r{^/packs/},
        %r{^/.*?/assets/},  # Catches /connect/assets/, /admin/assets/, etc.

        # Webpack dev server
        %r{^/__webpack_hmr},
        %r{^/sockjs-node/},

        # Common health check endpoints
        "/health",
        "/health_check",
        "/status",
        "/ping",

        # Favicon requests
        "/favicon.ico",
        "/apple-touch-icon.png",
        "/apple-touch-icon-precomposed.png",

        # Robots and sitemaps
        "/robots.txt",
        "/sitemap.xml"
      ]
    end
  end
end
