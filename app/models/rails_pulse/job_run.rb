module RailsPulse
  class JobRun < RailsPulse::ApplicationRecord
    include Taggable
    include HasPerformanceStatus

    performance_status_attribute :duration

    self.table_name = "rails_pulse_job_runs"

    STATUSES = %w[enqueued running success failed discarded retried].freeze
    FINAL_STATUSES = %w[success failed discarded retried].freeze

    belongs_to :job,
               class_name: "RailsPulse::Job",
               counter_cache: :runs_count,
               inverse_of: :runs
    has_many :operations,
             class_name: "RailsPulse::Operation",
             foreign_key: :job_run_id,
             inverse_of: :job_run,
             dependent: :destroy

    validates :run_id, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :occurred_at, presence: true

    def self.ransackable_attributes(auth_object = nil)
      %w[id job_id run_id status occurred_at duration attempts adapter]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[job operations]
    end

    scope :successful, -> { where(status: "success") }
    scope :failed, -> { where(status: %w[failed discarded]) }
    scope :recent, -> { order(occurred_at: :desc) }
    scope :by_adapter, ->(adapter) { where(adapter: adapter) }

    after_commit :apply_to_job_caches, on: %i[create update], if: :finalized?

    def to_breadcrumb
      occurred_at.strftime("%b %d, %Y %l:%M %p")
    end

    def all_tags
      (job.tag_list + tag_list).uniq
    end

    def failure_like_status?
      FINAL_STATUSES.include?(status) && status != "success"
    end

    def finalized?
      change = previous_changes["status"]
      return false unless change

      previous_state, new_state = change
      FINAL_STATUSES.include?(new_state) && !FINAL_STATUSES.include?(previous_state)
    end

    private

    def apply_to_job_caches
      job.apply_run!(self)
    end
  end
end
