module RailsPulse
  class DashboardController < ApplicationController
    include TimeRangeConcern
    include DeploymentMarkersConcern

    def index
      # Use TimeRangeConcern to get time range (supports time range selector + all other filters)
      @start_time, @end_time, @selected_time_range, @time_diff = setup_time_range
      populate_deployment_markers

      # Rounded rather than truncated, so a range a few seconds short of N
      # whole days still counts as N. Cards/charts also get @start_time/
      # @end_time directly so they bucket the exact range, not "the last
      # @period days ending now".
      @period = RailsPulse::TimeWindow.new(@start_time, @end_time).days

      # Determine period type based on time range
      # If 24 hours or less, use hourly summaries, otherwise use daily
      @period_type = @period <= 1 ? "hour" : "day"

      # Get tag filter values from session
      disabled_tags = session_disabled_tags
      show_non_tagged = session[:show_non_tagged] != false

      card_and_chart_options = {
        disabled_tags: disabled_tags, show_non_tagged: show_non_tagged,
        period: @period, period_type: @period_type,
        start_time: @start_time, end_time: @end_time
      }

      @percentile_response_times_metric_card = RailsPulse::Routes::Cards::PercentileResponseTimes.new(route: nil, **card_and_chart_options).to_metric_card
      @request_count_totals_metric_card = RailsPulse::Routes::Cards::RequestCountTotals.new(route: nil, **card_and_chart_options).to_metric_card
      @error_rates_metric_card = RailsPulse::Routes::Cards::ErrorRates.new(route: nil, **card_and_chart_options).to_metric_card
      @job_failure_rate_metric_card = RailsPulse::Jobs::Cards::FailureRate.new(**card_and_chart_options).to_metric_card if RailsPulse.configuration.track_jobs

      # Generate chart data for inline rendering
      @response_time_percentiles_chart_data = RailsPulse::Dashboard::Charts::ResponseTimePercentiles.new(**card_and_chart_options).to_chart_data
      @throughput_and_errors_chart_data = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(**card_and_chart_options).to_chart_data

      # Needs Attention panel
      @needs_attention = RailsPulse::Dashboard::NeedsAttention.new(disabled_tags: disabled_tags, show_non_tagged: show_non_tagged, period: @period, start_time: @start_time, end_time: @end_time).to_attention_data

      # System Health bar
      @health_summary = RailsPulse::Dashboard::HealthSummary.new(disabled_tags: disabled_tags, show_non_tagged: show_non_tagged, period: @period, start_time: @start_time, end_time: @end_time).to_health_data

      @storage_status = RailsPulse::Dashboard::StorageStatus.new(cached_sizes: true)

      # Deployments panel — scoped to the same window as the chart markers so
      # the panel and the markers drawn on the charts always agree.
      deployments_in_range = RailsPulse::Deployment.for_range(Time.zone.at(@start_time), Time.zone.at(@end_time))
      @deployment_count = deployments_in_range.count
      @recent_deployments = deployments_in_range.recent.limit(4)
      @last_deployment = RailsPulse::Deployment.recent.first
    end
  end
end
