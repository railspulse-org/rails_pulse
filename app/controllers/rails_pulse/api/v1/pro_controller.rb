module RailsPulse
  module Api
    module V1
      # Answers the API endpoints that rails_pulse_pro adds when that gem is
      # not installed, so the CLI and the MCP tools can say what is missing
      # instead of 404ing. rails_pulse_pro draws the real routes and these
      # stubs are skipped (see config/routes.rb).
      class ProController < BaseController
        FEATURES = {
          "alerts"                => "Alert history",
          "alert_rules"           => "Alert rules",
          "summary"               => "Weekly and monthly summaries",
          "threshold_suggestions" => "Backtested threshold suggestions",
          "setup"                 => "The setup and tuning check"
        }.freeze

        URL = "https://railspulse.com/pro".freeze

        def show
          feature = params[:feature].to_s

          render json: {
            error:   "requires_pro",
            feature: feature,
            message: "#{FEATURES.fetch(feature, feature)} needs Rails Pulse Pro, which is not installed in this application.",
            url:     URL
          }, status: :payment_required
        end
      end
    end
  end
end
