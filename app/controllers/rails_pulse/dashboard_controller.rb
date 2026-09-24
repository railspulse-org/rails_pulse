module RailsPulse
  class DashboardController < ApplicationController
    include DeploymentMarkersConcern

    def index
      @time_range = RailsPulse::TimeRange.resolve(
        params: params, session: session, default_key: default_time_range_key
      )
      populate_deployment_markers

      window = @time_range.window
      period = window.days
      period_type = @time_range.period_type

      # Get tag filter values from session
      disabled_tags = session_disabled_tags
      show_non_tagged = session[:show_non_tagged] != false

      card_and_chart_options = {
        disabled_tags: disabled_tags, show_non_tagged: show_non_tagged,
        period: period, period_type: period_type,
        window: window
      }

      @percentile_response_times_metric_card = RailsPulse::Routes::Cards::PercentileResponseTimes.new(**card_and_chart_options).to_metric_card
      @request_count_totals_metric_card = RailsPulse::Routes::Cards::RequestCountTotals.new(**card_and_chart_options).to_metric_card
      @error_rates_metric_card = RailsPulse::Routes::Cards::ErrorRates.new(**card_and_chart_options).to_metric_card
      @job_failure_rate_metric_card = RailsPulse::Jobs::Cards::FailureRate.new(**card_and_chart_options).to_metric_card if RailsPulse.configuration.track_jobs

      # Generate chart data for inline rendering
      @response_time_percentiles_chart_data = RailsPulse::Dashboard::Charts::ResponseTimePercentiles.new(**card_and_chart_options).to_chart_data
      @throughput_and_errors_chart_data = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(**card_and_chart_options).to_chart_data

      # Needs Attention panel
      @needs_attention = RailsPulse::Dashboard::NeedsAttention.new(disabled_tags: disabled_tags, show_non_tagged: show_non_tagged, period: period, window: window).to_attention_data

      # System Health bar
      @health_summary = RailsPulse::Dashboard::HealthSummary.new(disabled_tags: disabled_tags, show_non_tagged: show_non_tagged, period: period, window: window).to_health_data

      @storage_status = RailsPulse::Dashboard::StorageStatus.new(cached_sizes: true)

      # Deployments panel — scoped to the same window as the chart markers so
      # the panel and the markers drawn on the charts always agree.
      deployments_in_range = RailsPulse::Deployment.for_range(window.start_time, window.end_time)
      @deployment_count = deployments_in_range.count
      @recent_deployments = deployments_in_range.recent.limit(4)
      @last_deployment = RailsPulse::Deployment.recent.first
    end

    private

    def default_time_range_key
      :last_24_hours
    end
  end
end
