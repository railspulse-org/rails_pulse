# ChartTableConcern
#
# Core concern for controllers that display both charts and tables (routes, requests, queries, jobs).
# Orchestrates time range setup, chart generation, table queries, and zoom/filter handling.
#
# Controllers including this concern must implement:
# - chart_model, table_model, chart_definitions, default_table_sort, build_table_results
module ChartTableConcern
  extend ActiveSupport::Concern

  # Valid period types for summary data - constrained to prevent SQL injection
  VALID_PERIOD_TYPES = %w[hour day].freeze

  included do
    include RansackParamsConcern
    include DeploymentMarkersConcern

    before_action :setup_page_timings
    before_action :populate_deployment_markers
  end

  private

  # Hook: override to change the default time range (e.g. :last_7_days).
  def default_time_range_key = :last_24_hours

  def setup_page_timings
    @time_range = RailsPulse::TimeRange.resolve(
      params: params,
      session: session,
      default_key: default_time_range_key,
      duration_range_type: duration_range_type
    )
  end

  def setup_chart_and_table_data
    ransack_params = self.ransack_params

    unless partial_request?
      # Setup chart data first using original time range (no sorting from table)
      setup_chart_data(ransack_params)
      @has_chart_data = meaningful_chart_data?
    end

    # Setup table data using zoom parameters if present, otherwise use chart parameters
    setup_table_data(ransack_params)

    # Set flag to determine if we have meaningful data to display
    @has_data = has_meaningful_data?
  end

  # Sets up chart data for all chart types defined by the controller.
  # Generates multiple chart instances and stores them in instance variables.
  # Controllers override `chart_definitions` to specify which charts to render.
  def setup_chart_data(ransack_params)
    chart_ransack_params = build_chart_ransack_params(ransack_params)
    chart_ransack_query = chart_model.ransack(chart_ransack_params)

    common_options = {
      ransack_query: chart_ransack_query,
      period_type: period_type,
      window: @time_range&.window,
      start_duration: @time_range&.start_duration,
      disabled_tags: session_disabled_tags,
      show_non_tagged: session[:show_non_tagged] != false,
      **chart_options
    }

    # Generate all chart types defined by the controller
    chart_definitions.each do |ivar_name, chart_class|
      instance_variable_set(
        "@#{ivar_name}",
        chart_class.new(**common_options).to_chart_data
      )
    end

    # Backward compatibility: first chart becomes @chart_data
    @chart_data = instance_variable_get("@#{chart_definitions.keys.first}") if chart_definitions.any?
  end

  def setup_table_data(ransack_params)
    table_ransack_params = build_table_ransack_params(ransack_params)
    @ransack_query = table_model.ransack(table_ransack_params)
    @ransack_query.sorts = default_table_sort if @ransack_query.sorts.empty? && apply_ransack_sort?

    table_results = build_table_results
    handle_pagination

    @pagination, @table_data = paginate(table_results, limit: session_pagination_limit)
  end

  def period_type
    @time_range&.period_type || "day"
  end

  def meaningful_chart_data?
    return false unless @chart_data.is_a?(Hash) && @chart_data.key?(:series)

    @chart_data[:series].any? { |series|
      !series[:name].to_s.include?(" SLO ") &&
        series[:data].any? { |v| !chart_data_value(v).nil? }
    }
  end

  def has_meaningful_data?
    has_chart_data = if @chart_data.is_a?(Hash) && @chart_data.key?(:series)
      # Multi-series chart format — exclude SLO series (always has positive threshold values)
      # Supports both plain values and [timestamp_ms, value] pairs
      @chart_data[:series].any? { |series|
        !series[:name].to_s.include?(" SLO ") && series[:data].any? { |v| chart_data_value(v).to_f > 0 }
      }
    elsif @chart_data.is_a?(Hash)
      # Old simple hash format (bar charts)
      @chart_data.values.any? { |v| v.is_a?(Numeric) && v > 0 }
    else
      false
    end
    has_table_data = @table_data && @table_data.any?
    has_chart_data || has_table_data
  end

  # Extracts the numeric value from a data point.
  # Handles plain values, [timestamp_ms, value] pairs, and { value: [timestamp_ms, value] } objects.
  def chart_data_value(v)
    return v[1] if v.is_a?(Array)
    return v[:value][1] if v.is_a?(Hash) && v[:value].is_a?(Array)

    v
  end

  def handle_pagination
    set_pagination_limit(params[:limit]) if params[:limit].present?
  end

  # Helper method to determine if we're on a show action
  def show_action?
    action_name == "show"
  end

  # Hook: override to return param keys that should be excluded from chart queries.
  # Use this when a filter requires a JOIN that chart queries don't perform
  # (e.g. route path/action filters that need rails_pulse_routes joined).
  def chart_filter_exclusions
    []
  end

  # Builds ransack parameters for chart queries
  # Common pattern: time range + optional duration filter + resource scope
  def build_chart_ransack_params(ransack_params)
    base_params = ransack_params.except(:s, *chart_filter_exclusions)

    if @time_range&.window
      base_params.merge!(
        period_start_gteq: @time_range.window.start_time,
        period_start_lt: @time_range.window.end_time
      )
    end

    # Add summarizable_type filter for polymorphic associations (queries, jobs)
    base_params.merge!(summarizable_type_eq: summarizable_type) if summarizable_type

    # Only add duration filter if we have a meaningful threshold
    if @time_range&.start_duration && @time_range.start_duration > 0
      base_params[:avg_duration_gteq] = @time_range.start_duration
    end

    # Scope to specific resource on show pages
    if show_action?
      base_params.merge(resource_id_scope)
    else
      base_params
    end
  end

  # Builds ransack parameters for table queries
  # Different logic for index (summaries) vs show (individual records)
  def build_table_ransack_params(ransack_params)
    if show_action?
      build_show_table_ransack_params(ransack_params)
    else
      build_index_table_ransack_params(ransack_params)
    end
  end

  # Builds table params for show pages (individual records like Request, JobRun)
  def build_show_table_ransack_params(ransack_params)
    params = ransack_params.dup

    if @time_range&.table_window
      params.merge!(
        occurred_at_gteq: @time_range.table_window.start_time,
        occurred_at_lt: @time_range.table_window.end_time
      )
    end

    params.merge!(show_resource_filter)
    if @time_range&.start_duration && @time_range.start_duration > 0
      params[:duration_gteq] = @time_range.start_duration
    end
    params
  end

  # Builds table params for index pages (summary records)
  def build_index_table_ransack_params(ransack_params)
    params = ransack_params.dup

    if @time_range&.table_window
      params.merge!(
        period_start_gteq: @time_range.table_window.start_time,
        period_start_lt: @time_range.table_window.end_time
      )
    end

    params.merge!(summarizable_type_eq: summarizable_type) if summarizable_type
    if @time_range&.start_duration && @time_range.start_duration > 0
      params[:avg_duration_gteq] = @time_range.start_duration
    end
    params
  end

  # Hook: override to change the threshold type passed to setup_duration_range.
  # Return :query for query controllers, :job for job controllers, etc.
  def duration_range_type = :route

  # Hook: override to return false when the table's own query handles sorting
  # (e.g. index pages that delegate to a Tables::Index class).
  def apply_ransack_sort? = true

  # Abstract methods - must be implemented by including controllers

  # Returns the ActiveRecord model used for chart queries (usually Summary)
  def chart_model
    raise NotImplementedError, "#{self.class} must implement #chart_model"
  end

  # Returns the ActiveRecord model used for table queries (varies by action)
  def table_model
    raise NotImplementedError, "#{self.class} must implement #table_model"
  end

  # Returns a hash of { instance_variable_name: ChartClass }
  # Example: { response_time_chart_data: Routes::Charts::ResponseTime }
  def chart_definitions
    raise NotImplementedError, "#{self.class} must implement #chart_definitions"
  end

  # Returns options passed to chart classes (e.g., { subject: @route })
  def chart_options
    {}
  end

  # Returns the default sort order for tables
  def default_table_sort
    raise NotImplementedError, "#{self.class} must implement #default_table_sort"
  end

  # Returns the table query results (may include joins, filters, etc.)
  def build_table_results
    raise NotImplementedError, "#{self.class} must implement #build_table_results"
  end

  # Returns the summarizable_type for polymorphic associations (nil for routes)
  def summarizable_type
    nil
  end

  # Returns the ransack filter for scoping to a specific resource on show pages
  # Example: { route_id_eq: @route.id }
  def show_resource_filter
    raise NotImplementedError, "#{self.class} must implement #show_resource_filter" if show_action?
  end

  # Override in show actions to return the current resource (e.g., @route, @query)
  def current_resource
    nil
  end

  # Ransack scope for chart summaries on show pages. Override to customize (e.g. IN queries).
  def resource_id_scope
    { summarizable_id_eq: current_resource.id }
  end
end
