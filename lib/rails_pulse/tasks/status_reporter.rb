# frozen_string_literal: true

module RailsPulse
  module Tasks
    # `rails rails_pulse:status` — where does this install stand?
    #
    # Answers, from the shell and without opening the dashboard, the questions
    # an upgrade tends to leave hanging: is the schema current for this gem,
    # are there migration files that have not been run, has the route backfill
    # been done, does the initializer mention the settings this version added.
    # Anything that needs action is repeated in a closing "Action needed"
    # list, and `report` returns false in that case so release scripts can
    # stop on it.
    class StatusReporter
      attr_reader :output, :config

      def self.report(output: $stdout)
        new(output: output).report
      end

      def initialize(output: $stdout)
        @output = output
        @config = RailsPulse.configuration
        @actions = []
      end

      # Returns true when nothing needs attention.
      def report
        output.puts "Rails Pulse #{RailsPulse::VERSION}"
        output.puts

        print_database
        print_schema
        print_migrations
        print_route_backfill
        print_initializer
        print_tracking
        print_summaries
        print_actions

        @actions.empty?
      end

      private

      def action(text)
        @actions << text
      end

      # -- sections -----------------------------------------------------------

      def print_database
        connection = RailsPulse::ApplicationRecord.connection
        name = RailsPulse::ApplicationRecord.connection_db_config.name
        separate = config.connects_to.present?
        output.puts "Database:   #{connection.adapter_name} (#{name}#{separate ? ", separate Pulse database" : ""})"
      rescue StandardError => e
        output.puts "Database:   unavailable (#{e.class}: #{e.message})"
        action "Database connection failed; nothing below could be checked."
      end

      def print_schema
        RailsPulse::SchemaCheck.reset!
        missing = RailsPulse::SchemaCheck.missing

        if missing.empty?
          output.puts "Schema:     up to date for #{RailsPulse::VERSION}"
          return
        end

        output.puts "Schema:     BEHIND this gem version"
        missing.each do |table, columns|
          output.puts(columns == [ :table ] ? "              #{table}: table missing" : "              #{table}: missing #{columns.join(', ')}")
        end
        action "Schema is behind the gem. Run: #{upgrade_commands.join(' && ')}"
      end

      def print_migrations
        not_copied = gem_migrations_not_in_host
        pending = pending_migrations

        if not_copied.empty? && pending.empty?
          output.puts "Migrations: none pending"
          return
        end

        if not_copied.any?
          output.puts "Migrations: #{not_copied.size} gem migration(s) not yet copied into this app:"
          not_copied.each { |name| output.puts "              #{name}" }
          action "Copy this version's migrations: rails generate rails_pulse:upgrade"
        end

        if pending.any?
          output.puts "Migrations: #{pending.size} migration file(s) present but not run:"
          pending.each { |name| output.puts "              #{name}" }
          action "Run pending migrations: #{migrate_command}"
        end
      end

      def print_route_backfill
        unless RailsPulse::SchemaCheck.current?
          output.puts "Routes:     (skipped — schema is behind)"
          return
        end

        backfill = RailsPulse::Route.needs_action_backfill?
        index = RailsPulse::RouteIndexes.exists?(RailsPulse::ApplicationRecord.connection)

        if !backfill && index
          output.puts "Routes:     actions backfilled, unrecognised-path index present"
          return
        end

        output.puts "Routes:     #{backfill ? 'actions NOT backfilled' : 'actions backfilled'}, " \
                    "unrecognised-path index #{index ? 'present' : 'MISSING'}"
        action "Backfill route actions and create the unrecognised-path index: rails rails_pulse:migrate_routes"
      rescue StandardError => e
        output.puts "Routes:     could not check (#{e.class}: #{e.message})"
      end

      def print_initializer
        path = Rails.root.join("config", "initializers", "rails_pulse.rb")
        unless path.exist?
          output.puts "Initializer: config/initializers/rails_pulse.rb not found"
          action "Create the initializer: rails generate rails_pulse:install"
          return
        end

        missing = RailsPulse::Installers::ConfigUpdater.missing(destination: path.to_s)
        keys = missing[:keys] + missing[:hash_keys]
        if keys.empty?
          output.puts "Initializer: mentions every setting this version knows"
          return
        end

        output.puts "Initializer: #{keys.size} setting(s) from this version not mentioned: #{keys.join(', ')}"
        action "Append the new settings to the initializer: rails generate rails_pulse:upgrade (review with git diff)"
      end

      def print_tracking
        auth = if !config.authentication_enabled
          "disabled"
        elsif config.authentication_method || config.authorize
          "custom hook"
        else
          "HTTP Basic (RAILS_PULSE_PASSWORD #{ENV["RAILS_PULSE_PASSWORD"].to_s.empty? ? 'NOT set' : 'set'})"
        end

        output.puts "Tracking:   enabled=#{config.enabled} requests=#{config.enabled} jobs=#{config.track_jobs} " \
                    "exceptions=#{config.track_exceptions} async=#{config.async}"
        output.puts "Dashboard:  mount_dashboard=#{config.mount_dashboard} authentication=#{auth}"
      end

      def print_summaries
        last = RailsPulse::Summary.maximum(:updated_at)
        if last.nil?
          output.puts "Summaries:  none generated yet (schedule RailsPulse::SummaryJob hourly; backfill with rails rails_pulse:backfill_summaries)"
        elsif last < 2.hours.ago
          output.puts "Summaries:  last generated #{time_ago(last)} — stale (is RailsPulse::SummaryJob scheduled?)"
        else
          output.puts "Summaries:  last generated #{time_ago(last)}"
        end
      rescue StandardError => e
        output.puts "Summaries:  could not check (#{e.class}: #{e.message})"
      end

      def print_actions
        output.puts
        if @actions.empty?
          output.puts "OK — nothing to do."
        else
          output.puts "Action needed:"
          @actions.each { |text| output.puts "  - #{text}" }
        end
      end

      # -- helpers ------------------------------------------------------------

      def gem_migrations_not_in_host
        gem_dir = RailsPulse::Engine.root.join("db", "rails_pulse_migrate")
        return [] unless gem_dir.directory?

        host = %w[db/migrate db/rails_pulse_migrate].flat_map do |dir|
          Dir.glob(Rails.root.join(dir, "*.rb").to_s).map { |f| File.basename(f) }
        end
        Dir.glob(gem_dir.join("*.rb").to_s).map { |f| File.basename(f) }.sort - host
      end

      # Migration files on disk whose version is not recorded on the Pulse
      # connection. Names only; the versions are in the filenames.
      def pending_migrations
        context = RailsPulse::ApplicationRecord.connection_pool.migration_context
        applied = context.get_all_versions
        context.migrations.reject { |m| applied.include?(m.version) }.map { |m| File.basename(m.filename) }
      rescue StandardError
        []
      end

      def upgrade_commands
        [ "rails generate rails_pulse:upgrade", migrate_command, "rails rails_pulse:migrate_routes" ]
      end

      def migrate_command
        config.connects_to.present? ? "rails db:migrate:rails_pulse" : "rails db:migrate"
      end

      def time_ago(time)
        seconds = (Time.current - time).to_i
        return "#{seconds}s ago" if seconds < 60
        return "#{seconds / 60}m ago" if seconds < 3600
        return "#{seconds / 3600}h ago" if seconds < 86_400

        "#{seconds / 86_400}d ago"
      end
    end
  end
end
