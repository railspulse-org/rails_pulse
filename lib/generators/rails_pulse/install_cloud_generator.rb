require_relative "base_methods"

module RailsPulse
  module Generators
    # Adds the tables Rails Pulse Cloud's sync needs to an existing Rails
    # Pulse install. Kept out of rails_pulse:install so an app that never
    # uses Cloud never has them: like the main install, it copies a schema
    # file (db/rails_pulse_cloud_schema.rb) and a migration that loads it.
    class InstallCloudGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      include BaseMethods

      source_root File.expand_path("templates", __dir__)

      desc "Install the Rails Pulse Cloud tables into an existing Rails Pulse setup"

      class_option :database, type: :string, default: "detect",
                   desc: "Database setup: 'single', 'separate', or 'detect' (default)"

      def check_rails_pulse_installed
        return if File.exist?(File.join(root_path, "db/rails_pulse_schema.rb"))

        say "Rails Pulse not detected. Run 'rails generate rails_pulse:install' first.", :red
        exit 1
      end

      def copy_schema
        copy_file "db/rails_pulse_cloud_schema.rb", "db/rails_pulse_cloud_schema.rb"
      end

      # The migration goes where Rails Pulse's own migrations run. On a
      # separate database that is db/rails_pulse_migrate: the database
      # already exists, so db:migrate:rails_pulse has to create the tables,
      # and a fresh one built by db:prepare loads the schema file instead.
      def copy_migration
        migration_template(
          "migrations/install_rails_pulse_cloud_tables.rb",
          "#{migration_dir}/install_rails_pulse_cloud_tables.rb"
        )
      end

      def display_post_install_message
        say <<~MESSAGE

          Rails Pulse Cloud tables ready to install (#{separate_database? ? 'separate' : 'single'} database setup).

          Next steps:
          1. Run: #{separate_database? ? 'rails db:migrate:rails_pulse' : 'rails db:migrate'}
          2. Set these in config/initializers/rails_pulse.rb (create the key under
             Profile → API keys in Rails Pulse Cloud; application is your app's slug):

               config.cloud.api_key = ENV["RAILS_PULSE_CLOUD_API_KEY"]
               config.cloud.application = "your-app"

          3. Schedule both jobs, for example in config/recurring.yml. Nothing reaches
             Rails Pulse Cloud until they run: RailsPulse::SummaryJob starts the hourly
             sync, and RailsPulse::CloudHealthJob sends the health update every minute.

               rails_pulse_summary:
                 class: RailsPulse::SummaryJob
                 schedule: "5 * * * *"
               rails_pulse_cloud_health:
                 class: RailsPulse::CloudHealthJob
                 schedule: every minute

          4. Check what will be sent: rails rails_pulse:cloud:preview
          5. Restart your Rails server and workers

          The schema file db/rails_pulse_cloud_schema.rb is the source of truth for
          these tables, and rails_pulse:upgrade keeps it current.

        MESSAGE
      end

      private

      def separate_database?
        return options[:database] == "separate" unless options[:database] == "detect"

        has_separate_database_config?
      end

      def migration_dir
        separate_database? ? "db/rails_pulse_migrate" : "db/migrate"
      end
    end
  end
end
