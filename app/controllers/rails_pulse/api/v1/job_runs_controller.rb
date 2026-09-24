module RailsPulse
  module Api
    module V1
      class JobRunsController < BaseController
        def index
          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          collection = RailsPulse::JobRun.includes(:job).order(occurred_at: :desc)
          collection = collection.where(occurred_at: since_start..) if since_start
          collection = collection.where(occurred_at: ..until_end) if until_end

          status = params[:status].presence
          if status == "failed"
            collection = collection.failed
          elsif status
            unless RailsPulse::JobRun::STATUSES.include?(status)
              return render json: { error: "Invalid status. Valid values: #{RailsPulse::JobRun::STATUSES.join(', ')}" }, status: :bad_request
            end
            collection = collection.where(status: status)
          end

          if params[:job].present?
            collection = collection.joins(:job).where(rails_pulse_jobs: { name: params[:job] })
          end

          data, meta = paginated(collection)
          render json: { data: data.map { |run| JobRunSerializer.serialize(run) }, meta: meta }
        end
      end
    end
  end
end
