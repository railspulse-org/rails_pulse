module RailsPulse
  # Per-request/per-job state threaded from collection (middleware, job
  # wrapper, subscribers) through to the writer. Thread-local; Rails' executor
  # resets it automatically around requests and jobs, but RequestCollector and
  # JobRunCollector also reset it explicitly so behaviour does not depend on
  # the executor being present (rack-only apps, `perform_now` in a console).
  #
  # rails_pulse_script_name is set only on a central, for the length of one
  # dashboard request: the prefix engine URL helpers generate links under
  # (RailsPulse::Central::RequestScriptName).
  class Current < ActiveSupport::CurrentAttributes
    attribute :rails_pulse_request_id, :rails_pulse_job_run_id, :rails_pulse_operations,
              :skip_recording_rails_pulse_activity, :rails_pulse_captured_exception,
              :rails_pulse_script_name
  end
end
