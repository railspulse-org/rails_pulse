module RailsPulse
  module Api
    module V1
      # Read-only JSON API for the rails-pulse CLI, the MCP server, CI scripts
      # and coding agents. Authenticated by config.api_token alone: the
      # dashboard session is never consulted, and with no token configured
      # every request is refused.
      class BaseController < RailsPulse::ApplicationController
        skip_before_action :authenticate_rails_pulse_user!
        skip_before_action :set_onboarding_state
        skip_before_action :load_deployment_markers

        before_action :authenticate_api_token!

        private

        def authenticate_api_token!
          token = RailsPulse.configuration.api_token.to_s
          provided = request.headers["X-Rails-Pulse-Token"].to_s
          return if token.present? && ActiveSupport::SecurityUtils.secure_compare(provided, token)

          render json: { error: "Unauthorized" }, status: :unauthorized
        end

        def limit
          params.fetch(:limit, 25).to_i.clamp(1, 500)
        end

        def offset
          params.fetch(:offset, 0).to_i.clamp(0, Float::INFINITY)
        end

        def since_time
          Time.parse(params[:since]) if params[:since].present?
        rescue ArgumentError
          render json: { error: "Invalid time format for 'since'" }, status: :bad_request
        end

        def until_time
          Time.parse(params[:until]) if params[:until].present?
        rescue ArgumentError
          render json: { error: "Invalid time format for 'until'" }, status: :bad_request
        end

        def time_range
          since_start = since_time
          return if performed?
          until_end = until_time
          return if performed?
          [ since_start, until_end ]
        end

        def paginated(collection)
          total = collection.count
          data = collection.limit(limit).offset(offset)
          [ data, { total: total, limit: limit, offset: offset } ]
        end
      end
    end
  end
end
