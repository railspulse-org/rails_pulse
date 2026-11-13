module RailsPulse
  module Api
    module V1
      # Which installation answered, so a caller can tell one deployment's
      # numbers from another's before it starts reading them.
      class CapabilitiesController < BaseController
        def show
          render json: {
            rails_pulse_version: RailsPulse::VERSION,
            environment: Rails.env.to_s,
            # Names the installation a response came from, so two profiles
            # pointed at staging and production cannot be confused.
            application: application_name
          }
        end

        private

        # On a central, the application whose data this is.
        def application_name
          RailsPulse::Central.current_application&.to_s || Rails.application.class.module_parent_name
        rescue StandardError
          nil
        end
      end
    end
  end
end
