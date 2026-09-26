module RailsPulse
  module Api
    module V1
      class JobRunSerializer
        ERROR_MESSAGE_LIMIT = 500

        def self.serialize(run)
          {
            id:            run.id,
            job_id:        run.job_id,
            job_name:      run.job&.name,
            queue_name:    run.job&.queue_name,
            run_id:        run.run_id,
            status:        run.status,
            occurred_at:   run.occurred_at,
            enqueued_at:   run.enqueued_at,
            duration:      run.duration,
            attempts:      run.attempts,
            adapter:       run.adapter,
            error_class:   run.error_class,
            error_message: run.error_message&.truncate(ERROR_MESSAGE_LIMIT),
            tags:          run.tags
          }
        end
      end
    end
  end
end
