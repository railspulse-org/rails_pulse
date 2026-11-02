module RailsPulse
  # What normal looks like for one route, query or job: its median, P90 and
  # P95 durations over recent summaries, with how much data they rest on.
  # One row per subject, rebuilt in place. Auto thresholds and auto detail
  # capture measure against it, so sample_count and periods let a caller
  # decide whether a baseline has enough history to trust.
  class Baseline < RailsPulse::ApplicationRecord
    self.table_name = "rails_pulse_baselines"

    SUBJECT_TYPES = %w[RailsPulse::Route RailsPulse::Query RailsPulse::Job].freeze

    belongs_to :subject, polymorphic: true

    validates :subject_type, inclusion: { in: SUBJECT_TYPES }
    validates :subject_id, uniqueness: { scope: :subject_type }
    validates :computed_at, presence: true
    validates :sample_count, :periods, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :p50_ms, :p90_ms, :p95_ms, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id subject_type subject_id p50_ms p90_ms p95_ms sample_count periods computed_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
