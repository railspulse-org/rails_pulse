module RailsPulse
  module Api
    module V1
      class RequestSerializer
        def self.serialize(request)
          {
            id:                  request.id,
            route_id:            request.route_id,
            occurred_at:         request.occurred_at,
            duration:            request.duration,
            status:              request.status,
            is_error:            request.is_error,
            request_uuid:        request.request_uuid,
            controller_action:   request.controller_action,
            response_size_bytes: request.response_size_bytes
          }
        end
      end
    end
  end
end
