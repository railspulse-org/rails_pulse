module RailsPulse
  class Deployment < RailsPulse::ApplicationRecord
    include HasMetadata

    self.table_name = "rails_pulse_deployments"

    # The create endpoint is reachable with a CI token, so every field a
    # caller controls is bounded: a leaked token must not be able to fill the
    # table or push a marker into the future (which would stamp every later
    # exception with a revision that has not shipped).
    MAX_REVISION_LENGTH = 255
    MAX_METADATA_BYTES  = 4.kilobytes
    MAX_CLOCK_SKEW      = 1.hour

    validates :revision,   presence: true, length: { maximum: MAX_REVISION_LENGTH }
    validates :started_at, presence: true
    validate  :started_at_is_not_in_the_future
    validate  :metadata_is_within_size_limit

    scope :for_range, ->(start_time, end_time) { where(started_at: start_time..end_time) }
    scope :recent,    -> { order(started_at: :desc) }

    # A revision can be deployed more than once (rollbacks, re-deploys); both
    # the finish API endpoint and rails_pulse:finish_deployment close this row.
    def self.latest_for_revision(revision)
      where(revision: revision).order(started_at: :desc).first
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id revision started_at finished_at created_at]
    end

    def self.ransackable_associations(auth_object = nil)
      []
    end

    # Breadcrumbs fall back to #to_s without this, which renders the object's
    # inspect string. Revisions can be full 40-char SHAs, so truncate.
    def to_breadcrumb
      short_revision
    end

    def short_revision
      revision.to_s.length > 12 ? revision.to_s.first(12) : revision.to_s
    end

    def in_progress?
      finished_at.blank?
    end

    # Wall-clock seconds the deploy took, or nil while it is still running.
    def duration
      return nil if in_progress? || started_at.blank?
      finished_at - started_at
    end

    def to_chart_marker
      { timestamp: started_at.to_i * 1000, revision: revision, started_at: started_at.iso8601 }
    end

    private

    def started_at_is_not_in_the_future
      return if started_at.blank?
      return if started_at <= MAX_CLOCK_SKEW.from_now

      errors.add(:started_at, "can't be more than #{MAX_CLOCK_SKEW.inspect} in the future")
    end

    def metadata_is_within_size_limit
      return if metadata.blank?
      return if metadata.to_s.bytesize <= MAX_METADATA_BYTES

      errors.add(:metadata, "is too large (maximum is #{MAX_METADATA_BYTES.to_i / 1024} KB)")
    end
  end
end
