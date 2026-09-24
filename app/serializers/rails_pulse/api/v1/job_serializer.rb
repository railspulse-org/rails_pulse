module RailsPulse
  module Api
    module V1
      class JobSerializer
        def self.serialize(job)
          {
            id:             job.id,
            name:           job.name,
            queue_name:     job.queue_name,
            runs_count:     job.runs_count,
            failures_count: job.failures_count,
            avg_duration:   job.avg_duration,
            p95_duration:   job.p95_duration,
            p99_duration:   job.p99_duration,
            failure_rate:   job.failure_rate
          }
        end
      end
    end
  end
end
