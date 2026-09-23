module RailsPulse
  module Middleware
    class RequestCollector
      def initialize(app)
        @app = app
      end

      def call(env)
        # Skip if Rails Pulse is disabled
        return @app.call(env) unless RailsPulse.configuration.enabled

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

        # Process request
        status, headers, response = @app.call(env)
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)

        # Collect all tracking data. Operations are copied because the writer
        # thread annotates them (N+1 detection) after this request has moved on.
        operations = RailsPulse::Current.rails_pulse_operations || []
        path_params = env["action_dispatch.request.path_parameters"] || {}
        controller_action = [ path_params[:controller], path_params[:action] ].compact.join("#").presence
        tracking_data = {
          method: req.request_method,
          path: RailsPulse::RoutePathNormalizer.normalize(req.path, path_params),
          duration: duration,
          status: status,
          is_error: status.to_i >= 500,
          request_uuid: req.uuid,
          controller_action: controller_action,
          occurred_at: occurred_at,
          response_size_bytes: response_size_bytes(headers, response),
          operations: operations.map(&:dup)
        }

        # Send to tracker — rescue ensures Pulse never 500s a host request.
        begin
          RailsPulse::Tracker.track_request(tracking_data)
        rescue => e
          RailsPulse.logger.error("RailsPulse tracking failed: #{e.class} - #{e.message}")
        end

        [ status, headers, response ]
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = false
        RailsPulse::Current.rails_pulse_request_id = nil
        RailsPulse::Current.rails_pulse_operations = nil
      end

      private

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
