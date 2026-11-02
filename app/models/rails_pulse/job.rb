module RailsPulse
  class Job < RailsPulse::ApplicationRecord
    include Taggable
    include HasPerformanceStatus

    performance_status_attribute :avg_duration

    self.table_name = "rails_pulse_jobs"

    has_many :runs,
             class_name: "RailsPulse::JobRun",
             foreign_key: :job_id,
             inverse_of: :job,
             dependent: :destroy
    has_one :baseline, as: :subject, class_name: "RailsPulse::Baseline", dependent: :delete

    validates :name, presence: true

    def self.ransackable_attributes(auth_object = nil)
      %w[id name queue_name runs_count failures_count retries_count avg_duration p95_duration p99_duration]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[runs]
    end

    scope :by_queue, ->(queue) { where(queue_name: queue) }
    scope :with_failures, -> { where("failures_count > 0") }
    scope :ordered_by_runs, -> { order(runs_count: :desc) }

    def apply_run!(run)
      return unless run.duration

      duration = run.duration.to_f

      with_lock do
        reload
        total_runs = runs_count.to_i
        previous_total = [ total_runs - 1, 0 ].max
        previous_average = avg_duration.to_f

        new_average = if previous_total.zero?
          duration
        else
          ((previous_average * previous_total) + duration) / (previous_total + 1)
        end

        recent_durations = runs.where.not(duration: nil)
                               .order(occurred_at: :desc)
                               .limit(100)
                               .pluck(:duration)
                               .sort

        updates = {
          avg_duration: new_average,
          p95_duration: RailsPulse::Statistics.calculate_percentile(recent_durations, 0.95) || 0.0,
          p99_duration: RailsPulse::Statistics.calculate_percentile(recent_durations, 0.99) || 0.0
        }
        updates[:failures_count] = failures_count + 1 if run.failure_like_status?
        updates[:retries_count] = retries_count + 1 if run.status == "retried"

        update!(updates)
      end
    rescue ActiveRecord::RecordNotFound
      RailsPulse.logger.warn "RailsPulse::Job #{id} was deleted concurrently; skipping cache update for run #{run.id}"
    end

    def failure_rate
      return 0.0 if runs_count.zero?

      ((failures_count.to_f / runs_count) * 100).round(2)
    end

    def to_param
      id.to_s
    end

    def to_breadcrumb
      name.split("/").map(&:camelize).join("::")
    end
  end
end
