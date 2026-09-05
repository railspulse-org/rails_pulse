require_relative "base_methods"
require_relative "schema_parser"
require_relative "../../rails_pulse/installers/config_updater"

module RailsPulse
  module Generators
    class UpgradeGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      include BaseMethods

      source_root File.expand_path("templates", __dir__)

      desc "Upgrade Rails Pulse database schema to the latest version"

      class_option :database, type: :string, default: "detect",
                   desc: "Database setup: 'single', 'separate', or 'detect' (default)"

      def check_current_installation
        @database_type = detect_database_setup

        say "Detected database setup: #{@database_type}", :green

        case @database_type
        when :single
          upgrade_installation(migration_dir: "db/migrate", migrate_command: "rails db:migrate")
        when :separate
          warn_if_missing_schema_dump_false
          upgrade_installation(migration_dir: "db/rails_pulse_migrate", migrate_command: "rails db:migrate:rails_pulse")
        when :schema_only
          offer_conversion_to_migrations
        when :not_installed
          say "Rails Pulse not detected. Run 'rails generate rails_pulse:install' first.", :red
          exit 1
        end
      end

      private

      def detect_database_setup
        # Override with command line option if provided
        return options[:database].to_sym if options[:database] != "detect"

        # Determine database type before checking tables so the table lookup
        # uses the correct connection pool for separate-database setups.
        @is_separate_db = has_separate_database_config?
        tables_exist = rails_pulse_tables_exist?
        schema_path = File.join(root_path, "db/rails_pulse_schema.rb")

        # :schema_only only applies to single-database users who have the schema file
        # but haven't run the install migration yet. Separate-database users legitimately
        # have no Rails Pulse tables on the primary connection — that is not an error.
        if !tables_exist && !@is_separate_db && File.exist?(schema_path)
          :schema_only
        elsif !tables_exist
          :not_installed
        elsif @is_separate_db
          :separate
        else
          :single
        end
      end

      def has_separate_database_config?
        config_path = File.join(root_path, "config/database.yml")
        return false unless File.exist?(config_path)

        require "yaml"
        require "erb"
        # Process ERB before YAML parsing — database.yml files commonly use ERB
        # for environment-specific values. YAML.safe_load alone raises SyntaxError
        # on ERB tags.
        yaml_content = ERB.new(File.read(config_path)).result
        db_config = YAML.safe_load(yaml_content, aliases: true)
        db_config.values.any? { |env| env.is_a?(Hash) && env.key?("rails_pulse") }
      rescue
        false
      end

      def rails_pulse_tables_exist?
        return false unless defined?(ActiveRecord::Base)

        connection = if @is_separate_db && defined?(RailsPulse::ApplicationRecord)
          RailsPulse::ApplicationRecord.connection
        else
          ActiveRecord::Base.connection
        end

        required_tables = get_rails_pulse_table_names
        required_tables.all? { |table| connection.table_exists?(table) }
      rescue
        false
      end

      def get_rails_pulse_table_names
        schema_file = File.join(root_path, "db/rails_pulse_schema.rb")
        SchemaParser.new(schema_file).extract_table_names
      end

      # Notices printed when a feature's migration is newly copied into the host app.
      # Key is a substring of the migration filename (without timestamp).
      FEATURE_NOTICES = {
        "create_rails_pulse_exceptions" => <<~NOTICE.rstrip
          Exception tracking (opt-in)

          This upgrade adds exception tables. Capture stays off for existing
          installs until you opt in. After migrating, set the following in
          config/initializers/rails_pulse.rb (the upgrade generator inserts
          it as false — review with git diff) and restart:

            config.track_exceptions = true

          New installs enable this in the generated initializer. Messages and
          request params are both redacted using Rails filter_parameters; set
          config.exception_message_filter for anything app-specific.

          Two new tables will be created:
            - rails_pulse_exception_groups
            - rails_pulse_exception_occurrences

          To skip the tables entirely, delete the copied
          *_create_rails_pulse_exceptions.rb migration before db:migrate.
          (A later upgrade will copy it again unless that file remains in
          your migrate folder.)
        NOTICE
      }.freeze

      # Shared upgrade logic for both single and separate database setups
      def upgrade_installation(migration_dir:, migrate_command:)
        # Refresh the schema file so fresh databases (test, CI) built from
        # db/rails_pulse_schema.rb include all current columns and tables.
        copy_file "db/rails_pulse_schema.rb", "db/rails_pulse_schema.rb", force: true
        sync_initializer

        gem_migrations = get_gem_migrations
        existing_migrations = get_user_migrations(migration_dir)
        new_migrations = gem_migrations - existing_migrations

        if new_migrations.any?
          say "Found #{new_migrations.size} new migration(s) to copy:", :blue
          new_migrations.each do |migration|
            say "  - #{migration}", :blue
            copy_gem_migration_to(migration, migration_dir)
          end

          say "\nMigrations copied successfully!", :green
          announce_new_features(new_migrations)
          include_route_backfill = requires_route_backfill?(new_migrations)
          say_route_backfill_warning if include_route_backfill
          say_next_steps(migrate_command, include_route_backfill: include_route_backfill)
        else
          upgrade_with_missing_columns(migration_dir: migration_dir, migrate_command: migrate_command)
        end
      end

      def announce_new_features(new_migrations)
        notices = FEATURE_NOTICES.filter_map do |migration_key, notice|
          notice if new_migrations.any? { |filename| filename.include?(migration_key) }
        end
        return if notices.empty?

        say "\n" + ("=" * 72), :yellow
        notices.each_with_index do |notice, index|
          say "" if index.positive?
          notice.each_line { |line| say line.chomp, :yellow }
        end
        say ("=" * 72) + "\n", :yellow
      end

      def upgrade_with_missing_columns(migration_dir:, migrate_command:)
        missing_columns = detect_missing_columns

        if missing_columns.empty?
          report_outstanding_work(migrate_command)
          return
        end

        missing_by_table = format_missing_columns_by_table(missing_columns)

        say "Creating upgrade migration for missing columns: #{missing_columns.keys.join(', ')}", :blue

        @migration_version = ActiveRecord::Migration.current_version
        @missing_columns = missing_by_table

        migration_template(
          "migrations/upgrade_rails_pulse_tables.rb",
          "#{migration_dir}/upgrade_rails_pulse_tables.rb"
        )

        say "\nUpgrade migration created successfully!", :green
        missing_names = missing_columns.keys.map(&:to_s)
        include_route_backfill = missing_names.intersect?(%w[controller_action http_methods])
        say_route_backfill_warning if include_route_backfill
        say_next_steps(migrate_command, include_route_backfill: include_route_backfill)
        say "\nThis migration will add: #{missing_columns.keys.join(', ')}\n"
      end

      ROUTE_BACKFILL_MIGRATIONS = %w[
        change_rails_pulse_routes_to_multi_verb_model
        add_null_action_unique_index_to_routes
      ].freeze

      # "Rails Pulse is up to date! No migration needed." used to be printed
      # whenever every migration *file* was already in the app — including the
      # common case where they were copied in one deploy and have not yet been
      # run against this database, or where the schema migrated but
      # `rails_pulse:migrate_routes` is still outstanding. A host in that state
      # is one deploy away from the 0.4 gem running against 0.3 tables. Say
      # what is actually left instead.
      def report_outstanding_work(migrate_command)
        pending = pending_migration_files
        backfill = route_backfill_outstanding?

        if pending.empty? && !backfill
          if @initializer_updated
            say "Schema is up to date. Review initializer changes with git diff.", :green
          else
            say "Rails Pulse is up to date! No migration needed.", :green
          end
          return
        end

        say "All of this version's migration files are present, but this database is not up to date:", :yellow
        if pending.any?
          say "  #{pending.size} migration file(s) have not been run:", :yellow
          pending.each { |filename| say "    - #{filename}", :yellow }
        end
        say "  Route actions have not been backfilled.", :yellow if backfill

        include_route_backfill = backfill || requires_route_backfill?(pending)
        say_route_backfill_warning if include_route_backfill
        say_next_steps(migrate_command, include_route_backfill: include_route_backfill)
      end

      # Migration files on disk whose version is not recorded on the connection
      # this install uses. Any failure (no database, stubbed connection) reads
      # as "nothing pending" so the generator never blocks on it.
      def pending_migration_files
        pool = if @is_separate_db && defined?(RailsPulse::ApplicationRecord)
          RailsPulse::ApplicationRecord.connection_pool
        else
          ActiveRecord::Base.connection_pool
        end
        context = pool.migration_context
        applied = context.get_all_versions
        context.migrations.reject { |migration| applied.include?(migration.version) }
               .map { |migration| File.basename(migration.filename) }
      rescue StandardError
        []
      end

      def route_backfill_outstanding?
        defined?(RailsPulse::Route) && RailsPulse::Route.needs_action_backfill?
      rescue StandardError
        false
      end

      def requires_route_backfill?(migrations)
        migrations.any? do |name|
          ROUTE_BACKFILL_MIGRATIONS.any? { |fragment| name.include?(fragment) }
        end
      end

      def say_route_backfill_warning
        say "\nIMPORTANT: This upgrade changes how routes are identified.", :yellow
        say "Schema migrate alone leaves the Action column empty. After migrating, run:", :yellow
        say "  rails rails_pulse:migrate_routes", :yellow
        say "Skipping this leaves GET/POST on the same path unmerged in the dashboard.", :yellow
        say "\nWARNING: Migration 20260610000002 is irreversible (drops routes.method).", :red
        say "db:rollback past this point requires a database restore.", :red
      end

      def say_next_steps(migrate_command, include_route_backfill:)
        n = 1
        say "\nNext steps:", :green
        say "#{n}. Run: #{migrate_command}"
        n += 1
        if include_route_backfill
          say "#{n}. Run: rails rails_pulse:migrate_routes"
          n += 1
        end
        if @initializer_updated
          say "#{n}. Review config/initializers/rails_pulse.rb with git diff"
          n += 1
        end
        say "#{n}. Restart ALL processes (web + workers) together — a rolling restart"
        say "   that leaves old processes against the new schema breaks tracking."
      end

      def sync_initializer
        path = File.join(root_path, "config/initializers/rails_pulse.rb")
        result = RailsPulse::Installers::ConfigUpdater.update(
          destination: path,
          source: File.join(self.class.source_root, "rails_pulse.rb")
        )
        @initializer_updated = result[:status] == :updated
        return unless @initializer_updated

        say "\nUpdated config/initializers/rails_pulse.rb with new settings:", :blue
        result[:keys].each { |key| say "  - config.#{key}", :blue }
        result[:hash_keys].each { |key| say "  - #{key}", :blue }
        say "Review with git diff and keep or discard hunks.", :green
      end

      def warn_if_missing_schema_dump_false
        return unless separate_database_missing_schema_dump_false?

        say "\nIMPORTANT: Add schema_dump: false to the rails_pulse entry in", :yellow
        say "config/database.yml. Without it, Rails may dump or load", :yellow
        say "db/rails_pulse_structure.sql and db:migrate can fail with", :yellow
        say "\"relation already exists\". Delete that structure file if present.", :yellow
      end

      def separate_database_missing_schema_dump_false?
        config_path = File.join(root_path, "config/database.yml")
        return false unless File.exist?(config_path)

        require "yaml"
        require "erb"
        yaml_content = ERB.new(File.read(config_path)).result
        db_config = YAML.safe_load(yaml_content, aliases: true)
        pulse_entries = db_config.values.filter_map do |env|
          env["rails_pulse"] if env.is_a?(Hash)
        end
        return false if pulse_entries.empty?

        pulse_entries.any? { |entry| !entry.is_a?(Hash) || entry["schema_dump"] != false }
      rescue
        false
      end

      def offer_conversion_to_migrations
        say <<~MESSAGE

          Rails Pulse schema detected but no tables found.

          To convert to single database setup:
          1. Run: rails generate rails_pulse:convert_to_migrations
          2. Run: rails db:migrate

          The schema file db/rails_pulse_schema.rb will remain as your single source of truth.

        MESSAGE
      end

      def detect_missing_columns
        return {} unless rails_pulse_tables_exist?

        connection = if @is_separate_db && defined?(RailsPulse::ApplicationRecord)
          RailsPulse::ApplicationRecord.connection
        else
          ActiveRecord::Base.connection
        end
        missing = {}

        get_expected_schema_from_file.each do |table_name, columns|
          table_symbol = table_name.to_sym

          if connection.table_exists?(table_symbol)
            existing_columns = connection.columns(table_symbol).map(&:name)

            columns.each do |column_name, definition|
              missing[column_name] = definition unless existing_columns.include?(column_name)
            end
          end
        end

        missing
      end

      def get_expected_schema_from_file
        schema_file = File.join(root_path, "db/rails_pulse_schema.rb")
        SchemaParser.new(schema_file).extract_expected_schema
      end

      def format_missing_columns_by_table(missing_columns)
        missing_by_table = {}

        get_expected_schema_from_file.each do |table_name, expected_columns|
          table_missing = expected_columns.select { |col, _| missing_columns.key?(col) }
          missing_by_table[table_name] = table_missing if table_missing.any?
        end

        missing_by_table
      end

      def get_gem_migrations
        path = gem_migrations_path
        return [] unless File.directory?(path)

        Dir.glob("#{path}/*.rb").map { |f| File.basename(f) }
      end

      def get_user_migrations(directory)
        full_directory = File.join(root_path, directory)

        return [] unless File.directory?(full_directory)

        Dir.glob("#{full_directory}/*.rb").map { |f| File.basename(f) }
      end

      def copy_gem_migration_to(migration_name, destination)
        source_file = File.join(gem_migrations_path, migration_name)
        destination_file = File.join(destination, migration_name)

        copy_file source_file, destination_file
      end
    end
  end
end
