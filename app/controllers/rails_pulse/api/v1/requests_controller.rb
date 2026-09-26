module RailsPulse
  module Api
    module V1
      class RequestsController < BaseController
        STATUS_CLASS = /\A(\d)xx\z/
        STATUS_CODE  = /\A\d{3}\z/

        def index
          collection = RailsPulse::Request.all.order(occurred_at: :desc)

          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          collection = collection.where(occurred_at: since_start..) if since_start
          collection = collection.where(occurred_at: ..until_end) if until_end
          collection = apply_route_filter(collection)
          collection = apply_status_filter(collection)
          return if performed?

          data, meta = paginated(collection)
          render json: { data: data.map { |request| RequestSerializer.serialize(request) }, meta: meta }
        end

        private

        # Case-insensitive substring match on the request's controller action
        # or its route's path, so an agent can profile one endpoint without
        # paging through every request in the window.
        def apply_route_filter(scope)
          return scope unless params[:route].present?

          term = "%#{RailsPulse::Request.sanitize_sql_like(params[:route].to_s.downcase)}%"
          scope.joins(:route).where(
            "LOWER(rails_pulse_requests.controller_action) LIKE :term OR LOWER(rails_pulse_routes.path) LIKE :term",
            term: term
          )
        end

        def apply_status_filter(scope)
          return scope unless params[:status].present?

          status = params[:status].to_s
          if (match = status.match(STATUS_CLASS))
            digit = match[1].to_i
            scope.where(status: (digit * 100)...((digit + 1) * 100))
          elsif status.match?(STATUS_CODE)
            scope.where(status: status.to_i)
          else
            render json: { error: "Invalid status. Use a three-digit code (500) or a class (5xx)" }, status: :bad_request
            scope
          end
        end
      end
    end
  end
end
