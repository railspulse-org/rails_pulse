module RailsPulse
  module Api
    module V1
      class JobsController < BaseController
        def index
          collection = RailsPulse::Job.all.order(:name)
          collection = collection.with_failures if params[:status] == "failed"
          data, meta = paginated(collection)
          render json: { data: data.map { |job| JobSerializer.serialize(job) }, meta: meta }
        end
      end
    end
  end
end
