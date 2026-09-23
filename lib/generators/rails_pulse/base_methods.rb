# frozen_string_literal: true

module RailsPulse
  module Generators
    module BaseMethods
      # Authoritative list of Rails Pulse tables (from schema file)
      RAILS_PULSE_TABLES = %w[
        rails_pulse_routes
        rails_pulse_queries
        rails_pulse_requests
        rails_pulse_operations
        rails_pulse_jobs
        rails_pulse_job_runs
        rails_pulse_summaries
        rails_pulse_deployments
        rails_pulse_exception_groups
        rails_pulse_exception_occurrences
        rails_pulse_events
      ].freeze

      # Generate next migration number for timestamped migrations
      # Used by all three generators (install, upgrade, convert)
      # This method is called by Rails generators, so it needs to be defined
      # on the class that includes this module
      module ClassMethods
        def next_migration_number(path)
          next_number = current_migration_number(path) + 1
          ActiveRecord::Migration.next_migration_number(next_number)
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      private

      # Check if Rails Pulse tables exist in database
      # Returns false if database connection unavailable or tables missing
      def rails_pulse_tables_exist?
        return false unless defined?(ActiveRecord::Base)

        connection = ActiveRecord::Base.connection
        RAILS_PULSE_TABLES.all? { |table| connection.table_exists?(table) }
      rescue ActiveRecord::ConnectionNotEstablished, StandardError
        false
      end

      # Get root path (destination_root in tests, Rails.root in production)
      def root_path
        respond_to?(:destination_root) ? destination_root : Rails.root
      end

      # Path to gem's incremental migrations directory
      def gem_migrations_path
        File.expand_path("../../../db/rails_pulse_migrate", __dir__)
      end
    end
  end
end
