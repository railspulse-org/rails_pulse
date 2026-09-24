module RailsPulse
  class ExceptionsController < ApplicationController
    include RansackParamsConcern
    include TagFilterConcern
    include DeploymentMarkersConcern

    before_action :set_exception_group, only: %i[show update]

    def index
      ransack_params = self.ransack_params.dup
      apply_default_status_filter!(ransack_params)

      @ransack_query = ExceptionGroup.ransack(ransack_params)
      @ransack_query.sorts = "last_seen_at desc" if @ransack_query.sorts.empty?
      @pagination, @table_data = paginate(@ransack_query.result, limit: session_pagination_limit)

      setup_frequency_view
    end

    def show
      occurrences = @exception_group.occurrences.order(occurred_at: :desc)
      @latest_occurrence = occurrences.first
      @pagination, @occurrences = paginate(occurrences, limit: session_pagination_limit)
    end

    def update
      if params.key?(:preserve)
        update_preserve
      else
        update_status
      end
    end

    private

    # The index is a list of groups, not an aggregate table, so it does not use
    # ChartTableConcern. It still needs a time range and a frequency series:
    # without them the page can say what is failing but not whether it is
    # getting worse, which is the question users actually arrive with.
    def setup_frequency_view
      @time_range = RailsPulse::TimeRange.resolve(
        params: params, session: session, default_key: default_time_range_key
      )

      period_days = window_days_for(@time_range.selected_time_range, @time_range.window)

      populate_deployment_markers

      @occurrence_volume_chart = Exceptions::Charts::OccurrenceVolume.new(
        window: @time_range.window,
        period_type: @time_range.period_type
      ).to_chart_data

      card_params = { period: period_days, period_type: @time_range.period_type }

      @total_occurrences_metric_card = Exceptions::Cards::TotalOccurrences.new(**card_params).to_metric_card
      @exception_rate_metric_card    = Exceptions::Cards::ExceptionRate.new(**card_params).to_metric_card
      @open_groups_metric_card       = Exceptions::Cards::OpenGroups.new(**card_params).to_metric_card
    end

    def set_exception_group
      @exception_group = ExceptionGroup.find(params[:id])
    end

    # The card copy ("compared to previous N days") has to name the range the
    # user picked. Measuring the span instead reads one day long, because the
    # range runs from the start of the first day to the end of the last.
    def window_days_for(selected_range, window)
      case selected_range.to_s
      when "last_24_hours" then 1
      when "last_7_days"   then 7
      when "last_14_days"  then 14
      when "last_30_days"  then 30
      else window.days
      end
    end

    # Exceptions are low-volume compared with requests, so a day is rarely
    # enough to see a trend. Matches the jobs and queries defaults.
    def default_time_range_key
      :last_7_days
    end

    # Default the list to open groups. An explicit blank status ("All")
    # clears the filter; any other value is passed through to ransack.
    def apply_default_status_filter!(ransack_params)
      if !ransack_params.key?(:status_eq) && !ransack_params.key?("status_eq")
        ransack_params[:status_eq] = "open"
      elsif ransack_params[:status_eq].blank? && ransack_params["status_eq"].blank?
        ransack_params.delete(:status_eq)
        ransack_params.delete("status_eq")
      end
    end

    def update_preserve
      @exception_group.update!(preserve: ActiveModel::Type::Boolean.new.cast(params[:preserve]))
      flash[:notice] = @exception_group.preserve? ? "Exception preserved from cleanup." : "Exception no longer preserved."
      redirect_to exception_path(@exception_group)
    end

    def update_status
      new_status = params[:status]
      unless ExceptionGroup::STATUSES.include?(new_status)
        head :unprocessable_entity
        return
      end

      @exception_group.update!(
        status: new_status,
        resolved_at: new_status == "resolved" ? Time.current : nil
      )

      flash[:notice] = "Exception marked as #{new_status}."
      redirect_to exception_path(@exception_group)
    end
  end
end
