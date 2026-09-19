module RailsPulse
  class Summary < RailsPulse::ApplicationRecord
    self.table_name = "rails_pulse_summaries"

    PERIOD_TYPES = %w[hour day week month].freeze

    # Polymorphic association
    belongs_to :summarizable, polymorphic: true, optional: true  # Optional for Request summaries

    # Convenience associations for easier querying
    belongs_to :route, -> { where(rails_pulse_summaries: { summarizable_type: "RailsPulse::Route" }) },
               foreign_key: "summarizable_id", class_name: "RailsPulse::Route", optional: true
    belongs_to :query, -> { where(rails_pulse_summaries: { summarizable_type: "RailsPulse::Query" }) },
               foreign_key: "summarizable_id", class_name: "RailsPulse::Query", optional: true
    belongs_to :job,
               -> { where(rails_pulse_summaries: { summarizable_type: "RailsPulse::Job" }) },
               foreign_key: "summarizable_id", class_name: "RailsPulse::Job", optional: true

    # Validations
    validates :period_type, inclusion: { in: PERIOD_TYPES }
    validates :period_start, presence: true
    validates :period_end, presence: true

    # Scopes
    scope :for_period_type, ->(type) { where(period_type: type) }
    scope :for_date_range, ->(start_date, end_date) {
      where(period_start: start_date..end_date)
    }
    scope :for_requests, -> { where(summarizable_type: "RailsPulse::Request") }
    scope :for_routes, -> { where(summarizable_type: "RailsPulse::Route") }
    scope :for_queries, -> { where(summarizable_type: "RailsPulse::Query") }
    scope :for_jobs, -> { where(summarizable_type: "RailsPulse::Job") }
    scope :for_exceptions, -> { where(summarizable_type: "RailsPulse::ExceptionGroup") }

    # Frequency across every exception group, written alongside the per-group
    # rows so a chart of total exception volume is one query rather than one
    # per group.
    scope :overall_exceptions, -> {
      where(summarizable_type: "RailsPulse::ExceptionGroup", summarizable_id: 0)
    }
    scope :by_job_name, ->(job_name) { for_jobs.joins(:job).where(rails_pulse_jobs: { name: job_name }) }
    scope :recent, -> { order(period_start: :desc) }

    # Special scope for overall request summaries
    scope :overall_requests, -> {
      where(summarizable_type: "RailsPulse::Request", summarizable_id: 0)
    }

    # Tag filtering scope for charts and metrics
    # Filters summaries based on disabled tags in the underlying route/query/job
    scope :with_tag_filters, ->(disabled_tags = [], show_non_tagged = true) {
      # Separate "non_tagged" from actual tags (it's a virtual tag)
      actual_disabled_tags = (disabled_tags || []).reject { |tag| tag == "non_tagged" }

      # Return early if no filters are applied
      return all if actual_disabled_tags.empty? && show_non_tagged

      # One subquery per summarizable kind. This scope runs on every card and
      # chart query, so the alternative (plucking every matching route, query
      # and job id and inlining the lists) cost three extra statements per
      # call and grew each statement with the size of the tables.
      table = arel_table
      keep_for = lambda do |type, model|
        matching = TagFilterService.scope(model, actual_disabled_tags, show_non_tagged).select(:id).arel
        table[:summarizable_type].eq(type).and(table[:summarizable_id].in(matching))
      end

      where(
        keep_for.call("RailsPulse::Route", Route)
          .or(keep_for.call("RailsPulse::Query", Query))
          .or(keep_for.call("RailsPulse::Job", Job))
          .or(table[:summarizable_type].in([ "RailsPulse::Request", "RailsPulse::ExceptionGroup" ]))
      )
    }

    # Ransack configuration
    def self.ransackable_attributes(auth_object = nil)
      %w[
        period_start period_end avg_duration min_duration max_duration p95_duration p99_duration
        count error_count requests_per_minute error_rate_percentage
        route_path route_controller_action route_methods_sort
        execution_count total_time_consumed normalized_sql
        summarizable_id summarizable_type
      ]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[route query job]
    end

    # Note: Basic fields like count, avg_duration, min_duration, max_duration
    # are handled automatically by Ransack using actual database columns

    # Custom ransackers for calculated fields only
    ransacker :requests_per_minute do
      Arel.sql("rails_pulse_summaries.count / 60.0")
    end

    ransacker :error_rate_percentage do
      Arel.sql("(rails_pulse_summaries.error_count * 100.0) / rails_pulse_summaries.count")
    end


    # Ransacker for route path sorting (when joined with routes table)
    ransacker :route_path do
      Arel.sql("rails_pulse_routes.path")
    end

    # Ransacker for controller_action sorting (when joined with routes table)
    ransacker :route_controller_action do
      Arel.sql("rails_pulse_routes.controller_action")
    end

    # Placeholder ransacker for method aggregation sorting; actual ORDER BY is
    # applied by Routes::Tables::Index#named_sort using http_methods.
    ransacker :route_methods_sort do
      Arel.sql("rails_pulse_routes.http_methods")
    end

    # Sorting-specific ransackers for GROUP BY compatibility (used only in ORDER BY)
    # These use different names to avoid conflicts with filtering
    ransacker :avg_duration_sort do
      Arel.sql("AVG(rails_pulse_summaries.avg_duration)")
    end

    ransacker :max_duration_sort do
      Arel.sql("MAX(rails_pulse_summaries.max_duration)")
    end

    ransacker :p95_duration_sort do
      Arel.sql("SUM(rails_pulse_summaries.p95_duration * rails_pulse_summaries.count) / NULLIF(SUM(rails_pulse_summaries.count), 0)")
    end

    ransacker :p99_duration_sort do
      Arel.sql("SUM(rails_pulse_summaries.p99_duration * rails_pulse_summaries.count) / NULLIF(SUM(rails_pulse_summaries.count), 0)")
    end

    ransacker :count_sort do
      Arel.sql("SUM(rails_pulse_summaries.count)")
    end

    ransacker :error_count_sort do
      Arel.sql("SUM(rails_pulse_summaries.error_count)")
    end

    ransacker :success_count_sort do
      Arel.sql("SUM(rails_pulse_summaries.success_count)")
    end

    ransacker :total_time_consumed_sort do
      Arel.sql("SUM(rails_pulse_summaries.count * rails_pulse_summaries.avg_duration)")
    end

    # Alias execution_count_sort to count_sort for queries table compatibility
    ransacker :execution_count_sort do
      Arel.sql("SUM(rails_pulse_summaries.count)")
    end

    # Ransackers for queries table calculated fields
    ransacker :execution_count do
      Arel.sql("SUM(rails_pulse_summaries.count)")  # Total executions
    end

    ransacker :total_time_consumed do
      Arel.sql("SUM(rails_pulse_summaries.count * rails_pulse_summaries.avg_duration)")  # Total time consumed
    end

    # Ransacker for query SQL sorting (when joined with queries table)
    ransacker :normalized_sql do
      Arel.sql("rails_pulse_queries.normalized_sql")
    end

    class << self
      def calculate_period_end(period_type, start_time)
        case period_type
        when "hour"  then start_time.end_of_hour
        when "day"   then start_time.end_of_day
        when "week"  then start_time.end_of_week
        when "month" then start_time.end_of_month
        end
      end

      def normalize_period_start(period_type, time)
        case period_type
        when "hour"  then time.beginning_of_hour
        when "day"   then time.beginning_of_day
        when "week"  then time.beginning_of_week
        when "month" then time.beginning_of_month
        end
      end
    end
  end
end
