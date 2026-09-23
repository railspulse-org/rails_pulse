module RailsPulse
  class JobsController < ApplicationController
    include ChartTableConcern
    include TagFilterConcern
    include MetricCardConcern

    before_action :set_job, only: :show

    def index
      setup_metric_cards
      setup_chart_and_table_data

      @available_queues = RailsPulse::Job.distinct.pluck(:queue_name).compact.sort
    end

    def show
      setup_metric_cards
      setup_chart_and_table_data
    end

    private

    def set_job
      @job = RailsPulse::Job.find(params[:id])
    end

    # Metric card configuration
    def metric_card_definitions
      {
        total_runs_metric_card: Jobs::Cards::TotalRuns,
        failure_rate_metric_card: Jobs::Cards::FailureRate,
        p95_duration_metric_card: Jobs::Cards::P95Duration
      }
    end

    # The parameter name for passing the resource to metric cards
    def resource_key
      :job
    end

    # Chart configuration
    def chart_definitions
      {
        duration_chart_data: Jobs::Charts::Duration,
        execution_volume_chart_data: Jobs::Charts::ExecutionVolume,
        failure_rate_chart_data: Jobs::Charts::FailureRate
      }
    end

    def chart_model
      Summary
    end

    def table_model
      show_action? ? JobRun : Summary
    end

    # Pass the job to chart classes on show pages
    def chart_options
      show_action? ? { subject: @job } : {}
    end

    # Jobs use polymorphic summaries, so we need to filter by type
    def summarizable_type
      "RailsPulse::Job"
    end

    # Filter to scope table results to a specific job on show pages
    def show_resource_filter
      { job_id_eq: @job.id }
    end

    # Returns the current job for metric cards and chart params
    def current_resource
      @job
    end

    def default_table_sort
      show_action? ? "occurred_at desc" : "count_sort desc"
    end

    def build_table_results
      if show_action?
        # For show action, query JobRun directly but join to summaries for consistency
        # Use sanitize_sql_array to safely parameterize period_type
        join_sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL,
            INNER JOIN rails_pulse_summaries ON
              rails_pulse_summaries.summarizable_id = rails_pulse_job_runs.job_id AND
              rails_pulse_summaries.summarizable_type = 'RailsPulse::Job' AND
              rails_pulse_summaries.period_type = ? AND
              rails_pulse_job_runs.occurred_at >= rails_pulse_summaries.period_start AND
              rails_pulse_job_runs.occurred_at < rails_pulse_summaries.period_end
          SQL
          period_type
        ])

        base_query = @ransack_query.result.joins(join_sql)
        base_query.distinct
      else
        # For index action, use aggregated summaries
        Jobs::Tables::Index.new(
          ransack_query: @ransack_query,
          period_type: period_type,
          params: params,
          disabled_tags: session_disabled_tags,
          show_non_tagged: session[:show_non_tagged] != false,
          queue_name: params[:queue_name]
        ).to_table
      end
    end

    def default_time_range_key
      :last_7_days
    end
  end
end
