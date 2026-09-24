module RailsPulse
  module Subscribers
    class ExceptionSubscriber
      def self.subscribe!
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          new(event).process
        end
      end

      def initialize(event)
        @event = event
      end

      def process
        return unless RailsPulse.configuration.enabled
        return unless RailsPulse.configuration.track_exceptions
        return if RailsPulse::Current.skip_recording_rails_pulse_activity

        exception = @event.payload[:exception_object]
        return unless exception
        return if RailsPulse::Current.rails_pulse_captured_exception.equal?(exception)

        RailsPulse::ExceptionCaptureService.capture(
          exception,
          request_url:     @event.payload[:path],
          request_method:  @event.payload[:method],
          request_params:  @event.payload[:params],
          environment:     Rails.env.to_s
        )
      rescue => e
        Rails.logger.error("[RailsPulse] ExceptionSubscriber error: #{e.message}")
      end
    end
  end
end
