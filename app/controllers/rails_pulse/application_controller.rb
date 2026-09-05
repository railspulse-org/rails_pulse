module RailsPulse
  class ApplicationController < ActionController::Base
    include PaginationConcern
    include SessionFiltersConcern
    include RansackParamsConcern

    # Declared here rather than inherited. ActionController::Base only gets
    # protect_from_forgery from the host's `default_protect_from_forgery`,
    # which load_defaults 5.2+ turns on — a host still on an older
    # load_defaults (or one that set the flag false and calls
    # protect_from_forgery in its own ApplicationController) would leave every
    # state-changing engine endpoint forgeable. Idempotent when the host
    # already has it; the deployments API and assets controller keep their
    # explicit skips.
    protect_from_forgery with: :exception

    before_action :authenticate_rails_pulse_user!
    before_action :require_current_schema!
    before_action :set_onboarding_state
    before_action :load_deployment_markers

    # Values accepted into the cookie session. Everything else is dropped:
    # the session has a 4 KB ceiling and a stored value is re-parsed on every
    # later request, so an unbounded or unparseable string would 500 the
    # dashboard until the cookie is cleared.
    TIME_RANGE_PRESETS = %w[last_24_hours last_7_days last_14_days last_30_days].freeze
    PERFORMANCE_THRESHOLDS = %w[slow very_slow critical].freeze
    MAX_TIME_PARAM_LENGTH = 64

    def set_global_filters
      if params[:clear] == "true"
        session.delete(:global_filters)
        session[:show_non_tagged] = true  # Reset show_non_tagged to default
      else
        filters = session[:global_filters] || {}

        # Update time filters if provided
        start_time = valid_time_param(params[:start_time])
        end_time = valid_time_param(params[:end_time])
        if start_time && end_time
          filters["start_time"] = start_time
          filters["end_time"] = end_time
        end

        # Update performance threshold if provided (or remove if empty/unknown)
        threshold = params[:performance_threshold].to_s
        if PERFORMANCE_THRESHOLDS.include?(threshold)
          filters["performance_threshold"] = threshold
        else
          filters.delete("performance_threshold")
        end

        # Update tag visibility - convert enabled tags to disabled tags
        all_tags = RailsPulse.configuration.tags
        enabled_tags = Array(params[:enabled_tags]).map(&:to_s)

        # Handle "non_tagged" separately
        session[:show_non_tagged] = enabled_tags.include?("non_tagged")
        enabled_tags = enabled_tags - [ "non_tagged" ]

        disabled_tags = all_tags - enabled_tags

        if disabled_tags.any?
          filters["disabled_tags"] = disabled_tags
        else
          filters.delete("disabled_tags")
        end

        # Update deployment markers visibility (absent checkbox param = unchecked = false)
        filters["show_deployment_markers"] = params[:show_deployment_markers] == "1"

        session[:global_filters] = filters
      end

      # Redirect back to the referring page or root
      redirect_back(fallback_location: root_path, allow_other_host: false)
    end

    def set_time_range
      preset = params[:preset].to_s
      start_time = valid_time_param(params[:start_time])
      end_time = valid_time_param(params[:end_time])

      if preset.present?
        # Store preset selection
        session[:time_range_preference] = preset if TIME_RANGE_PRESETS.include?(preset)
      elsif start_time && end_time
        # Store custom range
        session[:time_range_preference] = {
          type: "custom",
          start_time: start_time,
          end_time: end_time
        }
      end

      # Redirect back to the referring page or root
      redirect_back(fallback_location: root_path, allow_other_host: false)
    end

    private

    # The original string if it is short enough to live in the session and
    # Time.parse accepts it (TimeRangeConcern parses it back the same way);
    # nil otherwise.
    def valid_time_param(value)
      value = value.to_s.strip
      return nil if value.blank? || value.length > MAX_TIME_PARAM_LENGTH

      Time.parse(value)
      value
    rescue ArgumentError, TypeError
      nil
    end

    def partial_request?
      request.headers["X-Partial-Request"] == "true"
    end

    def logger
      RailsPulse.logger
    end

    # Two hooks, run in order:
    #
    # * `authentication_method` — the legacy hook. It denies by rendering or
    #   redirecting (the documented `unless signed_in? then redirect_to`
    #   style). Returning literal `false` without responding is also a
    #   denial; returning nil (which `unless … end` does on success) allows.
    # * `authorize` — a fail-closed predicate. Anything falsy is a 403.
    #
    # With neither configured, HTTP Basic against RAILS_PULSE_PASSWORD.
    def authenticate_rails_pulse_user!
      config = RailsPulse.configuration
      return unless config.authentication_enabled

      return authenticate_standalone!(config) if RailsPulse.standalone?

      if config.authentication_method.nil? && config.authorize.nil?
        return fallback_http_basic_auth
      end

      unless config.authentication_method.nil?
        run_authentication_method(config.authentication_method)
        return if performed?
      end

      run_authorize_predicate(config.authorize) if config.authorize
    rescue StandardError => e
      logger.warn "RailsPulse authentication failed: #{e.message}"
      # The redirect target is a host app page; from the standalone server
      # it would point at a route this process does not serve.
      if RailsPulse.standalone?
        render plain: "Forbidden", status: :forbidden
      else
        redirect_to config.authentication_redirect_path
      end
    end

    # The standalone server has the host's models but not its middleware:
    # no host session store, Warden, or Devise helpers, and a different
    # hostname so no shared cookie. A session-based `authentication_method`
    # or `authorize` would raise (rescued above into a useless redirect) or,
    # worse, be written so that it silently allows. Ignore both here; use
    # `standalone_authentication_method` when set, else HTTP Basic.
    def authenticate_standalone!(config)
      hook = config.standalone_authentication_method
      if hook.nil?
        note_ignored_host_authentication(config)
        return fallback_http_basic_auth
      end

      run_authentication_method(hook)
    end

    def note_ignored_host_authentication(config)
      return if config.authentication_method.nil? && config.authorize.nil?
      return if self.class.instance_variable_get(:@_rails_pulse_standalone_auth_noted)

      self.class.instance_variable_set(:@_rails_pulse_standalone_auth_noted, true)
      logger.info "RailsPulse: standalone dashboard ignores config.authentication_method / config.authorize " \
                  "(host session helpers are not available here); using HTTP Basic auth. " \
                  "Set config.standalone_authentication_method to customise."
    end

    def run_authentication_method(hook)
      result = case hook
      when Proc
        instance_exec(&hook)
      when Symbol, String
        method_name = hook.to_s
        unless respond_to?(method_name, true)
          logger.error "RailsPulse: Authentication method '#{method_name}' not found"
          return render plain: "Authentication configuration error", status: :internal_server_error
        end
        send(method_name)
      else
        logger.error "RailsPulse: Invalid authentication method type: #{hook.class}"
        return render plain: "Authentication configuration error", status: :internal_server_error
      end

      return if performed?
      return unless result == false

      # `proc { current_user&.admin? }` reads as a predicate but never halts
      # the chain. Treat an explicit false as the denial it was meant to be.
      logger.warn "RailsPulse: authentication_method returned false without rendering or redirecting; " \
                  "denying access. Use config.authorize for predicate-style checks."
      render plain: "Forbidden", status: :forbidden
    end

    def run_authorize_predicate(predicate)
      allowed = predicate.arity.zero? ? instance_exec(&predicate) : predicate.call(self)
      return if allowed

      render plain: "Forbidden", status: :forbidden
    end

    def fallback_http_basic_auth
      authenticate_or_request_with_http_basic("Rails Pulse") do |username, password|
        # Use environment variables for default credentials
        expected_username = ENV.fetch("RAILS_PULSE_USERNAME", "admin")
        expected_password = ENV.fetch("RAILS_PULSE_PASSWORD", nil)

        if expected_password.nil?
          logger.error "RailsPulse: No authentication method configured and RAILS_PULSE_PASSWORD not set. Access denied."
          false
        else
          ActiveSupport::SecurityUtils.secure_compare(username.to_s, expected_username) &&
            ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
        end
      end
    end

    # New gem code against un-migrated tables would otherwise 500 on every
    # page that touches a missing column. Runs after authentication so the
    # schema report is not exposed to anonymous callers.
    def require_current_schema!
      return if RailsPulse::SchemaCheck.current?

      RailsPulse::SchemaCheck.warn_once!
      missing = RailsPulse::SchemaCheck.missing

      respond_to do |format|
        format.html do
          render template: "rails_pulse/shared/schema_outdated", layout: false,
                 status: :service_unavailable, locals: { missing: missing }
        end
        format.any do
          render json: {
            error: "Rails Pulse #{RailsPulse::VERSION} requires a schema upgrade",
            missing: missing,
            instructions: RailsPulse::SchemaCheck::UPGRADE_INSTRUCTIONS
          }, status: :service_unavailable
        end
      end
    end

    def load_deployment_markers
      @deployment_markers = []
      @show_deployment_markers = session_show_deployment_markers
    end

    def set_onboarding_state
      @has_requests = RailsPulse::Request.exists?
      last_summary_at = RailsPulse::Summary.maximum(:updated_at)
      @has_summaries = last_summary_at.present?
      @summaries_stale = RailsPulse.configuration.warn_on_stale_summaries && @has_summaries && last_summary_at < 2.hours.ago
      @route_backfill_pending = RailsPulse::Route.needs_action_backfill?
    end
  end
end
