module RailsPulse
  class RoutesController < ApplicationController
    include ChartTableConcern
    include TagFilterConcern
    include MetricCardConcern

    before_action :set_route, only: :show

    def index
      setup_metric_cards
      setup_chart_and_table_data
    end

    def show
      setup_metric_cards
      setup_chart_and_table_data
      setup_archived_summary_data
    end

    private

    # Metric card configuration - defines which cards to display
    def metric_card_definitions
      {
        percentile_response_times_metric_card: Routes::Cards::PercentileResponseTimes,
        request_count_totals_metric_card: Routes::Cards::RequestCountTotals,
        error_rates_metric_card: Routes::Cards::ErrorRates
      }
    end

    # The parameter name for passing the resource to metric cards
    def resource_key
      :route
    end

    # Chart configuration - defines which charts to render
    def chart_definitions
      {
        response_time_chart_data: Routes::Charts::ResponseTimePercentiles,
        request_rate_chart_data: Routes::Charts::RequestVolume,
        error_rate_chart_data: Routes::Charts::ErrorRate
      }
    end

    def chart_model
      Summary
    end

    def table_model
      show_action? ? Request : Summary
    end

    # Pass the route to chart classes on show pages
    def chart_options
      show_action? ? { route: @route } : {}
    end

    def show_resource_filter
      { route_id_eq: @route.id }
    end

    # Returns the current route for metric cards and chart params
    def current_resource
      @route
    end

    def default_table_sort
      show_action? ? "occurred_at desc" : "p95_duration desc"
    end

    def build_table_results
      if show_action?
        # Only show requests that belong to time periods where we have route summaries
        # This ensures the table data is consistent with the chart data
        # Note: We don't apply tag filters here because we want to show all requests
        # for this specific route, regardless of individual request tags

        # Use sanitize_sql_array to safely parameterize period_type
        join_sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL,
            INNER JOIN rails_pulse_summaries ON
              rails_pulse_summaries.summarizable_id = rails_pulse_requests.route_id AND
              rails_pulse_summaries.summarizable_type = 'RailsPulse::Route' AND
              rails_pulse_summaries.period_type = ? AND
              rails_pulse_requests.occurred_at >= rails_pulse_summaries.period_start AND
              rails_pulse_requests.occurred_at < rails_pulse_summaries.period_end
          SQL
          period_type
        ])

        base_query = @ransack_query.result.joins(join_sql)

        # For PostgreSQL compatibility with DISTINCT + ORDER BY
        # we need to include computed columns in SELECT when ordering by them
        base_query = base_query.joins(:route).preload(:route)

        if ordering_by_computed_column?
          base_query.select("rails_pulse_requests.*, #{status_indicator_sql} as status_indicator_value").distinct
        else
          base_query.distinct
        end
      else
        Routes::Tables::Index.new(
          ransack_query: @ransack_query,
          period_type: period_type,
          start_time: @start_time,
          params: params,
          disabled_tags: session_disabled_tags,
          show_non_tagged: session[:show_non_tagged] != false
        ).to_table
      end
    end

    # Request/route-name filters that Summary chart queries don't join for.
    def chart_filter_exclusions
      %w[route_path_cont route_controller_action_cont controller_action_cont http_method_eq]
    end

    def default_time_range_key
      :last_14_days
    end

    # Routes::Tables::Index handles index-page sorting; only apply ransack sort on show.
    def apply_ransack_sort? = show_action?

    def set_route
      @route = Route.find(params[:id])
    end

    # Raw Request rows get purged by CleanupService after full_retention_period.
    # For any part of the selected window older than that cutoff, fall back to
    # pre-aggregated Summary rows (which CleanupService never deletes for
    # day/week/month periods) so the table isn't just blank for old ranges.
    def setup_archived_summary_data
      cutoff = retention_cutoff
      window_start = @page_timings&.table_start_time

      if cutoff && window_start && Time.at(window_start) < cutoff
        scope = Summary.for_routes
          .where(summarizable_id: @route.id)
          .where(period_type: period_type)
          .where("period_start < ?", cutoff)

        if @page_timings&.table_end_time
          scope = scope.where("period_start < ?", Time.at(@page_timings.table_end_time))
        end

        @archived_summary_data = scope.order(period_start: :desc).limit(100)
      else
        @archived_summary_data = Summary.none
      end
    end

    def retention_cutoff
      config = RailsPulse.configuration rescue nil
      period = config&.full_retention_period
      period ? period.ago : nil
    end

    def ordering_by_computed_column?
      # Check if we're ordering by status_indicator (computed column)
      @ransack_query.sorts.any? { |sort| sort.name == "status_indicator" }
    end

    def status_indicator_sql
      # Same logic as in the Request model's ransacker
      # Use sanitize_sql_array to safely parameterize threshold values
      config = RailsPulse.configuration rescue nil
      thresholds = config&.request_thresholds || { slow: 500, very_slow: 1000, critical: 2000 }
      slow = thresholds[:slow] || 500
      very_slow = thresholds[:very_slow] || 1000
      critical = thresholds[:critical] || 2000

      ActiveRecord::Base.sanitize_sql_array([
        "CASE
          WHEN rails_pulse_requests.duration < ? THEN 0
          WHEN rails_pulse_requests.duration < ? THEN 1
          WHEN rails_pulse_requests.duration < ? THEN 2
          ELSE 3
        END",
        slow,
        very_slow,
        critical
      ])
    end
  end
end
