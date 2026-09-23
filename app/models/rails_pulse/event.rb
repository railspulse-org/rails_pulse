module RailsPulse
  # What Rails Pulse noticed, as opposed to what it measured. One row per
  # outcome or sample, tagged by `kind`; `subject` names what it is about,
  # `value` carries its number and `metadata` the kind-specific detail as JSON.
  #
  # The free gem writes writer_heartbeat rows (see WriterHeartbeat).
  # rails_pulse_pro writes its alert triggers, regression checks, exception
  # alerts and job heartbeats here too, so a host has one table for all of it
  # and Pro installs without a migration of its own. Decision 0019.
  #
  # CleanupService deletes rows older than config.event_retention_period,
  # except kinds listed in config.event_retention_exempt_kinds (rows a writer
  # updates in place, such as Pro's job heartbeats). Writer heartbeats are
  # pruned after a day by the writer itself.
  class Event < RailsPulse::ApplicationRecord
    include HasMetadata

    self.table_name = "rails_pulse_events"

    validates :kind, :outcome, :occurred_at, presence: true

    scope :of_kind,     ->(*kinds) { where(kind: kinds.flatten.map(&:to_s)) }
    scope :for_subject, ->(subject) { where(subject: subject) }
    scope :since,       ->(time) { where(occurred_at: time..) }
    scope :recent,      -> { order(occurred_at: :desc) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[kind subject outcome value occurred_at message created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    # table_exists?, rescued consistently. Several call sites need to know
    # whether this table is there yet (an upgrader who hasn't migrated) —
    # centralized here instead of each reimplementing the rescue.
    def self.table_available?
      table_exists?
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end
end
