module RailsPulse
  module Api
    module V1
      class JobsController < BaseController
        STATUSES = %w[failed].freeze

        def index
          collection = RailsPulse::Job.all.order(:name)
          collection = collection.where(name: params[:job]) if params[:job].present?

          status = params[:status].presence
          if status && !STATUSES.include?(status)
            return render json: { error: "Invalid status. Valid values: #{STATUSES.join(', ')}" }, status: :bad_request
          end
          collection = collection.with_failures if status == "failed"

          data, meta = paginated(collection)
          render json: { data: data.map { |job| JobSerializer.serialize(job) }, meta: meta }
        end
      end
    end
  end
end
