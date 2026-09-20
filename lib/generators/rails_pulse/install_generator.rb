require_relative "base_methods"

module RailsPulse
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      include BaseMethods

      source_root File.expand_path("templates", __dir__)

      desc "Install Rails Pulse with flexible database setup options"

      class_option :database, type: :string, default: "single",
                   desc: "Database setup: 'single' (default) or 'separate'"

      def copy_schema
        copy_file "db/rails_pulse_schema.rb", "db/rails_pulse_schema.rb"
      end

      def create_migration_directory
        create_file "db/rails_pulse_migrate/.keep"
      end

      def copy_initializer
        copy_file "rails_pulse.rb", "config/initializers/rails_pulse.rb"
      end

      def setup_database_configuration
        if separate_database?
          create_separate_database_setup
        else
          create_single_database_setup
        end
      end

      def display_post_install_message
        if separate_database?
          display_separate_database_message
        else
          display_single_database_message
        end
      end

      private

      def separate_database?
        options[:database] == "separate"
      end

      def create_separate_database_setup
        say "Setting up separate database configuration...", :green

        # Migration directory already created by create_migration_directory
        # Could add database.yml configuration here if needed
        # For now, users will configure manually
      end

      def create_single_database_setup
        say "Setting up single database configuration...", :green

        # Create a migration that loads the schema
        migration_template(
          "migrations/install_rails_pulse_tables.rb",
          "db/migrate/install_rails_pulse_tables.rb"
        )
      end

      def display_separate_database_message
        say <<~MESSAGE

          Rails Pulse installation complete! (Separate Database Setup)

          Next steps:
          1. Add Rails Pulse database configuration to config/database.yml:

             #{Rails.env}:
               rails_pulse:
                 <<: *default
                 database: storage/#{Rails.env}_rails_pulse.sqlite3
                 migrations_paths: db/rails_pulse_migrate
                 schema_dump: false

          Repeat this entry for each environment (development, test, production).

          schema_dump: false is required so Rails does not dump or load
          db/rails_pulse_structure.sql. Keep database_tasks enabled so
          rails db:migrate:rails_pulse still runs upgrades.

          2. Uncomment config.connects_to in config/initializers/rails_pulse.rb
             so Rails Pulse models use the rails_pulse connection. Without it
             every model keeps writing to your primary database.
          3. Run: rails db:prepare (creates database and loads schema)
          4. Restart your Rails server

          The schema file db/rails_pulse_schema.rb is your single source of truth.
          Future upgrades will automatically copy new migrations to db/rails_pulse_migrate/

        MESSAGE
      end

      def display_single_database_message
        say <<~MESSAGE

          Rails Pulse installation complete! (Single Database Setup)

          Next steps:
          1. Run: rails db:migrate (creates Rails Pulse tables in your main database)
          2. Restart your Rails server

          The schema file db/rails_pulse_schema.rb is your single source of truth.
          Future upgrades will automatically copy new migrations to db/migrate/

          Note: The installation migration loads from db/rails_pulse_schema.rb
          and includes all current Rails Pulse tables and columns.

        MESSAGE
      end
    end
  end
end
