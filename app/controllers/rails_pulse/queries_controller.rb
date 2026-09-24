module RailsPulse
  class QueriesController < ApplicationController
    include ChartTableConcern
    include TagFilterConcern
    include MetricCardConcern

    before_action :set_query, only: [ :show, :reanalyze ]

    def index
      setup_metric_cards
      setup_chart_and_table_data
    end

    def show
      setup_metric_cards
      setup_chart_and_table_data
      @all_query_operations = @query.recent_operations
      @n_plus_one_groups = @query.n_plus_one_groups(@all_query_operations)
      @query.ensure_analyzed!
    end

    def reanalyze
      @query.update_columns(analyzed_at: nil, explain_plan: nil)
      redirect_to query_path(@query)
    end

    # Override to generate database load chart with custom parameters
    def setup_chart_data(ransack_params)
      super

      # Database load chart doesn't use ransack_query, so generate it separately
      @database_load_chart_data = Queries::Charts::DatabaseLoad.new(
        window: @time_range&.window,
        period_type: period_type,
        disabled_tags: session_disabled_tags,
        show_non_tagged: session[:show_non_tagged] != false
      ).to_chart_data
    end

    private

    # Metric card configuration
    def metric_card_definitions
      {
        percentile_query_times_metric_card: Queries::Cards::PercentileQueryTimes,
        execution_rate_metric_card: Queries::Cards::ExecutionRate
      }
    end

    # Override to handle database_load card which has different params
    def setup_metric_cards
      super
      return if partial_request?

      # Database load card only shows on index page and doesn't accept query param
      if current_resource.nil?
        window = @time_range&.window
        period_days = window ? ((window.end_time - window.start_time) / 1.day).round : 7

        @database_load_metric_card = Queries::Cards::DatabaseLoad.new(
          disabled_tags: session_disabled_tags,
          show_non_tagged: session[:show_non_tagged] != false,
          period: period_days,
          period_type: period_type.to_s
        ).to_metric_card
      end
    end

    # The parameter name for passing the resource to metric cards
    def resource_key
      :query
    end

    # Chart configuration
    def chart_definitions
      {
        query_performance_chart_data: Queries::Charts::QueryPerformance,
        execution_volume_chart_data: Queries::Charts::ExecutionVolume
      }
    end

    def chart_model
      Summary
    end

    def table_model
      Summary
    end

    # Pass the query to chart classes on show pages
    def chart_options
      show_action? ? { subject: @query } : {}
    end

    # Queries use polymorphic summaries, so we need to filter by type
    def summarizable_type
      "RailsPulse::Query"
    end

    # Filter to scope table results to a specific query on show pages
    def show_resource_filter
      { summarizable_id_eq: @query.id, summarizable_type_eq: "RailsPulse::Query" }
    end

    # Returns the current query for metric cards and chart params
    def current_resource
      @query
    end

    def default_time_range_key
      :last_7_days
    end

    def default_table_sort
      "period_start desc"
    end

    def duration_range_type = :query

    # Queries::Tables::Index handles index-page sorting; only apply ransack sort on show.
    def apply_ransack_sort? = show_action?

    def build_table_results
      if show_action?
        # For Summary model on show page - ransack params already include query ID and type filters
        # Summaries aren't taggable, so we don't apply tag filters here
        @ransack_query.result.where(period_type: period_type)
      else
        Queries::Tables::Index.new(
          ransack_query: @ransack_query,
          period_type: period_type,
          params: params,
          disabled_tags: session_disabled_tags,
          show_non_tagged: session[:show_non_tagged] != false
        ).to_table
      end
    end

    def set_query
      @query = Query.find(params[:id])
    end
  end
end
