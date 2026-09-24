module RailsPulse
  module Api
    module V1
      class RouteSerializer
        def self.serialize(route, stats: nil)
          {
            id:                route.id,
            http_methods:      route.http_methods_list,
            path:              route.path,
            controller_action: route.controller_action,
            tags:              route.tag_list,
            created_at:        route.created_at,
            stats:             stats
          }
        end
      end
    end
  end
end
