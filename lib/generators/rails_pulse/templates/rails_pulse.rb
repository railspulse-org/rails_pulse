RailsPulse.configure do |config|
  # ====================================================================================================
  #                                         GLOBAL CONFIGURATION
  # ====================================================================================================

  # Enable or disable Rails Pulse
  config.enabled = true

  # Tracking writes happen on a background thread by default (see `config.async`
  # under ADVANCED). Transactional tests share one database connection across
  # threads, so write inline there to keep the writer off the test's connection.
  config.async = false if Rails.env.test?

  # ====================================================================================================
  #                                               THRESHOLDS
  # ====================================================================================================
  # These thresholds are used to determine if a route, request, or query is slow, very slow, or critical.
  # Values are in milliseconds (ms). Adjust these based on your application's performance requirements.

  # Thresholds for an individual route
  config.route_thresholds = {
    slow:      500,
    very_slow: 1500,
    critical:  3000
  }

  # Thresholds for an individual request
  config.request_thresholds = {
    slow:      700,
    very_slow: 2000,
    critical:  4000
  }

  # Thresholds for an individual database query
  config.query_thresholds = {
    slow:      100,
    very_slow: 500,
    critical:  1000
  }

  # ====================================================================================================
  #                                        SERVICE LEVEL OBJECTIVES (SLO)
  # ====================================================================================================
  # Define Service Level Objectives to visualize performance targets on the dashboard.
  # These SLOs appear as dashed threshold lines on the performance charts, color-matched
  # to their percentile series (green for P95, blue for P99).
  #
  # SLO Configuration:
  #   :percentile - Must be 95 or 99 (binds to the matching chart series)
  #   :threshold  - Maximum acceptable response time in milliseconds

  # SLO for HTTP request response times (shown on Response Time Percentiles chart)
  # config.service_level_objectives = [
  #   { percentile: 95, threshold: 200 },
  #   { percentile: 99, threshold: 500 }
  # ]

  # SLO for database query execution times (shown on Query Performance chart)
  # Query SLOs should typically be 5-10x stricter than request SLOs
  # config.query_service_level_objectives = [
  #   { percentile: 95, threshold: 50 },
  #   { percentile: 99, threshold: 100 }
  # ]

  # ====================================================================================================
  #                                               FILTERING
  # ====================================================================================================

  # Asset Tracking Configuration
  # By default, Rails Pulse ignores asset requests (images, CSS, JS files) to focus on application performance.
  # Set track_assets to true if you want to monitor asset delivery performance.
  config.track_assets = false

  # Custom asset patterns to ignore (in addition to the built-in defaults)
  # Only applies when track_assets is false. Add patterns for app-specific asset paths.
  config.custom_asset_patterns = [
    # Example: ignore specific asset directories
    # %r{^/uploads/},
    # %r{^/media/},
    # "/special-assets/"
  ]

  # Rails Pulse Mount Path (optional)
  # If Rails Pulse is mounted at a custom path, specify it here to prevent
  # Rails Pulse from tracking its own requests. Leave as nil for default '/rails_pulse'.
  # Examples:
  #   config.mount_path = "/admin/monitoring"
  config.mount_path = nil

  # Manual route filtering
  # Specify additional routes, requests, or queries to ignore from performance tracking.
  # Each array can include strings (exact matches) or regular expressions.
  #
  # Examples:
  #   config.ignored_routes   = ["/health_check", %r{^/admin}]
  #   config.ignored_requests = ["GET /status", %r{POST /api/v1/.*}]
  #   config.ignored_queries  = ["SELECT 1", %r{FROM \"schema_migrations\"}]

  config.ignored_routes   = []
  config.ignored_requests = []
  config.ignored_queries  = []

  # ====================================================================================================
  #                                                 TAGGING
  # ====================================================================================================
  # Define custom tags for categorizing routes, requests, and queries.
  # You can add any custom tags you want for filtering and organization.
  #
  # Tag names should be in present tense and describe the current state or category.
  # Examples of good tag names:
  #   - "critical" (for high-priority endpoints)
  #   - "experimental" (for routes under development)
  #   - "deprecated" (for routes being phased out)
  #   - "external" (for third-party API calls)
  #   - "background" (for async job-related operations)
  #   - "admin" (for administrative routes)
  #   - "public" (for public-facing routes)
  #
  # Example configuration:
  #   config.tags = ["ignored", "critical", "experimental", "deprecated", "external", "admin"]

  config.tags = [ "ignored", "critical", "experimental" ]

  # ====================================================================================================
  #                                          EXCEPTION TRACKING
  # ====================================================================================================
  # When enabled, Rails Pulse captures unhandled exceptions raised during web
  # requests and failed background jobs, groups them by class and location, and
  # displays them in the Exceptions tab. Rake tasks are not captured automatically —
  # call ExceptionCaptureService.capture yourself if needed.
  #
  # Capture runs synchronously on the calling thread (upsert + insert). That keeps
  # the implementation simple for v1; under an error storm it adds DB latency to
  # failing requests and jobs. Set track_exceptions = false to disable.
  #
  # The gem default is false so existing installs do not start capturing on
  # upgrade. New apps get true from this template; the upgrade generator
  # inserts false into existing initializers.
  #
  # Backtraces store the first 50 frames. Request params are filtered via Rails'
  # filter_parameters. Exception messages are filtered too: the SQL and echoed
  # values in ActiveRecord::StatementInvalid messages are stripped, and any
  # `key=value` / `key: value` fragment whose key matches filter_parameters
  # (password=…, token: …) is masked. Messages are truncated to 500 characters.

  # Enable or disable exception tracking
  config.track_exceptions = true

  # Capture request params with each exception occurrence.
  # Params are filtered using Rails' filter_parameters config (passwords, tokens, etc. are redacted).
  # Occurrences with params larger than 10KB after filtering are stored without params.
  # Set to false to disable entirely, e.g. for strict data-minimization requirements.
  config.capture_exception_params = true

  # Extra redaction for exception messages, applied after the built-in
  # filter_parameters pass. Receives the message and the exception; return the
  # message to store. If the hook raises, the message is stored as "[FILTERED]".
  # config.exception_message_filter = ->(message, exception) {
  #   message.gsub(/\b\d{13,16}\b/, "[FILTERED]")   # card-number-shaped digits
  # }

  # How many times an exception group has to fire over the dashboard period
  # before it is called out. These are occurrence counts, not durations.
  # config.exception_thresholds = {
  #   warning:  10,
  #   critical: 100
  # }

  # Capture the raw (unparameterized) SQL for each operation.
  # WARNING: mysql2 defaults to prepared_statements: false, so every literal
  # value (emails, passwords, tokens) is inlined and stored in plaintext.
  # Same applies to PostgreSQL behind PgBouncer in transaction-pool mode.
  # Default: false (upgrade-safe). New installs may opt in after review.
  # config.capture_actual_sql = true

  # ====================================================================================================
  #                                            BACKGROUND JOBS
  # ====================================================================================================
  # Configure background job monitoring and tracking.
  # When enabled, Rails Pulse will track job executions, durations, failures, and retries.
  # Supports ActiveJob, Sidekiq, and Delayed Job.

  # Enable or disable background job tracking
  config.track_jobs = false

  # Thresholds for job execution times (in milliseconds)
  config.job_thresholds = {
    slow:      5_000,   # 5 seconds
    very_slow: 30_000,  # 30 seconds
    critical:  60_000   # 1 minute
  }

  # Job classes to ignore from tracking (by class name)
  # Examples:
  #   config.ignored_jobs = ["ActionMailer::MailDeliveryJob", "MyApp::HealthCheckJob"]
  config.ignored_jobs = []

  # Queue names to ignore from tracking
  # Examples:
  #   config.ignored_queues = ["low_priority", "mailers"]
  config.ignored_queues = []

  # Capture job arguments for debugging (may contain sensitive data)
  # WARNING: job arguments may contain user credentials, PII, or API keys.
  # Default: false. Set to true only after reviewing your job argument contents.
  config.capture_job_arguments = false

  # Job tracking mode: :universal (all jobs) or :opt_in (only explicitly tracked jobs)
  # config.job_tracking_mode = :universal

  # Per-adapter settings. Disable adapters or opt into queue-depth tracking:
  # config.job_adapters = {
  #   sidekiq: { enabled: true, track_queue_depth: false },
  #   solid_queue: { enabled: true, track_recurring: false },
  #   good_job: { enabled: true, track_cron: false },
  #   delayed_job: { enabled: true },
  #   resque: { enabled: true }
  # }

  # ====================================================================================================
  #                                            DATABASE CONFIGURATION
  # ====================================================================================================
  # Configure Rails Pulse to use a separate database for performance monitoring data.
  # This is optional but recommended for production applications to isolate performance
  # data from your main application database.
  #
  # Uncomment and configure one of the following patterns:

  # Option 1: Separate single database for Rails Pulse
  # config.connects_to = {
  #   database: { writing: :rails_pulse, reading: :rails_pulse }
  # }

  # Option 2: Primary/replica configuration for Rails Pulse
  # config.connects_to = {
  #   database: { writing: :rails_pulse_primary, reading: :rails_pulse_replica }
  # }

  # Don't forget to add the database configuration to config/database.yml:
  #
  # production:
  #   # ... your main database config ...
  #   rails_pulse:
  #     adapter: postgresql  # or mysql2, sqlite3
  #     database: myapp_rails_pulse_production
  #     username: rails_pulse_user
  #     password: <%= Rails.application.credentials.dig(:rails_pulse, :database_password) %>
  #     host: localhost
  #     pool: 5
  #     migrations_paths: db/rails_pulse_migrate
  #     schema_dump: false

  # ====================================================================================================
  #                                            AUTHENTICATION
  # ====================================================================================================
  # Configure authentication to secure access to the Rails Pulse dashboard.
  # Authentication is ENABLED BY DEFAULT outside development and test.
  #
  # If nothing below is configured, Rails Pulse will use HTTP Basic Auth
  # with credentials from RAILS_PULSE_USERNAME (default: 'admin') and RAILS_PULSE_PASSWORD
  # environment variables. Set RAILS_PULSE_PASSWORD to enable this fallback.

  # Enable/disable authentication (enabled by default outside development/test)
  # config.authentication_enabled = !Rails.env.local?

  # Where to redirect users when an authentication hook raises
  # config.authentication_redirect_path = "/"

  # RECOMMENDED: a fail-closed predicate. Receives the controller; return
  # true to allow. Anything else (false, nil, no user) is a 403 Forbidden.
  # config.authorize = ->(controller) { controller.current_user&.admin? }
  #
  # A zero-argument proc runs in the controller's context instead:
  # config.authorize = proc { user_signed_in? && current_user.admin? }

  # Alternatively, a hook that runs in the controller and DENIES BY RENDERING
  # OR REDIRECTING. Returning false without responding is also a denial;
  # returning nil (what `unless … end` returns on success) allows the request.
  # Do not write predicate-style checks here — use config.authorize for those.
  # If both are set, authentication_method runs first, then authorize.

  # Example 1: Devise with admin role check
  # config.authentication_method = proc {
  #   unless user_signed_in? && current_user.admin?
  #     redirect_to main_app.root_path, alert: "Access denied"
  #   end
  # }

  # Example 2: Custom session-based authentication
  # config.authentication_method = proc {
  #   unless session[:user_id] && User.find_by(id: session[:user_id])&.admin?
  #     redirect_to main_app.login_path, alert: "Please log in as an admin"
  #   end
  # }

  # Example 3: Warden authentication
  # config.authentication_method = proc {
  #   warden.authenticate!(:scope => :admin)
  # }

  # Example 4: Basic HTTP authentication
  # config.authentication_method = proc {
  #   authenticate_or_request_with_http_basic do |username, password|
  #     ActiveSupport::SecurityUtils.secure_compare(username, ENV['RAILS_PULSE_USERNAME']) &&
  #       ActiveSupport::SecurityUtils.secure_compare(password, ENV['RAILS_PULSE_PASSWORD'])
  #   end
  # }

  # Example 5: Custom authorization check
  # config.authentication_method = proc {
  #   current_user = User.find_by(id: session[:user_id])
  #   unless current_user&.can_access_rails_pulse?
  #     render plain: "Forbidden", status: :forbidden
  #   end
  # }

  # STANDALONE DASHBOARD (bin/rails_pulse_server, see docs/deployment-modes.md):
  # that process has your models but not your app's session, Warden or Devise
  # helpers, and runs on its own hostname, so the hooks above are ignored there.
  # By default it uses HTTP Basic auth (RAILS_PULSE_USERNAME / RAILS_PULSE_PASSWORD).
  # Set this to run something else instead; same rules as authentication_method
  # (deny by rendering or redirecting, or by returning false).
  # config.standalone_authentication_method = proc {
  #   authenticate_or_request_with_http_token do |token, _options|
  #     ActiveSupport::SecurityUtils.secure_compare(token, ENV["RAILS_PULSE_DASHBOARD_TOKEN"].to_s)
  #   end
  # }

  # ====================================================================================================
  #                                             DEPLOYMENT TRACKING
  # ====================================================================================================
  # Record deployments to display vertical marker lines on performance charts, making it easy
  # to correlate performance changes with specific releases.
  #
  # API token for the POST /rails_pulse/deployments endpoint.
  # When set, requests must include an `X-Rails-Pulse-Token` header matching this value.
  # When nil, the endpoint falls back to the standard dashboard authentication.
  #
  # Set this in your CI/CD pipeline and store the value in credentials or an environment variable:
  #   config.deployment_api_token = Rails.application.credentials.dig(:rails_pulse, :deployment_api_token)
  #   config.deployment_api_token = ENV["RAILS_PULSE_DEPLOYMENT_TOKEN"]
  #
  # Limits: revision ≤ 255 characters, metadata ≤ 4 KB serialized, started_at at most
  # one hour in the future. Rows beyond max_table_records[:rails_pulse_deployments]
  # are pruned oldest-first by the cleanup task.
  #
  # Record a deployment from your CI/CD pipeline:
  #   curl -X POST https://yourapp.com/rails_pulse/deployments \
  #     -H "X-Rails-Pulse-Token: $RAILS_PULSE_DEPLOYMENT_TOKEN" \
  #     -H "Content-Type: application/json" \
  #     -d '{"deployment": {"revision": "abc1234", "metadata": {"environment": "production"}}}'
  #
  # Or use the rake tasks for shell-based deploys (no token or HTTP access needed):
  #   rake rails_pulse:record_deployment[abc1234]
  #   rake rails_pulse:finish_deployment[abc1234]
  # Metadata for the rake task comes from an environment variable, as a JSON object:
  #   RAILS_PULSE_DEPLOYMENT_METADATA='{"environment":"production"}' rake rails_pulse:record_deployment[abc1234]

  # config.deployment_api_token = ENV["RAILS_PULSE_DEPLOYMENT_TOKEN"]

  # ====================================================================================================
  #                                               DATA CLEANUP
  # ====================================================================================================
  # Configure automatic cleanup of old performance data to manage database size.
  # Rails Pulse provides two cleanup mechanisms that work together:
  #
  # 1. Time-based cleanup: Delete records older than the retention period
  # 2. Count-based cleanup: Keep only the specified number of records per table
  #
  # Cleanup order respects foreign key constraints:
  # operations → requests → queries/routes

  # Enable or disable automatic data cleanup
  config.archiving_enabled = true

  # Time-based retention - delete records older than this period
  config.full_retention_period = 30.days

  # Count-based retention - maximum records to keep per table
  # After time-based cleanup, if tables still exceed these limits,
  # the oldest remaining records will be deleted to stay under the limit
  config.max_table_records = {
    rails_pulse_requests: 50_000,                 # HTTP requests (moderate volume)
    rails_pulse_operations: 100_000,              # Operations within requests (high volume)
    rails_pulse_routes: 1_000,                    # Unique routes (low volume)
    rails_pulse_queries: 10_000,                  # Normalized SQL queries (low volume)
    rails_pulse_job_runs: 50_000,                 # Individual job executions (high volume)
    rails_pulse_jobs: 1_000,                      # Unique job classes (low volume)
    rails_pulse_exception_occurrences: 50_000,    # Individual exception raises (high volume)
    rails_pulse_exception_groups: 10_000,         # Distinct exception sites (moderate volume)
    rails_pulse_deployments: 1_000                # Deploy markers (low volume; oldest pruned first)
  }

  # ====================================================================================================
  #                                       HISTORICAL COMPARISON
  # ====================================================================================================

  # Rails Pulse compares recent behaviour against a route, query or job's own
  # history to answer "what changed?" rather than only "what is slow?".
  #
  # The baseline is the traffic-weighted metric across `baseline_window` of day
  # summaries; `comparison_window` is the recent slice measured against it. The
  # two never overlap.
  # config.baseline_window   = 28.days
  # config.comparison_window = 1.day

  # Hourly summaries decide how precisely a change point can be placed. They are
  # pruned at this age because the 1-day view is otherwise the only thing that
  # reads them. Inside this window Rails Pulse can say a route slowed down at
  # 14:00; beyond it, the finest answer is the day. Raising this buys precision
  # at the cost of summary table growth.
  # config.hourly_summary_retention = 2.days

  # A change is reported as a regression only when it clears both the ratio and
  # the absolute floor for its unit. The ratio alone flags trivial millisecond
  # noise on fast endpoints; the floor alone flags slow endpoints that never
  # actually changed. min_samples keeps low-traffic subjects quiet.
  # config.regression_thresholds = {
  #   ratio:                1.5,   # 50% worse than baseline
  #   min_delta_ms:         50.0,  # ...and at least 50ms worse
  #   min_delta_rate:       1.0,   # ...or 1 percentage point, for error rates
  #   min_samples:          100,   # minimum observations on each side
  #   min_baseline_periods: 3      # minimum days of history before comparing
  # }

  # ====================================================================================================
  #                                               ADVANCED
  # ====================================================================================================

  # Use a custom logger (default: Rails.logger)
  # config.logger = Logger.new("log/rails_pulse.log")

  # Perform tracking writes in a background thread (default: true).
  # When false, writes happen inline before the response is sent.
  # config.async = true

  # Show a dashboard banner when summary data is stale (default: true)
  # config.warn_on_stale_summaries = true

  # When this gem version is newer than the Rails Pulse tables it is connected
  # to (deployed before `db:migrate`, or a rolling restart), pause tracking after
  # one logged warning and answer every dashboard page with a 503 that lists the
  # upgrade commands, instead of erroring on each request (default: true).
  # config.schema_check_enabled = true

  # Set to false to skip dashboard middleware and asset serving entirely.
  # Useful for standalone/API-only deployments that use a separate dashboard app.
  # config.mount_dashboard = true
end
