module RailsPulse
  class ExceptionOccurrence < RailsPulse::ApplicationRecord
    self.table_name = "rails_pulse_exception_occurrences"

    belongs_to :exception_group, class_name: "RailsPulse::ExceptionGroup"

    serialize :backtrace, type: Array, coder: JSON
    serialize :request_params, type: Hash, coder: JSON

    validates :exception_class, presence: true
    validates :occurred_at, presence: true

    scope :recent, -> { order(occurred_at: :desc) }

    def self.ransackable_attributes(auth_object = nil)
      %w[id exception_class message occurred_at request_url environment]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[exception_group]
    end

    def to_breadcrumb
      occurred_at.strftime("%b %d, %Y %l:%M %p")
    end
  end
end
