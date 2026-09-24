# frozen_string_literal: true

# MetricCardConcern
#
# Provides a consistent pattern for setting up metric cards across resource controllers.
# Each controller defines which metric cards to display via `metric_card_definitions`,
# and this concern handles the instantiation with common parameters.
#
# Example usage:
#   def metric_card_definitions
#     {
#       percentile_response_times_metric_card: Routes::Cards::PercentileResponseTimes,
#       request_count_totals_metric_card: Routes::Cards::RequestCountTotals
#     }
#   end
module MetricCardConcern
  extend ActiveSupport::Concern

  private

  # Sets up all metric cards defined by the controller.
  # Skips setup for partial requests to avoid unnecessary computation.
  def setup_metric_cards
    return if partial_request?

    card_params = metric_card_params

    metric_card_definitions.each do |ivar_name, card_class|
      instance_variable_set(
        "@#{ivar_name}",
        card_class.new(**card_params).to_metric_card
      )
    end
  end

  # Common parameters passed to all metric card classes. Deliberately does
  # NOT pass window: — these cards show a "trailing period" figure, not the
  # exact selected range (ChartTableConcern's charts get the exact window;
  # see Cards::Base#window_days).
  def metric_card_params
    window = @time_range&.window
    period_days = window ? ((window.end_time - window.start_time) / 1.day).round : 7

    {
      resource_key => current_resource,
      disabled_tags: session_disabled_tags,
      show_non_tagged: session[:show_non_tagged] != false,
      period: period_days,
      period_type: period_type.to_s
    }
  end

  # Abstract: Define which metric cards to display
  # Returns a hash of { instance_variable_name: CardClass }
  def metric_card_definitions
    raise NotImplementedError, "#{self.class} must implement #metric_card_definitions"
  end

  # Abstract: The key name for the resource (e.g., :route, :query, :job)
  def resource_key
    raise NotImplementedError, "#{self.class} must implement #resource_key"
  end

  # Override in show actions to pass the current resource to cards
  # Returns nil for index actions
  def current_resource
    nil
  end
end
