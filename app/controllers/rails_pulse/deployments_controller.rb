module RailsPulse
  class DeploymentsController < ApplicationController
    # The API actions authenticate by token so CI can post without a session;
    # the browsable pages use the dashboard's own authentication like every
    # other page. Scoping the skip to create/finish means adding a UI does not
    # widen the hole the 0.4.0 audit closed.
    skip_before_action :authenticate_rails_pulse_user!, only: %i[create finish]
    skip_before_action :verify_authenticity_token, only: %i[create finish]
    before_action :authenticate_deployment_request!, only: %i[create finish]

    def index
      @ransack_query = Deployment.ransack(ransack_params)
      @ransack_query.sorts = "started_at desc" if @ransack_query.sorts.empty?
      @pagination, @table_data = paginate(@ransack_query.result, limit: session_pagination_limit)
    end

    def show
      @deployment = Deployment.find(params[:id])
    end

    def create
      deployment = RailsPulse::Deployment.new(
        revision:    deployment_params[:revision],
        started_at:  deployment_params[:started_at].presence || Time.current,
        finished_at: deployment_params[:finished_at].presence,
        metadata:    deployment_params[:metadata]&.to_json
      )

      if deployment.save
        render json: { status: "created", id: deployment.id, revision: deployment.revision,
                       started_at: deployment.started_at, finished_at: deployment.finished_at }, status: :created
      else
        render json: { status: "error", errors: deployment.errors.full_messages },
               status: :unprocessable_content
      end
    end

    def finish
      deployment = RailsPulse::Deployment.latest_for_revision(finish_params[:revision])

      return render json: { status: "error", error: "Deployment not found" }, status: :not_found unless deployment

      deployment.finished_at = finish_params[:finished_at].presence || Time.current

      if deployment.save
        render json: { status: "updated", id: deployment.id, revision: deployment.revision,
                       started_at: deployment.started_at, finished_at: deployment.finished_at }
      else
        render json: { status: "error", errors: deployment.errors.full_messages },
               status: :unprocessable_content
      end
    end

    private

    def authenticate_deployment_request!
      token = RailsPulse.configuration.api_token
      if token.present?
        provided = request.headers["X-Rails-Pulse-Token"].to_s
        unless ActiveSupport::SecurityUtils.secure_compare(provided, token)
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      elsif RailsPulse.configuration.authentication_enabled
        authenticate_rails_pulse_user!
      else
        # No token configured and authentication disabled — fail closed.
        # Without a token there is no way to verify the caller.
        render json: { error: "Unauthorized — set config.api_token or enable authentication" }, status: :unauthorized
      end
    end

    def deployment_params
      params.require(:deployment).permit(:revision, :started_at, :finished_at, metadata: {})
    end

    def finish_params
      params.require(:deployment).permit(:revision, :finished_at)
    end
  end
end
