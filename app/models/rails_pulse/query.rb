module RailsPulse
  class Query < RailsPulse::ApplicationRecord
    include Taggable

    self.table_name = "rails_pulse_queries"

    # Associations
    has_many :operations, class_name: "RailsPulse::Operation", inverse_of: :query
    has_many :summaries, as: :summarizable, class_name: "RailsPulse::Summary", dependent: :destroy
    has_one :baseline, as: :subject, class_name: "RailsPulse::Baseline", dependent: :delete

    # Validations
    validates :normalized_sql, presence: true
    validates :hashed_sql, presence: true

    # Callbacks
    before_validation :generate_hashed_sql, if: -> { normalized_sql.present? && (normalized_sql_changed? || hashed_sql.blank?) }

    # JSON serialization for analysis columns
    serialize :issues, type: Array, coder: JSON
    serialize :metadata, type: Hash, coder: JSON
    serialize :query_stats, type: Hash, coder: JSON
    serialize :backtrace_analysis, type: Hash, coder: JSON
    serialize :n_plus_one_analysis, type: Hash, coder: JSON
    serialize :index_recommendations, type: Array, coder: JSON
    serialize :suggestions, type: Array, coder: JSON

    def self.bulk_find_or_create(norm_map)
      return {} if norm_map.empty?

      id_map = where(hashed_sql: norm_map.keys).pluck(:hashed_sql, :id).to_h

      missing = norm_map.reject { |h, _| id_map.key?(h) }
      unless missing.empty?
        now = Time.current
        insert_all(missing.map { |h, n| { hashed_sql: h, normalized_sql: n, created_at: now, updated_at: now } })
        id_map.merge!(where(hashed_sql: missing.keys).pluck(:hashed_sql, :id).to_h)
      end

      id_map
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id normalized_sql average_query_time_ms execution_count total_time_consumed performance_status occurred_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[operations]
    end

    ransacker :average_query_time_ms do
      Arel.sql("COALESCE(AVG(rails_pulse_operations.duration), 0)")
    end

    ransacker :execution_count do
      Arel.sql("COUNT(rails_pulse_operations.id)")
    end

    ransacker :total_time_consumed do
      Arel.sql("COALESCE(SUM(rails_pulse_operations.duration), 0)")
    end

    ransacker :performance_status do
      # Calculate status indicator based on query_thresholds with safe defaults
      config = RailsPulse.configuration rescue nil
      thresholds = config&.query_thresholds || { slow: 200, very_slow: 500, critical: 1000 }

      slow = (thresholds[:slow] || 200).to_f
      very_slow = (thresholds[:very_slow] || 500).to_f
      critical = (thresholds[:critical] || 1000).to_f

      # Use Arel to safely construct the SQL with parameterized values
      avg_duration = Arel.sql("COALESCE(AVG(rails_pulse_operations.duration), 0)")

      Arel::Nodes::Case.new(avg_duration)
        .when(avg_duration.lt(slow)).then(0)
        .when(avg_duration.lt(very_slow)).then(1)
        .when(avg_duration.lt(critical)).then(2)
        .else(3)
    end

    ransacker :occurred_at do
      Arel.sql("MAX(rails_pulse_operations.occurred_at)")
    end

    def recent_operations
      operations
        .where("occurred_at > ?", 30.days.ago)
        .order(occurred_at: :desc)
        .limit(500)
        .to_a
    end

    def n_plus_one_groups(ops)
      ops
        .reject { |op| op.repeated_query_group.nil? }
        .group_by(&:repeated_query_group)
        .transform_values { |group| group.map(&:repetition_count).compact.max }
    end

    def ensure_analyzed!
      return if analyzed?
      QueryAnalysisService.analyze_query(id)
      reload
    rescue => e
      RailsPulse.logger.warn("[Query] Auto-analysis failed for query #{id}: #{e.message}")
    end

    # Analysis helper methods
    def analyzed?
      analyzed_at.present?
    end

    def has_recent_operations?
      operations.where("occurred_at > ?", 48.hours.ago).exists?
    end

    def needs_reanalysis?
      return true unless analyzed?

      # Check if there are new operations since analysis
      last_operation_time = operations.maximum(:occurred_at)
      return false unless last_operation_time

      last_operation_time > analyzed_at
    end

    def analysis_status
      return "not_analyzed" unless analyzed?
      return "needs_update" if needs_reanalysis?
      "current"
    end

    def issues_by_severity
      return {} unless analyzed? && issues.present?

      issues.group_by { |issue| issue["severity"] || "unknown" }
    end

    def critical_issues_count
      issues_by_severity["critical"]&.count || 0
    end

    def warning_issues_count
      issues_by_severity["warning"]&.count || 0
    end

    def to_breadcrumb
      normalized_sql.to_s.truncate(60)
    end

    def to_s
      id
    end

    def generate_hashed_sql
      require "digest"
      self.hashed_sql = Digest::MD5.hexdigest(normalized_sql)
    end
  end
end
