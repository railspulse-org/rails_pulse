module RailsPulse
  class Request < RailsPulse::ApplicationRecord
    include Taggable

    self.table_name = "rails_pulse_requests"

    attribute :is_error, :boolean, default: false

    # Associations
    belongs_to :route, class_name: "RailsPulse::Route"
    has_many :operations, class_name: "RailsPulse::Operation", foreign_key: "request_id", dependent: :destroy

    # Validations
    validates :route_id, presence: true
    validates :occurred_at, presence: true
    validates :duration, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :status, presence: true
    validates :is_error, inclusion: { in: [ true, false ] }
    validates :request_uuid, presence: true

    before_validation :set_request_uuid, on: :create

    def self.ransackable_attributes(auth_object = nil)
      %w[id route_id occurred_at duration status status_category status_indicator route_path http_method controller_action response_size_bytes]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[route]
    end

    ransacker :occurred_at do |parent|
      parent.table[:occurred_at]
    end

    ransacker :route_path do |parent|
      Arel.sql("rails_pulse_routes.path")
    end

    ransacker :http_method do |parent|
      parent.table[:method]
    end

    ransacker :status_category do |parent|
      # Returns the first digit of the status code (2, 3, 4, or 5)
      # Use FLOOR instead of CAST for cross-database compatibility
      Arel.sql("FLOOR(#{parent.table[:status].name} / 100)")
    end

    ransacker :status_indicator do |parent|
      # Calculate status indicator based on request_thresholds with safe defaults
      config = RailsPulse.configuration rescue nil
      thresholds = config&.request_thresholds || { slow: 500, very_slow: 1000, critical: 2000 }

      slow = thresholds[:slow] || 500
      very_slow = thresholds[:very_slow] || 1000
      critical = thresholds[:critical] || 2000

      Arel.sql("
        CASE
          WHEN rails_pulse_requests.duration < #{slow} THEN 0
          WHEN rails_pulse_requests.duration < #{very_slow} THEN 1
          WHEN rails_pulse_requests.duration < #{critical} THEN 2
          ELSE 3
        END
      ")
    end

    def to_s
      occurred_at.strftime("%b %d, %Y %l:%M %p")
    end

    private

    def set_request_uuid
      self.request_uuid = SecureRandom.uuid if request_uuid.blank?
    end
  end
end
