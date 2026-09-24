module RailsPulse
  class RequestsController < ApplicationController
    include ChartTableConcern
    include TagFilterConcern

    before_action :set_request, only: :show

    def index
      setup_chart_and_table_data
    end

    def show
      @operation_timeline = RailsPulse::Charts::OperationsChart.new(@request.operations)
    end

    private


    def chart_model
      RailsPulse::Summary
    end

    def table_model
      RailsPulse::Request
    end

    # Chart configuration - requests page doesn't display charts
    def chart_definitions
      {}
    end

    def chart_options
      {}
    end

    # Requests use polymorphic summaries with type "RailsPulse::Request"
    def summarizable_type
      "RailsPulse::Request"
    end

    # Override: Requests aggregate all request data (summarizable_id: 0)
    # rather than scoping to a specific resource
    def build_chart_ransack_params(ransack_params)
      base_params = ransack_params.except(:s).merge(
        summarizable_type_eq: "RailsPulse::Request",
        summarizable_id_eq: 0
      )

      if @time_range&.window
        base_params.merge!(
          period_start_gteq: @time_range.window.start_time,
          period_start_lt: @time_range.window.end_time
        )
      end

      # Only add duration filter if we have a meaningful threshold
      if @time_range&.start_duration && @time_range.start_duration > 0
        base_params[:avg_duration_gteq] = @time_range.start_duration
      end
      base_params
    end

    # Override: Requests support "recent" mode (no time filtering)
    def build_table_ransack_params(ransack_params)
      params = ransack_params.dup

      # Handle time mode - check if recent mode is selected
      time_mode = params[:period_start_range] || "recent"

      if time_mode != "recent" && @time_range&.table_window
        # Custom mode - apply time filters
        params.merge!(
          occurred_at_gteq: @time_range.table_window.start_time,
          occurred_at_lt: @time_range.table_window.end_time
        )
      end
      # else: Recent mode - no time filters, just rely on sort + pagination

      start_duration = @time_range&.start_duration
      # Duration filter - convert symbol to numeric threshold or use start_duration
      if params[:duration_gteq].present?
        # If it's a symbol like :slow, convert it to the numeric threshold
        if params[:duration_gteq].to_s.in?(%w[slow very_slow critical])
          params[:duration_gteq] = start_duration
        end
        # else: it's already a number, keep it as is
      elsif start_duration && start_duration > 0
        # No duration_gteq param, use start_duration from @time_range
        params[:duration_gteq] = start_duration
      end

      # Min response size filter - input is in KB, convert to bytes for the column
      min_size_kb = self.params[:min_size_kb].to_i
      if min_size_kb > 0
        params[:response_size_bytes_gteq] = min_size_kb * 1024
      end

      params
    end

    def default_table_sort
      "occurred_at desc"
    end

    # Requests index shows individual request records, not aggregated summaries
    # This differs from Routes/Queries which use Tables::Index for aggregation
    # Individual records allow displaying per-request details (tags, occurred_at, etc.)
    def build_table_results
      base_query = apply_tag_filters(@ransack_query.result.includes(:route))

      # If filtering or sorting by route_path, we need to join the routes table
      needs_join = @ransack_query.sorts.any? { |sort| sort.name == "route_path" } ||
                   ransack_params[:route_path_cont].present?

      if needs_join
        base_query = base_query.joins(:route)
      end

      base_query
    end

    def set_request
      @request = Request.includes(operations: :query).find(params[:id])
    end
  end
end
