module RailsPulse
  module Api
    module V1
      # Answers the API endpoints an extension engine adds when none is
      # installed, so the CLI and the MCP tools can say what is missing
      # instead of 404ing. An installed extension draws the real routes and
      # these stubs are skipped (see config/routes.rb).
      class ExtensionController < BaseController
        FEATURES = {
          "alerts"                => "Alert history",
          "alert_rules"           => "Alert rules",
          "summary"               => "Weekly and monthly summaries",
          "threshold_suggestions" => "Backtested threshold suggestions",
          "setup"                 => "The setup and tuning check"
        }.freeze

        def show
          feature = params[:feature].to_s

          render json: {
            error:   "requires_extension",
            feature: feature,
            message: "#{FEATURES.fetch(feature, feature)} is provided by an extension that is not installed in this application."
          }, status: :payment_required
        end
      end
    end
  end
end
