require "test_helper"

module RailsPulse
  module Subscribers
    class ExceptionSubscriberTest < ActiveSupport::TestCase
      def setup
        RailsPulse::Current.reset
        RailsPulse::Current.skip_recording_rails_pulse_activity = false
      end

      def teardown
        RailsPulse::Current.reset
        ExceptionCaptureService.reset_deploy_sha_cache!
      end

      test "process captures an exception from a process_action payload" do
        exception = boom_exception

        assert_difference -> { ExceptionOccurrence.count }, 1 do
          ExceptionSubscriber.new(notification_event(exception)).process
        end

        occurrence = ExceptionOccurrence.order(:created_at).last

        assert_equal "/posts/1", occurrence.request_url
        assert_equal "GET", occurrence.request_method
      end

      test "process is a no-op without an exception object" do
        assert_no_difference -> { ExceptionOccurrence.count } do
          ExceptionSubscriber.new(notification_event(nil)).process
        end
      end

      test "process skips an exception already captured by JobRunCollector" do
        exception = boom_exception
        RailsPulse::Current.rails_pulse_captured_exception = exception

        assert_no_difference -> { ExceptionOccurrence.count } do
          ExceptionSubscriber.new(notification_event(exception)).process
        end
      end

      test "process is a no-op when track_exceptions is disabled" do
        original = RailsPulse.configuration.track_exceptions
        RailsPulse.configuration.track_exceptions = false
        exception = boom_exception

        assert_no_difference -> { ExceptionOccurrence.count } do
          ExceptionSubscriber.new(notification_event(exception)).process
        end
      ensure
        RailsPulse.configuration.track_exceptions = original
      end

      private

      def boom_exception
        error = RuntimeError.new("subscriber boom")
        error.set_backtrace([ "#{Rails.root}/app/models/post.rb:1:in 'save'" ])
        error
      end

      def notification_event(exception)
        payload = {
          path: "/posts/1",
          method: "GET",
          params: { "id" => "1" },
          exception_object: exception
        }
        ActiveSupport::Notifications::Event.new(
          "process_action.action_controller",
          Time.current,
          Time.current,
          "exception-subscriber-test",
          payload
        )
      end
    end
  end
end
