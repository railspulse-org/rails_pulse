require "test_helper"
require "delayed_job"
require "delayed_job_active_record"
require "rails_pulse/adapters/delayed_job_plugin"

module RailsPulse
  module Adapters
    class DelayedJobPluginTest < ActiveSupport::TestCase
      class FakeWorker; end

      class FakePayload
        def self.name = "FakeDelayedJobPayload"
        def args = [ "arg1", "arg2" ]
      end

      class FakePayloadWithArguments
        def self.name = "FakeDelayedJobPayloadWithArguments"
        def arguments = [ "arg3", "arg4" ]
      end

      class FakePayloadNoArgs
        def self.name = "FakeDelayedJobPayloadNoArgs"
      end

      class FakeDelayedJobData
        attr_accessor :attempts, :payload_object

        def initialize(payload: FakePayload.new, attempts: 0)
          @payload_object = payload
          @attempts = attempts
        end

        def id = 42
        def queue = "default"
        def created_at = 5.minutes.ago
      end

      def setup
        super
        RailsPulse::Current.reset
        @fake_worker = FakeWorker.new
        @fake_job    = FakeDelayedJobData.new
        @original_enabled    = RailsPulse.configuration.enabled
        @original_track_jobs = RailsPulse.configuration.track_jobs
        RailsPulse.configuration.enabled    = true
        RailsPulse.configuration.track_jobs = true
      end

      def teardown
        RailsPulse::Current.reset
        RailsPulse.configuration.enabled    = @original_enabled
        RailsPulse.configuration.track_jobs = @original_track_jobs
        super
      end

      def run_plugin(worker: @fake_worker, job_data: @fake_job, &work_block)
        lifecycle = Delayed::Lifecycle.new
        DelayedJobPlugin.callback_block.call(lifecycle)
        lifecycle.run_callbacks(:perform, worker, job_data) do
          work_block&.call
        end
      end

      # Tracking Tests

      test "tracks job run when enabled and track_jobs is true" do
        assert_difference -> { RailsPulse::JobRun.count }, 1 do
          run_plugin { }
        end
      end

      test "creates job record with correct class name from payload" do
        run_plugin { }

        job = RailsPulse::Job.order(:created_at).last

        assert_equal "FakeDelayedJobPayload", job.name
      end

      test "records adapter as delayed_job" do
        run_plugin { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal "delayed_job", run.adapter
      end

      test "skips tracking when disabled" do
        RailsPulse.configuration.enabled = false

        assert_no_difference -> { RailsPulse::JobRun.count } do
          run_plugin { }
        end
      end

      test "skips tracking when track_jobs is false" do
        RailsPulse.configuration.track_jobs = false

        assert_no_difference -> { RailsPulse::JobRun.count } do
          run_plugin { }
        end
      end

      test "still yields the block when disabled" do
        RailsPulse.configuration.enabled = false
        yielded = false

        run_plugin { yielded = true }

        assert yielded
      end

      # Metadata Tests

      test "maps attempts from job_data" do
        @fake_job.attempts = 3

        run_plugin { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal 3, run.attempts
      end

      test "records enqueued_at from job_data created_at" do
        run_plugin { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_not_nil run.enqueued_at
      end

      test "records success status when block succeeds" do
        run_plugin { }

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal "success", run.status
      end

      test "records failed status when block raises" do
        assert_raises RuntimeError do
          run_plugin { raise "fail" }
        end

        run = RailsPulse::JobRun.order(:created_at).last

        assert_equal "failed", run.status
      end

      # Argument Extraction Tests

      test "uses payload args for arguments" do
        run_plugin { }

        job = RailsPulse::Job.order(:created_at).last

        assert_equal "FakeDelayedJobPayload", job.name
      end

      test "uses payload arguments when args not available" do
        @fake_job = FakeDelayedJobData.new(payload: FakePayloadWithArguments.new)

        assert_difference -> { RailsPulse::JobRun.count }, 1 do
          run_plugin { }
        end

        job = RailsPulse::Job.order(:created_at).last

        assert_equal "FakeDelayedJobPayloadWithArguments", job.name
      end

      test "falls back to empty arguments when neither args nor arguments available" do
        @fake_job = FakeDelayedJobData.new(payload: FakePayloadNoArgs.new)

        assert_difference -> { RailsPulse::JobRun.count }, 1 do
          run_plugin { }
        end

        job = RailsPulse::Job.order(:created_at).last

        assert_equal "FakeDelayedJobPayloadNoArgs", job.name
      end
    end
  end
end
