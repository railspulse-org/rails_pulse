require "test_helper"
require "rails_pulse/adapters/sidekiq_middleware"

module RailsPulse
  module Adapters
    class SidekiqMiddlewareTest < ActiveSupport::TestCase
      class FakeWorker
        def self.name
          "FakeSidekiqWorker"
        end
      end

      def setup
        super
        RailsPulse::Current.reset
        @middleware = SidekiqMiddleware.new
        @worker = FakeWorker.new
        @job_data = {
          "jid" => "abc123",
          "args" => [ 1, 2 ],
          "queue" => "default",
          "enqueued_at" => Time.current.to_f,
          "retry_count" => 0
        }
        @original_enabled = RailsPulse.configuration.enabled
        @original_track_jobs = RailsPulse.configuration.track_jobs
        RailsPulse.configuration.enabled = true
        RailsPulse.configuration.track_jobs = true
      end

      def teardown
        RailsPulse::Current.reset
        RailsPulse.configuration.enabled = @original_enabled
        RailsPulse.configuration.track_jobs = @original_track_jobs
        super
      end

      # Tracking Tests

      test "call tracks job run when enabled and track_jobs is true" do
        assert_difference -> { RailsPulse::JobRun.count }, 1 do
          @middleware.call(@worker, @job_data, "default") { }
        end
      end

      test "call creates job record with correct class name" do
        @middleware.call(@worker, @job_data, "default") { }

        job = RailsPulse::Job.order(:created_at).last

        assert_equal "FakeSidekiqWorker", job.name
      end

      test "call skips tracking when disabled" do
        RailsPulse.configuration.enabled = false

        assert_no_difference -> { RailsPulse::JobRun.count } do
          @middleware.call(@worker, @job_data, "default") { }
        end
      end

      test "call skips tracking when track_jobs is false" do
        RailsPulse.configuration.track_jobs = false

        assert_no_difference -> { RailsPulse::JobRun.count } do
          @middleware.call(@worker, @job_data, "default") { }
        end
      end

      test "call still yields the block when disabled" do
        RailsPulse.configuration.enabled = false
        yielded = false

        @middleware.call(@worker, @job_data, "default") { yielded = true }

        assert yielded
      end

      # Metadata Tests

      test "call maps retry_count to executions" do
        @job_data["retry_count"] = 3

        @middleware.call(@worker, @job_data, "default") { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal 3, run.attempts
      end

      test "call records success status when block succeeds" do
        @middleware.call(@worker, @job_data, "default") { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal "success", run.status
      end

      test "call records failed status when block raises" do
        assert_raises RuntimeError do
          @middleware.call(@worker, @job_data, "default") { raise "fail" }
        end

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal "failed", run.status
      end

      # Edge Cases

      test "call handles missing enqueued_at gracefully" do
        @job_data.delete("enqueued_at")

        assert_nothing_raised do
          @middleware.call(@worker, @job_data, "default") { }
        end
      end

      test "call handles missing retry_count gracefully" do
        @job_data.delete("retry_count")

        @middleware.call(@worker, @job_data, "default") { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal 0, run.attempts
      end
    end
  end
end
