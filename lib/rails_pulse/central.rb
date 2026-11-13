# frozen_string_literal: true

require "stringio"

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

    # The shard load_schema connects to the database it loads, for as long
    # as it takes.
    SCHEMA_LOAD_SHARD = :rails_pulse_schema_load

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

      # Loads db/rails_pulse_schema.rb into each application's database, in
      # each of `environments`, that does not have the Rails Pulse tables
      # yet, and records there what Rails' own schema load would: the
      # migrations in db/rails_pulse_migrate as applied (the schema already
      # has what they add, and db:migrate would otherwise run them against
      # it) and the environment the database belongs to, which Rails'
      # protected-environment checks (db:drop, db:reset, db:test:prepare,
      # db:seed:replant) refuse to proceed without. A database that has the
      # tables is left to db:migrate, and only gets an environment if it has
      # none. Run by db:prepare and db:migrate on a central; a host's test
      # suite calls it from parallelize_setup, whose workers start with empty
      # copies of these databases.
      def load_schema(environments: [ Rails.env ], schema_file: Rails.root.join("db/rails_pulse_schema.rb"),
                      migrations_path: Rails.root.join("db/rails_pulse_migrate"), quiet: false)
        with_output(quiet) do
          unless File.exist?(schema_file)
            puts "Rails Pulse schema file not found. Run: rails generate rails_pulse:install --database=separate"
            next
          end

          environments.each do |environment|
            RailsPulse.configuration.central.entries.each do |name, options|
              db_config = ActiveRecord::Base.configurations.configs_for(env_name: environment, name: options[:database].to_s,
                                                                        include_hidden: true)
              load_schema_into(db_config, "#{name} (#{environment})", schema_file, migrations_path) if db_config
            end
          end
        end
      end

      # The environments db:prepare, db:create and db:drop act on when run in
      # `environment`: development brings test along unless SKIP_TEST_DATABASE
      # or DATABASE_URL is set, as ActiveRecord::Tasks::DatabaseTasks decides.
      def task_environments(environment)
        environments = [ environment.to_s ]
        environments << "test" if environment.to_s == "development" && !ENV["SKIP_TEST_DATABASE"] && !ENV["DATABASE_URL"]
        environments
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

      private

      def load_schema_into(db_config, label, schema_file, migrations_path)
        with_database(db_config) do |pool|
          loaded = false
          if pool.with_connection { |connection| connection.table_exists?(:rails_pulse_routes) }
            puts "Rails Pulse tables already exist for #{label}"
          else
            # The file loads itself through RailsPulse::ApplicationRecord's
            # connection, which with_database points at this database.
            load schema_file.to_s
            record_migrations(pool, migrations_path)
            loaded = true
            puts "Rails Pulse schema loaded for #{label}"
          end
          record_environment(pool, db_config.env_name, loaded: loaded)
        end
      end

      # A shard of RailsPulse::ApplicationRecord for one database alone, for
      # the length of the block, whatever environment the database is in.
      def with_database(db_config)
        handler = RailsPulse::ApplicationRecord.connection_handler
        handler.establish_connection(db_config, owner_name: RailsPulse::ApplicationRecord, role: :writing, shard: SCHEMA_LOAD_SHARD)
        RailsPulse::ApplicationRecord.connected_to(shard: SCHEMA_LOAD_SHARD, role: :writing) do
          yield RailsPulse::ApplicationRecord.connection_pool
        end
      ensure
        handler&.remove_connection_pool(RailsPulse::ApplicationRecord.connection_specification_name,
                                        role: :writing, shard: SCHEMA_LOAD_SHARD)
      end

      def record_migrations(pool, migrations_path)
        versions = Dir[File.join(migrations_path.to_s, "*.rb")].filter_map { |file| File.basename(file)[/\A\d+(?=_)/] }.sort
        return if versions.empty?

        schema_migration = pool.schema_migration
        schema_migration.create_table
        (versions - schema_migration.versions).each do |version|
          schema_migration.create_version(version)
          puts "[RailsPulse] Marked migration #{version} as applied (schema already up to date)"
        end
      end

      # Set after a load, and for a database that has never had one; never
      # replaced, since a database recorded as another environment's is what
      # the protected-environment checks exist to catch.
      def record_environment(pool, environment, loaded:)
        metadata = pool.internal_metadata
        return unless metadata.enabled?
        return if !loaded && metadata.table_exists? && metadata[:environment].present?

        metadata.create_table_and_set_flags(environment)
      end

      def with_output(quiet)
        return yield unless quiet

        original_stdout = $stdout
        $stdout = StringIO.new
        begin
          yield
        ensure
          $stdout = original_stdout
        end
      end
    end
  end
end
