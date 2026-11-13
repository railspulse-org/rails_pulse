module RailsPulse
  module Middleware
    class RequestCollector
      def initialize(app)
        @app = app
      end

      def call(env)
        # Skip if Rails Pulse is disabled, or on a central, which records what
        # its applications send and tracks nothing of its own
        return @app.call(env) if !RailsPulse.configuration.enabled || RailsPulse::Central.enabled?

        # Skip logging if we are already recording RailsPulse activity. This is to avoid recursion issues
        return @app.call(env) if RailsPulse::Current.skip_recording_rails_pulse_activity

        req = ActionDispatch::Request.new(env)

        # Skip RailsPulse engine requests
        mount_path = RailsPulse.configuration.mount_path || "/rails_pulse"
        if req.path.start_with?(mount_path)
          return with_recording_suppressed { @app.call(env) }
        end

        # Check if route should be ignored based on configuration
        if should_ignore_route?(req)
          return with_recording_suppressed { @app.call(env) }
        end

        # Clear any previous request data and set a placeholder ID
        RailsPulse::Current.rails_pulse_request_id = SecureRandom.uuid
        RailsPulse::Current.rails_pulse_operations = []

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        occurred_at = Time.current

        begin
          status, headers, response = @app.call(env)
        rescue Exception => exception # rubocop:disable Lint/RescueException
          # This middleware sits inside ShowExceptions, so an unhandled
          # exception passes through here before anything renders it. Record
          # the request with the status the error page will send, then let
          # the exception continue to the host's error handling unchanged.
          track(req, env, start_time, occurred_at, error_status(exception), {}, nil)
          raise
        end

        track(req, env, start_time, occurred_at, status, headers, response)
        [ status, headers, response ]
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = false
        RailsPulse::Current.rails_pulse_request_id = nil
        RailsPulse::Current.rails_pulse_operations = nil
      end

      private

      # The status the error page will send for this exception. The wrapper
      # unwraps ActionView::Template::Error to its cause, as the error page
      # does. This runs while the host's exception is unwinding, so it must
      # never raise over it — anything unexpected records a 500.
      def error_status(exception)
        ActionDispatch::ExceptionWrapper.new(nil, exception).status_code
      rescue
        500
      end

      # Never raises: a failure to track must not turn a host response, or a
      # host exception, into a Rails Pulse error.
      def track(req, env, start_time, occurred_at, status, headers, response)
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)

        # Operations are copied because the writer thread annotates them (N+1
        # detection) after this request has moved on.
        operations = RailsPulse::Current.rails_pulse_operations || []
        path_params = env["action_dispatch.request.path_parameters"] || {}
        controller_action = [ path_params[:controller], path_params[:action] ].compact.join("#").presence

        RailsPulse::Tracker.track_request(
          build_tracking_data(req, path_params, controller_action, duration, status, occurred_at, headers, response, operations)
        )
      rescue => e
        RailsPulse.logger.error("RailsPulse tracking failed: #{e.class} - #{e.message}")
      end

      # With store_full_details at :all the payload has no :detail key at all.
      # Otherwise a request at or above the named request threshold, one that
      # ran a query at or above the named query threshold, an error, or a
      # sampled request gets the full payload (plus detail: true); every other
      # request is slimmed here, on the request thread, to what the writer's
      # rollups need: the route identity, duration, status, and its SQL
      # operations reduced to statement and duration. Decision 0022.
      def build_tracking_data(req, path_params, controller_action, duration, status, occurred_at, headers, response, operations)
        settings = RailsPulse.configuration.detail_capture_settings
        base = {
          method: req.request_method,
          path: RailsPulse::RoutePathNormalizer.normalize(req.path, path_params),
          duration: duration,
          status: status,
          controller_action: controller_action,
          occurred_at: occurred_at
        }

        if settings.nil? || capture_detail?(settings, duration, status, operations)
          full = base.merge(
            is_error: status.to_i >= 500,
            request_uuid: req.uuid,
            response_size_bytes: response_size_bytes(headers, response),
            operations: operations.map(&:dup)
          )
          full[:detail] = true if settings
          return full
        end

        base.merge(detail: false, operations: slim_sql_operations(operations))
      end

      def capture_detail?(settings, duration, status, operations)
        return true if status.to_i >= 500
        return true if duration >= settings.requests_slower_than
        return true if operations.any? { |op| op[:operation_type] == "sql" && op[:duration].to_f >= settings.queries_slower_than }

        settings.sample_rate > 0 && Kernel.rand < settings.sample_rate
      end

      # Only SQL operations feed aggregates (per-query rollups); everything
      # else exists for the per-request timeline, which a folded request
      # does not keep.
      def slim_sql_operations(operations)
        operations.filter_map do |op|
          next unless op[:operation_type] == "sql"

          {
            operation_type: "sql",
            actual_sql: op[:actual_sql],
            label: op[:label],
            duration: op[:duration]
          }
        end
      end

      def with_recording_suppressed
        RailsPulse::Current.skip_recording_rails_pulse_activity = true
        yield
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = false
      end

      def response_size_bytes(headers, response)
        return headers["Content-Length"].to_i if headers["Content-Length"]
        body = response.respond_to?(:body) ? response.body : nil
        body.bytesize if body.is_a?(String)
      rescue
        nil
      end

      def should_ignore_route?(req)
        # Get ignored routes from configuration
        ignored_routes = RailsPulse.configuration.ignored_routes || []

        # Create route identifier for matching
        route_method_path = "#{req.request_method} #{req.path}"
        route_path = req.path

        # Check each ignored route pattern
        ignored_routes.any? do |pattern|
          case pattern
          when String
            # Exact string match against path or method+path
            pattern == route_path || pattern == route_method_path
          when Regexp
            # Regex match against path or method+path
            pattern.match?(route_path) || pattern.match?(route_method_path)
          else
            false
          end
        end
      end
    end
  end
end
