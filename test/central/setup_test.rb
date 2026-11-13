require_relative "test_helper"
require "rails/generators/test_case"
require "generators/rails_pulse/upgrade_generator"
require_relative "../support/generator_test_helpers"

module RailsPulse
  # What a central's db:prepare and the upgrade generator do with a database
  # per application.
  class CentralSchemaTest < CentralTestCase
    # Structure Tests

    test "every application's database has the Rails Pulse tables db:prepare loaded" do
      %i[alpha beta].each do |name|
        in_application(name) do
          assert_empty RailsPulse::SchemaCheck.missing, "#{name} is missing tables"
        end
      end
    end

    test "loading the schema again leaves databases that have it alone" do
      Rake::Task["db:schema:load_rails_pulse"].reenable
      output = StringIO.new
      original_stdout = $stdout
      $stdout = output
      Rake::Task["db:schema:load_rails_pulse"].invoke

      assert_includes output.string, "Rails Pulse tables already exist for alpha"
      assert_includes output.string, "Rails Pulse tables already exist for beta"
    ensure
      $stdout = original_stdout
    end

    test "db:prepare and db:migrate load the schema into a new application's database first" do
      assert_includes Rake::Task["db:prepare"].prerequisites, "db:rails_pulse:prepare_central_schema"
      assert_includes Rake::Task["db:migrate"].prerequisites, "db:rails_pulse:load_central_schema"
    end

    test "db:prepare acts on test as well as development, as Rails does, unless told not to" do
      assert_equal %w[development test], RailsPulse::Central.task_environments("development")
      assert_equal %w[test], RailsPulse::Central.task_environments("test")
      assert_equal %w[production], RailsPulse::Central.task_environments(:production)

      with_env("SKIP_TEST_DATABASE" => "1") { assert_equal %w[development], RailsPulse::Central.task_environments("development") }
      with_env("DATABASE_URL" => "sqlite3:storage/x.sqlite3") { assert_equal %w[development], RailsPulse::Central.task_environments("development") }
    end

    test "every application's database records the environment it belongs to" do
      %i[alpha beta].each do |name|
        in_application(name) do
          assert_equal "test", RailsPulse::ApplicationRecord.connection_pool.internal_metadata[:environment]
        end
      end
    end

    private

    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
  end

  # What a parallel worker's empty copy of an application's database gets
  # from load_schema, which a host calls from parallelize_setup. Rails points
  # each worker's database configurations at fresh files the same way.
  class CentralLoadSchemaTest < CentralTestCase
    self.use_transactional_tests = false

    setup do
      @dir = Dir.mktmpdir("rails_pulse_central_load_schema")
      @migrations = File.join(@dir, "rails_pulse_migrate").tap { |path| FileUtils.mkdir_p(path) }
      %w[20260101000000_add_widgets 20260102000000_add_gadgets].each do |name|
        File.write(File.join(@migrations, "#{name}.rb"), "class #{name.sub(/\A\d+_/, '').camelize} < ActiveRecord::Migration[7.2]; end\n")
      end
      @db_config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "pulse_alpha", include_hidden: true)
      @original_database = @db_config.database
      @worker_database = File.join(@dir, "worker_pulse_alpha.sqlite3")
      @db_config._database = @worker_database
    end

    teardown do
      @db_config&._database = @original_database
      FileUtils.rm_rf(@dir) if @dir
    end

    # Structure Tests

    test "an empty database gets the tables, its migrations marked as applied, and its environment" do
      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)

      assert_includes worker_tables, "rails_pulse_routes"
      assert_includes worker_tables, "rails_pulse_rollups"
      assert_equal %w[20260101000000 20260102000000], worker_rows("SELECT version FROM schema_migrations ORDER BY version")
      assert_equal [ "test" ], worker_rows("SELECT value FROM ar_internal_metadata WHERE key = 'environment'")
    end

    test "the shard it loads through is gone afterwards" do
      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)

      assert_nil RailsPulse::ApplicationRecord.connection_handler.retrieve_connection_pool(
        RailsPulse::ApplicationRecord.connection_specification_name, role: :writing, shard: RailsPulse::Central::SCHEMA_LOAD_SHARD
      )
    end

    test "a database that has the tables is left to db:migrate" do
      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)
      File.write(File.join(@migrations, "20260103000000_add_sprockets.rb"), "class AddSprockets < ActiveRecord::Migration[7.2]; end\n")

      output = capture_stdout { RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations) }

      assert_includes output, "Rails Pulse tables already exist for alpha (test)"
      assert_not_includes worker_rows("SELECT version FROM schema_migrations"), "20260103000000", "a pending migration stays pending"
    end

    # Edge Cases

    test "a database with the tables but no environment gets one" do
      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)
      worker_execute("DELETE FROM ar_internal_metadata WHERE key = 'environment'")

      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)

      assert_equal [ "test" ], worker_rows("SELECT value FROM ar_internal_metadata WHERE key = 'environment'")
    end

    test "an environment already recorded is never replaced" do
      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)
      worker_execute("UPDATE ar_internal_metadata SET value = 'production' WHERE key = 'environment'")

      RailsPulse::Central.load_schema(environments: [ "test" ], migrations_path: @migrations, quiet: true)

      assert_equal [ "production" ], worker_rows("SELECT value FROM ar_internal_metadata WHERE key = 'environment'")
    end

    test "an environment with no database for an application is skipped" do
      assert_nothing_raised { RailsPulse::Central.load_schema(environments: [ "staging" ], quiet: true) }
    end

    test "with no schema file it says what to run" do
      output = capture_stdout { RailsPulse::Central.load_schema(schema_file: File.join(@dir, "missing.rb")) }

      assert_includes output, "rails generate rails_pulse:install"
      assert_not File.exist?(@worker_database)
    end

    private

    def worker_rows(sql)
      database = SQLite3::Database.new(@worker_database)
      database.execute(sql).map(&:first)
    ensure
      database&.close
    end

    def worker_execute(sql)
      database = SQLite3::Database.new(@worker_database)
      database.execute(sql)
    ensure
      database&.close
    end

    def worker_tables
      worker_rows("SELECT name FROM sqlite_master WHERE type = 'table'")
    end

    def capture_stdout
      original_stdout = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original_stdout
    end
  end

  # The database tasks the dashboard suggests run once per application on a
  # central, or for the one RAILS_PULSE_APPLICATION names.
  class CentralDatabaseTasksTest < CentralTestCase
    setup do
      RailsPulse::BackfillSummariesJob.any_instance.stubs(:sleep)
      in_application(:alpha) do
        route = RailsPulse::Route.find_or_create_for_request("GET", "/alpha", controller_action: "pages#show")
        RailsPulse::Request.create!(route: route, method: "GET", duration: 50, status: 200, is_error: false,
                                    request_uuid: SecureRandom.uuid, controller_action: "pages#show", occurred_at: 3.hours.ago)
      end
    end

    teardown do
      ENV.delete("RAILS_PULSE_APPLICATION")
    end

    test "rails_pulse:backfill_summaries summarizes every application in its own database" do
      output = run_task("rails_pulse:backfill_summaries")

      assert_includes output, "== alpha"
      assert_includes output, "== beta"
      assert_includes output, "No Rails Pulse data found"
      in_application(:alpha) { assert_predicate RailsPulse::Summary, :exists? }
      in_application(:beta) { assert_not RailsPulse::Summary.exists? }
    end

    test "RAILS_PULSE_APPLICATION runs a task for that application only" do
      ENV["RAILS_PULSE_APPLICATION"] = "beta"

      output = run_task("rails_pulse:backfill_summaries")

      assert_not_includes output, "== alpha"
      in_application(:alpha) { assert_not RailsPulse::Summary.exists? }
    end

    test "an application the central does not list stops the task" do
      ENV["RAILS_PULSE_APPLICATION"] = "gamma"

      assert_raises(SystemExit) { run_task("rails_pulse:backfill_summaries") }
    end

    test "rails_pulse:cleanup cleans every application's database" do
      run_task("rails_pulse:cleanup")

      in_application(:alpha) { assert_predicate RailsPulse::CleanupRun.events, :exists? }
      in_application(:beta) { assert_predicate RailsPulse::CleanupRun.events, :exists? }
    end

    private

    def run_task(name)
      Rake::Task[name].reenable
      output = StringIO.new
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = output
      $stderr = output
      Rake::Task[name].invoke
      output.string
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  class CentralUpgradeGeneratorTest < Rails::Generators::TestCase
    include GeneratorTestHelpers

    tests RailsPulse::Generators::UpgradeGenerator

    def destination_root
      @destination_root ||= File.expand_path("../tmp/central_upgrade_generator_test/#{name}", __dir__)
    end

    setup do
      skip "central mode tests run in their own process: rake test_central" unless RailsPulse::Central.enabled?

      prepare_destination
      setup_test_app_with_schema
      FileUtils.mkdir_p(File.join(destination_root, "db/rails_pulse_migrate"))
      RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:gem_migrations_path).returns(gem_migrations_path)
    end

    teardown do
      FileUtils.rm_rf(destination_root)
    end

    test "a central's upgrade copies new migrations to db/rails_pulse_migrate, which db:migrate runs for every application" do
      create_gem_migration("add_widget_to_rails_pulse_routes")

      output = run_generator([], {})

      assert_match(/Detected database setup: central/, output)
      assert_equal 1, Dir[File.join(destination_root, "db/rails_pulse_migrate/*_add_widget_to_rails_pulse_routes.rb")].size
      assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
      assert_match(/rails db:migrate\b(?!:)/, output)
    end
  end
end
