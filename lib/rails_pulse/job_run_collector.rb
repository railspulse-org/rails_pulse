require "securerandom"

module RailsPulse
  class JobRunCollector
    class << self
      def track(active_job, adapter: detect_adapter)
        return yield unless tracking_enabled?
        return yield if ignore_job?(active_job)

        previous_request_id = RequestStore.store[:rails_pulse_request_id]
        previous_operations = RequestStore.store[:rails_pulse_operations]
        previous_job_run_id = RequestStore.store[:rails_pulse_job_run_id]

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        occurred_at = Time.current

        job = nil
        job_run = nil

        # Pulse DB writes before yield must not prevent the job from running.
        begin
          with_recording_suppressed do
            job = find_or_create_job(active_job)
            job_run = create_job_run(job, active_job, adapter, occurred_at)
          end
        rescue => e
          RailsPulse.logger.error "Failed to initialize job tracking: #{e.class} - #{e.message}"
          job_run = nil
        end

        RequestStore.store[:rails_pulse_request_id] = nil
        RequestStore.store[:rails_pulse_job_run_id] = job_run&.id
        RequestStore.store[:rails_pulse_operations] = []

        yield

        # Record success — must not re-raise if the job already completed.
        begin
          if job_run
            duration = elapsed_time_ms(start_time)
            with_recording_suppressed do
              job_run.update!(status: "success", duration: duration)
            end
          end
        rescue => e
          RailsPulse.logger.error "Failed to record job success: #{e.class} - #{e.message}"
        end
      rescue => error
        # Record failure — must always re-raise the ORIGINAL error.
        begin
          if job_run
            duration = elapsed_time_ms(start_time)
            with_recording_suppressed do
              job_run.update!(
                status: failure_status_for(error),
                duration: duration,
                error_class: error.class.name,
                # Same redaction as exception occurrences — a job failure
                # message can carry the same literal PII a request one can.
                error_message: RailsPulse::ExceptionMessageSanitizer.for_exception(error)
              )
            end
          end
          # Capture outside with_recording_suppressed — the capture service
          # checks skip_recording_rails_pulse_activity and would bail out.
          # The service's own SQL is already filtered by the rails_pulse_ prefix.
          RailsPulse::ExceptionCaptureService.capture(error, environment: Rails.env.to_s)
          RequestStore.store[:rails_pulse_captured_exception] = error
        rescue => e
          RailsPulse.logger.error "Failed to record job failure: #{e.class} - #{e.message}"
        end
        raise error
      ensure
        begin
          save_operations(job_run)
        rescue => e
          RailsPulse.logger.error "Failed to persist job operations: #{e.class} - #{e.message}"
        ensure
          RequestStore.store[:rails_pulse_job_run_id] = previous_job_run_id
          RequestStore.store[:rails_pulse_operations] = previous_operations
          RequestStore.store[:rails_pulse_request_id] = previous_request_id
        end
      end

      def should_ignore_job?(job)
        ignore_job?(job)
      end

      private

      def tracking_enabled?
        config = RailsPulse.configuration
        config.enabled && config.track_jobs && RailsPulse::SchemaCheck.tracking_allowed?
      end

      def ignore_job?(job)
        config = RailsPulse.configuration
        job_class = job_class_name(job)
        queue_name = job.queue_name

        return true if config.ignored_jobs&.include?(job_class)
        return true if config.ignored_queues&.include?(queue_name)
        return true if job_class.start_with?("RailsPulse::")

        false
      end

      def find_or_create_job(active_job)
        RailsPulse::Job.find_or_create_by!(name: job_class_name(active_job)) do |job|
          job.queue_name = active_job.queue_name
        end
      rescue ActiveRecord::RecordNotUnique
        RailsPulse::Job.find_by!(name: job_class_name(active_job))
      end

      def create_job_run(job, active_job, adapter, occurred_at)
        run_id = active_job.job_id || SecureRandom.uuid
        attrs = {
          job: job,
          status: initial_status_for(active_job),
          enqueued_at: safe_timestamp(active_job.try(:enqueued_at)),
          occurred_at: occurred_at,
          attempts: (active_job.respond_to?(:executions) ? active_job.executions : 0),
          adapter: adapter,
          arguments: serialized_arguments(active_job)
        }

        job_run = RailsPulse::JobRun.create_or_find_by!(run_id: run_id) { |r| r.assign_attributes(attrs) }
        unless job_run.previously_new_record?
          job_run.assign_attributes(attrs)
          job_run.save!
        end
        job_run
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        RailsPulse::JobRun.find_by!(run_id: run_id)
      end

      def serialized_arguments(active_job)
        return unless RailsPulse.configuration.capture_job_arguments

        Array(active_job.arguments).to_json
      rescue StandardError => e
        RailsPulse.logger.debug "Unable to serialize job arguments: #{e.class} - #{e.message}"
        nil
      end

      def initial_status_for(active_job)
        active_job.respond_to?(:scheduled_at) ? "enqueued" : "running"
      end

      def failure_status_for(error)
        error.is_a?(StandardError) ? "failed" : "discarded"
      end

      def save_operations(job_run)
        return unless job_run

        ops = RequestStore.store[:rails_pulse_operations] || []
        with_recording_suppressed do
          RailsPulse::Operation.persist_bulk(ops, job_run_id: job_run.id, request_id: nil)
        end
      rescue => e
        RailsPulse.logger.error "Failed to save job operations: #{e.class} - #{e.message}"
      ensure
        RequestStore.store[:rails_pulse_operations] = nil
      end

      def detect_adapter
        return "sidekiq" if defined?(::Sidekiq)
        return "solid_queue" if defined?(::SolidQueue)
        return "good_job" if defined?(::GoodJob)
        return "delayed_job" if defined?(::Delayed::Job)
        return "resque" if defined?(::Resque)
        return "que" if defined?(::Que)

        "active_job"
      end

      def elapsed_time_ms(start_time)
        return 0.0 unless start_time

        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
      end

      def safe_timestamp(value)
        case value
        when Time, ActiveSupport::TimeWithZone
          value
        when Integer
          Time.at(value)
        else
          nil
        end
      end

      def job_class_name(job)
        job.respond_to?(:class_name) ? job.class_name : job.class.name
      end

      def with_recording_suppressed
        previous = RequestStore.store[:skip_recording_rails_pulse_activity]
        RequestStore.store[:skip_recording_rails_pulse_activity] = true
        yield
      ensure
        RequestStore.store[:skip_recording_rails_pulse_activity] = previous
      end
    end
  end
end
