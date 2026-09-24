module RailsPulse
  module Api
    module V1
      class RequestsController < BaseController
        def index
          collection = RailsPulse::Request.all.order(occurred_at: :desc)

          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          collection = collection.where(occurred_at: since_start..) if since_start
          collection = collection.where(occurred_at: ..until_end) if until_end
          collection = apply_status_filter(collection)

          data, meta = paginated(collection)
          render json: { data: data.map { |request| RequestSerializer.serialize(request) }, meta: meta }
        end

        private

        def apply_status_filter(scope)
          return scope unless params[:status].present?

          if (match = params[:status].to_s.match(/\A(\d)xx\z/))
            digit = match[1].to_i
            scope.where(status: (digit * 100)...((digit + 1) * 100))
          else
            scope.where(status: params[:status].to_i)
          end
        end
      end
    end
  end
end
