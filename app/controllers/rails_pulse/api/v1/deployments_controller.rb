module RailsPulse
  module Api
    module V1
      class DeploymentsController < BaseController
        def index
          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          collection = RailsPulse::Deployment.recent
          collection = collection.where(started_at: since_start..) if since_start
          collection = collection.where(started_at: ..until_end) if until_end

          data, meta = paginated(collection)
          deployments = data.to_a
          regressions = deployment_regressions(deployments)

          render json: {
            data: deployments.map { |deployment| DeploymentSerializer.serialize(deployment, regression: regressions[deployment.id]) },
            meta: meta
          }
        end

        private

        # Extension point. An extension overrides this to return each
        # deployment's regression check, keyed by deployment id, already
        # serialized; this gem has no regression data to attach.
        def deployment_regressions(_deployments)
          {}
        end
      end
    end
  end
end
