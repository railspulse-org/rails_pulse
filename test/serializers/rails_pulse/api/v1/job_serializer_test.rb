require "test_helper"

module RailsPulse
  module Api
    module V1
      class JobSerializerTest < ActiveSupport::TestCase
        test "serializes all expected fields" do
          job = rails_pulse_jobs(:mailer_job)
          result = JobSerializer.serialize(job)

          assert_equal job.id,             result[:id]
          assert_equal job.name,           result[:name]
          assert_equal job.queue_name,     result[:queue_name]
          assert_equal job.runs_count,     result[:runs_count]
          assert_equal job.failures_count, result[:failures_count]
          assert_equal job.avg_duration,   result[:avg_duration]
          assert_nil result[:p95_duration]
          assert_nil result[:p99_duration]
          assert_equal job.failure_rate,   result[:failure_rate]
        end

        test "returns a hash with exactly the expected keys" do
          result = JobSerializer.serialize(rails_pulse_jobs(:mailer_job))

          assert_equal %i[id name queue_name runs_count failures_count avg_duration p95_duration p99_duration failure_rate], result.keys
        end
      end
    end
  end
end
