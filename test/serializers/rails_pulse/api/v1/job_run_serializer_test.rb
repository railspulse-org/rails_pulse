require "test_helper"

module RailsPulse
  module Api
    module V1
      class JobRunSerializerTest < ActiveSupport::TestCase
        setup do
          @run = RailsPulse::JobRun.create!(
            job: rails_pulse_jobs(:report_job), run_id: "ser-run-1", status: "failed",
            occurred_at: 1.hour.ago, enqueued_at: 61.minutes.ago, duration: 42.5, attempts: 2,
            adapter: "sidekiq", error_class: "RuntimeError", error_message: "x" * 600,
            arguments: '["user@example.com"]'
          )
        end

        teardown do
          @run.destroy
        end

        test "serializes run fields with job name and queue" do
          result = JobRunSerializer.serialize(@run)

          assert_equal @run.id,            result[:id]
          assert_equal "GenerateReportJob", result[:job_name]
          assert_equal "default",           result[:queue_name]
          assert_equal "ser-run-1",         result[:run_id]
          assert_equal "failed",            result[:status]
          assert_equal 2,                   result[:attempts]
          assert_equal "sidekiq",           result[:adapter]
          assert_equal "RuntimeError",      result[:error_class]
          assert_in_delta 42.5, result[:duration]
        end

        test "truncates long error messages" do
          result = JobRunSerializer.serialize(@run)

          assert_equal 500, result[:error_message].length
        end

        test "never includes arguments" do
          result = JobRunSerializer.serialize(@run)

          assert_not result.key?(:arguments)
          assert_no_match(/user@example\.com/, result.to_json)
        end
      end
    end
  end
end
