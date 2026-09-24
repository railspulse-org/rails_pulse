require "test_helper"

# Job classes defined outside RailsPulse:: namespace so they are not
# treated as internal Rails Pulse jobs and filtered by ignore_job?.
class ActiveJobExtensionsTrackingTestJob < ApplicationJob
  queue_as :default
  def perform; end
end

class ActiveJobExtensionsFailingJob < ApplicationJob
  queue_as :default
  def perform
    raise "intentional failure"
  end
end

module RailsPulse
  class ActiveJobExtensionsTest < ActiveSupport::TestCase
    def setup
      super
      RailsPulse::Current.reset
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

    test "around_perform creates a job run record" do
      assert_difference -> { RailsPulse::JobRun.count }, 1 do
        ActiveJobExtensionsTrackingTestJob.perform_now
      end
    end

    test "around_perform records the job class name" do
      ActiveJobExtensionsTrackingTestJob.perform_now

      job = RailsPulse::Job.find_by(name: "ActiveJobExtensionsTrackingTestJob")

      assert_not_nil job
    end

    test "around_perform records success status" do
      ActiveJobExtensionsTrackingTestJob.perform_now

      run = RailsPulse::JobRun.order(:created_at).last

      assert_equal "success", run.status
    end

    test "around_perform records non-nil duration" do
      ActiveJobExtensionsTrackingTestJob.perform_now

      run = RailsPulse::JobRun.order(:created_at).last

      assert_not_nil run.duration
      assert_operator run.duration, :>=, 0.0
    end

    test "around_perform records failed status when job raises" do
      assert_raises RuntimeError do
        ActiveJobExtensionsFailingJob.perform_now
      end

      run = RailsPulse::JobRun.order(:created_at).last

      assert_equal "failed", run.status
    end

    test "around_perform records error class when job raises" do
      assert_raises RuntimeError do
        ActiveJobExtensionsFailingJob.perform_now
      end

      run = RailsPulse::JobRun.order(:created_at).last

      assert_equal "RuntimeError", run.error_class
    end

    # Real Execution Tests

    test "job still runs when tracking is disabled" do
      RailsPulse.configuration.enabled = false
      executed = false

      assert_no_difference -> { RailsPulse::JobRun.count } do
        ActiveJobExtensionsTrackingTestJob.perform_now
        executed = true
      end

      assert executed
    end
  end
end
