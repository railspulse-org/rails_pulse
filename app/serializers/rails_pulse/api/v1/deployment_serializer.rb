module RailsPulse
  module Api
    module V1
      class DeploymentSerializer
        # `regression` is the already-serialized regression check that
        # rails_pulse_pro attaches, or nil.
        def self.serialize(deployment, regression: nil)
          {
            id:               deployment.id,
            revision:         deployment.revision,
            short_revision:   deployment.short_revision,
            started_at:       deployment.started_at,
            finished_at:      deployment.finished_at,
            duration_seconds: deployment.duration&.round(1),
            in_progress:      deployment.in_progress?,
            metadata:         deployment.metadata_hash,
            regression:       regression
          }
        end
      end
    end
  end
end
