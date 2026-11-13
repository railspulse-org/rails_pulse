module RailsPulse
  module Central
    # The central's index: every configured application, when it was last
    # heard from, and a link to its dashboard. Routed by the central's own
    # routes file, outside any application's path, and authenticated like
    # the dashboards. It reads only each application's latest heartbeat and
    # request, so none of the dashboard's per-application callbacks run.
    class ApplicationsController < RailsPulse::ApplicationController
      skip_around_action :serve_central_application
      skip_before_action :require_current_schema!
      skip_before_action :set_onboarding_state
      skip_before_action :load_deployment_markers

      layout false

      def index
        @applications = RailsPulse::Central.application_names.map do |name|
          { name: name.to_s, last_seen_at: last_seen_at(name) }
        end
      end

      private

      # A writer heartbeats once a minute even when idle, so the latest one
      # says whether the application is still sending; nil when its database
      # has nothing yet or cannot be read.
      def last_seen_at(name)
        RailsPulse::Central.with_application(name) do
          [ RailsPulse::WriterHeartbeat.events.maximum(:occurred_at), RailsPulse::Request.maximum(:occurred_at) ].compact.max
        end
      rescue StandardError => e
        logger.warn "RailsPulse: could not read #{name}'s database: #{e.class} - #{e.message}"
        nil
      end
    end
  end
end
