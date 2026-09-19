require "test_helper"

module RailsPulse
  module Dashboard
    class StorageStatusTest < ActiveSupport::TestCase
      fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_requests,
               :rails_pulse_operations, :rails_pulse_summaries, :rails_pulse_jobs,
               :rails_pulse_job_runs, :rails_pulse_exception_groups,
               :rails_pulse_exception_occurrences, :rails_pulse_deployments

      def setup
        @original_max_records = RailsPulse.configuration.max_table_records
        @original_archiving = RailsPulse.configuration.archiving_enabled
        @original_retention = RailsPulse.configuration.full_retention_period
      end

      def teardown
        RailsPulse.configuration.max_table_records = @original_max_records
        RailsPulse.configuration.archiving_enabled = @original_archiving
        RailsPulse.configuration.full_retention_period = @original_retention
      end

      # Structure Tests

      test "tables includes each pulse table" do
        labels = StorageStatus.new.tables.map { |table| table[:label] }

        assert_includes labels, "Operations"
        assert_includes labels, "Requests"
        assert_includes labels, "Queries"
        assert_includes labels, "Summaries"
      end

      test "overview includes headline stats" do
        overview = StorageStatus.new.overview

        assert_kind_of Hash, overview
        assert_includes overview.keys, :hottest_label
        assert_includes overview.keys, :hottest_percent
        assert_includes overview.keys, :total_records
        assert_includes overview.keys, :display_bytes
        assert_includes overview.keys, :cleanup_health
        assert_includes overview.keys, :cleanup_label
      end

      test "overview total_records matches the sum of table counts" do
        status = StorageStatus.new

        assert_equal status.tables.sum { |table| table[:count] }, status.overview[:total_records]
      end

      test "cached sizes are measured once per table within the cache window" do
        StorageStatus.reset_size_cache!
        size_statements = lambda do
          count = 0
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            count += 1 if payload[:sql] =~ /dbstat|pg_total_relation_size|information_schema/i
          end
          yield_result = StorageStatus.new(cached_sizes: true).tables
          ActiveSupport::Notifications.unsubscribe(subscriber)
          [ count, yield_result ]
        end

        first_count, first_tables = size_statements.call
        second_count, second_tables = size_statements.call

        assert_operator first_count, :>, 0
        assert_equal 0, second_count
        assert_equal first_tables.map { |t| t[:bytes] }, second_tables.map { |t| t[:bytes] }
      ensure
        StorageStatus.reset_size_cache!
      end

      test "uncached status measures sizes on every call" do
        StorageStatus.reset_size_cache!
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          count += 1 if payload[:sql] =~ /dbstat|pg_total_relation_size|information_schema/i
        end

        StorageStatus.new.tables
        StorageStatus.new.tables

        assert_operator count, :>=, 2
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # Calculation Tests

      test "reports fill percent against the configured table limit" do
        query_count = RailsPulse::Query.count
        RailsPulse.configuration.max_table_records = { rails_pulse_queries: query_count * 2 }

        table = table_named(:rails_pulse_queries)

        assert_equal query_count, table[:count]
        assert_equal query_count * 2, table[:limit]
        assert_in_delta 50.0, table[:percent], 0.1
        assert_equal :healthy, table[:severity]
        assert_equal "50.0%", table[:percent_label]
      end

      test "marks a table critical when it is at or above 90 percent of its cap" do
        RailsPulse.configuration.max_table_records = { rails_pulse_queries: 1 }

        table = table_named(:rails_pulse_queries)

        assert_operator table[:percent], :>=, 90
        assert_equal :critical, table[:severity]
      end

      test "marks tables without a cap as uncapped" do
        RailsPulse.configuration.max_table_records = { rails_pulse_queries: 500 }

        table = table_named(:rails_pulse_summaries)

        assert_nil table[:limit]
        assert_nil table[:percent]
        assert_equal :uncapped, table[:severity]
        assert_equal "No cap", table[:runway_label]
      end

      test "dashboard_tables returns at most four of the fullest capped tables" do
        RailsPulse.configuration.max_table_records = {
          rails_pulse_queries: RailsPulse::Query.count,
          rails_pulse_operations: 50_000,
          rails_pulse_requests: 10_000,
          rails_pulse_routes: 1_000
        }

        tables = StorageStatus.new.dashboard_tables

        assert_operator tables.size, :<=, 4
        assert_equal :rails_pulse_queries, tables.first[:name]
        assert tables.all? { |table| table[:limit] }
      end

      test "cleanup reflects current configuration" do
        RailsPulse.configuration.archiving_enabled = true
        RailsPulse.configuration.full_retention_period = 2.weeks

        cleanup = StorageStatus.new.cleanup

        assert cleanup[:enabled]
        assert_equal "14 days", cleanup[:retention_label]
      end

      test "retention label renders hours and minutes" do
        RailsPulse.configuration.archiving_enabled = true
        RailsPulse.configuration.full_retention_period = 3.hours

        assert_equal "3 hours", StorageStatus.new.cleanup[:retention_label]

        RailsPulse.configuration.full_retention_period = 45.minutes

        assert_equal "45 minutes", StorageStatus.new.cleanup[:retention_label]
      end

      test "cleanup reports disabled when archiving is off" do
        RailsPulse.configuration.archiving_enabled = false
        RailsPulse::Dashboard::StoragePressure.any_instance.stubs(:pressure_items).returns([])

        cleanup = StorageStatus.new.cleanup

        assert_equal :disabled, cleanup[:health]
        assert_equal "Cleanup off", cleanup[:health_label]
      end

      test "cleanup warns when a pressure item is at warning severity" do
        RailsPulse.configuration.archiving_enabled = true
        RailsPulse::Dashboard::StoragePressure.any_instance.stubs(:pressure_items).returns([ { severity: :warning } ])

        cleanup = StorageStatus.new.cleanup

        assert_equal :warning, cleanup[:health]
        assert_equal "Needs attention", cleanup[:health_label]
      end

      test "database reports the adapter" do
        database = StorageStatus.new.database

        assert_kind_of String, database[:adapter]
        refute_predicate database[:adapter], :blank?
        assert_includes [ true, false ], database[:separate]
      end

      test "database adapter label names the adapter" do
        adapter = StorageStatus.new.database[:adapter]

        if RailsPulse::ApplicationRecord.connection.adapter_name.downcase.include?("sqlite")
          assert_equal "SQLite", adapter
        else
          assert_includes [ "PostgreSQL", "MySQL" ], adapter
        end
      end

      private

      def table_named(name)
        table = StorageStatus.new.tables.find { |entry| entry[:name] == name }

        assert table, "Expected a table named #{name}"
        table
      end
    end
  end
end
