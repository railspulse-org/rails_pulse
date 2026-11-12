require "securerandom"

module RailsPulse
  # Records one job run: the Job row, the JobRun as it starts, its outcome,
  # its operations, and on failure the exception. In remote mode nothing is
  # written here; a Remote::JobRun collects the same attributes and is sent
  # to the central once the job ends, and the central records it through
  # `record`, with the same writes.
  class JobRunCollector
    # What a run starts with and what its outcome sets, as `record` replays
    # them for a run that ended in another process.
    START_ATTRIBUTES = %i[enqueued_at occurred_at attempts adapter arguments].freeze
    OUTCOME_ATTRIBUTES = %i[status duration error_class error_message].freeze

    class << self
      def track(active_job, adapter: detect_adapter)
        return yield unless tracking_enabled?
        return yield if ignore_job?(active_job)

        previous_request_id = RailsPulse::Current.rails_pulse_request_id
        previous_operations = RailsPulse::Current.rails_pulse_operations
        previous_job_run_id = RailsPulse::Current.rails_pulse_job_run_id

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        occurred_at = Time.current

        job_run = nil

        # Pulse DB writes before yield must not prevent the job from running.
        begin
          with_recording_suppressed do
            job_run = start_job_run(active_job, adapter, occurred_at)
          end
        rescue => e
          RailsPulse.logger.error "Failed to initialize job tracking: #{e.class} - #{e.message}"
          job_run = nil
        end

        RailsPulse::Current.rails_pulse_request_id = nil
        RailsPulse::Current.rails_pulse_job_run_id = job_run&.id
        RailsPulse::Current.rails_pulse_operations = []

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
          RailsPulse::Current.rails_pulse_captured_exception = error
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
          RailsPulse::Current.rails_pulse_job_run_id = previous_job_run_id
          RailsPulse::Current.rails_pulse_operations = previous_operations
          RailsPulse::Current.rails_pulse_request_id = previous_request_id
        end
      end

      def should_ignore_job?(job)
        ignore_job?(job)
      end

      # Records a job run an application sent a central (Remote::JobRun):
      # the job, the run as it started, its outcome, then its operations, as
      # `track` writes them where the job ran.
      def record(run)
        with_recording_suppressed do
          job = find_or_create_job_named(run[:job_class], run[:queue_name])
          job_run = persist_job_run(job, run[:run_id], run.slice(*START_ATTRIBUTES).merge(status: run[:initial_status]))
          job_run.update!(run.slice(*OUTCOME_ATTRIBUTES))
          RailsPulse::Operation.persist_bulk(Array(run[:operations]), job_run_id: job_run.id, request_id: nil)
          job_run
        end
      end

      private

      def start_job_run(active_job, adapter, occurred_at)
        unless RailsPulse::Remote.enabled?
          job = find_or_create_job(active_job)
          return create_job_run(job, active_job, adapter, occurred_at)
        end

        RailsPulse::Remote::JobRun.new(
          job_class: job_class_name(active_job),
          queue_name: active_job.queue_name,
          run_id: run_id_for(active_job),
          **run_attributes(active_job, adapter, occurred_at)
        )
      end

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
        find_or_create_job_named(job_class_name(active_job), active_job.queue_name)
      end

      def find_or_create_job_named(name, queue_name)
        RailsPulse::Job.find_or_create_by!(name: name) do |job|
          job.queue_name = queue_name
        end
      rescue ActiveRecord::RecordNotUnique
        RailsPulse::Job.find_by!(name: name)
      end

      def create_job_run(job, active_job, adapter, occurred_at)
        persist_job_run(job, run_id_for(active_job), run_attributes(active_job, adapter, occurred_at))
      end

      def persist_job_run(job, run_id, attributes)
        attrs = attributes.merge(job: job)

        job_run = RailsPulse::JobRun.create_or_find_by!(run_id: run_id) { |r| r.assign_attributes(attrs) }
        unless job_run.previously_new_record?
          job_run.assign_attributes(attrs)
          job_run.save!
        end
        job_run
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        RailsPulse::JobRun.find_by!(run_id: run_id)
      end

      def run_id_for(active_job)
        active_job.job_id || SecureRandom.uuid
      end

      def run_attributes(active_job, adapter, occurred_at)
        {
          status: initial_status_for(active_job),
          enqueued_at: safe_timestamp(active_job.try(:enqueued_at)),
          occurred_at: occurred_at,
          attempts: (active_job.respond_to?(:executions) ? active_job.executions : 0),
          adapter: adapter,
          arguments: serialized_arguments(active_job)
        }
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

        ops = RailsPulse::Current.rails_pulse_operations || []
        return job_run.track(ops) if job_run.is_a?(RailsPulse::Remote::JobRun)

        with_recording_suppressed do
          RailsPulse::Operation.persist_bulk(ops, job_run_id: job_run.id, request_id: nil)
        end
      rescue => e
        RailsPulse.logger.error "Failed to save job operations: #{e.class} - #{e.message}"
      ensure
        RailsPulse::Current.rails_pulse_operations = nil
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
        previous = RailsPulse::Current.skip_recording_rails_pulse_activity
        RailsPulse::Current.skip_recording_rails_pulse_activity = true
        yield
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = previous
      end
    end
  end
end
