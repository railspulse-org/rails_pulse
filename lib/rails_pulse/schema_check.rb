# frozen_string_literal: true

require "generators/rails_pulse/base_methods"

module RailsPulse
  # Answers one question about the live Rails Pulse tables: can this gem
  # version safely read and write them?
  #
  # The answer is "no" exactly when new gem code is running against tables
  # that predate it — a deploy that shipped the gem before `db:migrate`, or a
  # rolling restart that left old and new processes side by side. Without
  # this guard that state surfaces as a "Failed to persist tracking data"
  # log line on every request and a 500 on every dashboard page. With it,
  # tracking pauses after one warning and the dashboard explains what to run.
  #
  # The comparison is deliberately explicit and small: every Rails Pulse
  # table must exist, and SENTINEL_COLUMNS lists the columns that incremental
  # migrations have added since a table was first created (see
  # db/rails_pulse_migrate). Presence only, never types. It runs at most once
  # per process, and any database error is treated as "not outdated" so a
  # booting app without a database (assets precompile, db:create) is never
  # blocked. `config.schema_check_enabled = false` turns it off entirely.
  module SchemaCheck
    UPGRADE_INSTRUCTIONS = [
      "rails generate rails_pulse:upgrade",
      "rails db:migrate                  # separate Pulse database: rails db:migrate:rails_pulse",
      "rails rails_pulse:migrate_routes  # once, after the route identity migrations"
    ].freeze

    # Every table the gem expects. Kept in one place already; reused here so a
    # new table is covered as soon as it is added there.
    REQUIRED_TABLES = RailsPulse::Generators::BaseMethods::RAILS_PULSE_TABLES

    # Columns added by incremental migrations after the table itself was
    # introduced. When db/rails_pulse_migrate gains a migration that adds a
    # column the models depend on, add it here too (CLAUDE.md lists the other
    # places); test/lib/rails_pulse/schema_check_test.rb checks every entry
    # against db/rails_pulse_schema.rb so the list cannot drift from it.
    SENTINEL_COLUMNS = {
      "rails_pulse_routes" => %w[controller_action http_methods],
      "rails_pulse_requests" => %w[method response_size_bytes],
      "rails_pulse_operations" => %w[actual_sql row_count repeated_query_group],
      "rails_pulse_jobs" => %w[p95_duration p99_duration],
      "rails_pulse_exception_groups" => %w[location]
    }.freeze

    class << self
      def enabled?
        RailsPulse.configuration.schema_check_enabled
      end

      def current?
        missing.empty?
      end

      # { "rails_pulse_routes" => ["http_methods", "controller_action"] }
      # for a table missing columns, { "rails_pulse_exception_groups" => [:table] }
      # for a table that does not exist at all. Empty when everything is present
      # or the check is disabled.
      def missing
        return {} unless enabled?

        cached = @missing
        return cached if cached

        result = compute_missing
        # Only remember a completed comparison; a database error is retried
        # on the next call rather than cached as either answer.
        @missing = result unless result.nil?
        result || {}
      end

      # Tracking entry points call this instead of writing straight away. The
      # first refusal logs the upgrade instructions; later ones are silent.
      def tracking_allowed?
        return true if current?

        warn_once!
        false
      end

      def warn_once!
        return if @warned

        @warned = true
        RailsPulse.logger.error(warning_message)
      end

      def warning_message
        lines = missing.map do |table, columns|
          columns == [ :table ] ? "  #{table} (table missing)" : "  #{table}: #{columns.join(', ')}"
        end
        <<~MESSAGE.chomp
          Rails Pulse #{RailsPulse::VERSION} is running against a database that has not been migrated for it.
          Tracking is paused and the dashboard is unavailable until the schema is upgraded. Missing:
          #{lines.join("\n")}
          To upgrade:
          #{UPGRADE_INSTRUCTIONS.map { |line| "  #{line}" }.join("\n")}
          (Set config.schema_check_enabled = false to disable this check.)
        MESSAGE
      end

      # The table => [column] map the check enforces.
      def expected_schema
        REQUIRED_TABLES.each_with_object({}) do |table, expected|
          expected[table] = SENTINEL_COLUMNS.fetch(table, [])
        end
      end

      def reset!
        @missing = nil
        @warned = nil
      end

      private

      def compute_missing
        connection = RailsPulse::ApplicationRecord.connection
        expected_schema.each_with_object({}) do |(table, columns), missing|
          unless connection.table_exists?(table)
            missing[table] = [ :table ]
            next
          end

          absent = columns - connection.columns(table).map(&:name)
          missing[table] = absent if absent.any?
        end
      rescue StandardError
        # ActiveRecord::ActiveRecordError plus whatever the adapter raises
        # (PG::Error, SQLite3::Exception, Mysql2::Error) when the database is
        # not there yet. Unknown, not outdated.
        nil
      end
    end
  end
end
