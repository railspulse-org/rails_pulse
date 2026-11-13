# frozen_string_literal: true

module RailsPulse
  # A central Rails Pulse: it receives what remote applications collect
  # (RailsPulse::Remote, through Central::BatchesController), writes each
  # application into a database of its own and serves one dashboard per
  # application. Configured by config.central.applications.
  #
  # Each application is a shard of RailsPulse::ApplicationRecord, named after
  # it. Anything that reads or writes Rails Pulse tables runs inside
  # with_application; outside one a query fails rather than landing in
  # whichever application is listed first (see NO_APPLICATION). Process
  # caches that hold ids (the tracker's rollups and route cache, the schema
  # check, the deploy SHA) are kept per application for the same reason.
  #
  # The central mounts the engine under a path segment naming the
  # application, so /shop/routes is the shop's routes page:
  #
  #   mount RailsPulse::Engine, at: "/:rails_pulse_application", as: :rails_pulse,
  #         constraints: RailsPulse::Central.route_constraints
  module Central
    # The shard RailsPulse::ApplicationRecord falls back to outside
    # with_application: an empty in-memory SQLite database. Models can load
    # and declare their attributes against it, as an eager-loading boot does
    # before any application is connected, but every query fails there for
    # want of its table.
    NO_APPLICATION = :rails_pulse_no_application

    # The path segment of the central's mount that names the application.
    PATH_PARAMETER = :rails_pulse_application

    # Engine URL helpers called with no request at hand (the layout's
    # rails_pulse.* links, Dashboard::NeedsAttention) ask the mount for its
    # prefix, which the application segment is missing from. While a
    # dashboard request is served they get the prefix that request was
    # routed under, the one the controller's own URL helpers use.
    module RequestScriptName
      def find_script_name(options)
        script_name = RailsPulse::Current.rails_pulse_script_name
        return super if script_name.nil? || options[:script_name].present?

        options.delete(:script_name)
        script_name
      end
    end

    class << self
      def enabled?
        RailsPulse.configuration&.central&.enabled? || false
      end

      def application_names
        RailsPulse.configuration.central.application_names
      end

      # Arguments for RailsPulse::ApplicationRecord.connects_to: NO_APPLICATION,
      # the default, then a shard per application.
      def connects_to
        empty = ActiveRecord::DatabaseConfigurations::HashConfig.new(
          Rails.env, NO_APPLICATION.to_s, { adapter: "sqlite3", database: ":memory:" }
        )
        shards = RailsPulse.configuration.central.connects_to[:shards]
        { shards: { NO_APPLICATION => { writing: empty, reading: empty } }.merge(shards) }
      end

      def application?(name)
        name.present? && application_names.map(&:to_s).include?(name.to_s)
      end

      # The application a bearer token belongs to, or nil. Every configured
      # token is compared, each in constant time, so how long the answer
      # takes says nothing about which one matched.
      def application_for_token(token)
        return nil if token.blank?

        RailsPulse.configuration.central.entries.reduce(nil) do |found, (name, options)|
          configured = options[:token].to_s
          matched = configured.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, configured)
          matched ? name : found
        end
      end

      # Runs the block against one application's database. A dashboard
      # request passes its script_name, the prefix engine URL helpers then
      # generate links under. With central mode off, or no application, the
      # block runs as it is.
      def with_application(name, script_name: nil, &block)
        return yield unless enabled? && name

        connect = -> { RailsPulse::ApplicationRecord.connected_to(shard: name.to_sym, role: :writing, &block) }
        return connect.call unless script_name

        previous = RailsPulse::Current.rails_pulse_script_name
        RailsPulse::Current.rails_pulse_script_name = script_name
        begin
          connect.call
        ensure
          RailsPulse::Current.rails_pulse_script_name = previous
        end
      end

      # The application whose database Rails Pulse is connected to right now:
      # nil outside with_application, and always nil with central mode off.
      def current_application
        return nil unless enabled?

        shard = RailsPulse::ApplicationRecord.current_shard
        shard == NO_APPLICATION ? nil : shard
      end

      # Runs the block once per application, each in its own database. One
      # application's failure is logged and the others still run; the first
      # failure is raised once they all have.
      def each_application
        first_error = nil
        application_names.each do |name|
          with_application(name) { yield name }
        rescue StandardError => e
          RailsPulse.logger.error("[RailsPulse] #{name}: #{e.class} - #{e.message}")
          first_error ||= e
        end
        raise first_error if first_error
      end

      # Segment constraints for the central's mount, so only a configured
      # application reaches the engine and every other path stays the
      # central's own.
      def route_constraints
        { PATH_PARAMETER => Regexp.union(application_names.map(&:to_s)) }
      end

      # Called once the host's initializers have run, so it sees the final
      # configuration. With no writer thread here, nothing else flushes the
      # rollups of folded requests at exit, as the writer's shutdown does
      # where requests are tracked.
      def install!
        return unless enabled?

        routes = RailsPulse::Engine.routes
        return if routes.singleton_class.ancestors.include?(RequestScriptName)

        routes.singleton_class.prepend(RequestScriptName)
        at_exit { RailsPulse::Tracker.flush_rollups! }
      end
    end
  end
end
