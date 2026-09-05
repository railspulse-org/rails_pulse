require "test_helper"
require "generators/rails_pulse/upgrade_generator"
require_relative "../support/generator_test_helpers"
require "ostruct"
require "ripper"

class UpgradeGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestHelpers

  tests RailsPulse::Generators::UpgradeGenerator

  def destination_root
    # Use test-specific directory to avoid parallel test interference
    @destination_root ||= File.expand_path("../tmp/upgrade_generator_test/#{name}", __dir__)
  end

  setup do
    prepare_destination
    setup_test_app_with_schema

    # Stub the generator to use test-specific gem migrations path
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:gem_migrations_path).returns(gem_migrations_path)
    # The database behind the generator is the dummy app's; pin the two
    # "outstanding work" probes so each test controls them explicitly.
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:pending_migration_files).returns([])
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:route_backfill_outstanding?).returns(false)
  end

  teardown do
    FileUtils.rm_rf(gem_migrations_path)
    RailsPulse::Generators::UpgradeGenerator.any_instance.unstub(:gem_migrations_path)
    RailsPulse::Generators::UpgradeGenerator.any_instance.unstub(:pending_migration_files)
    RailsPulse::Generators::UpgradeGenerator.any_instance.unstub(:route_backfill_outstanding?)
  end

  # Database Detection Tests

  test "detects single database setup by default" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Detected database setup: single/, output)
  end

test "detects separate database setup from database.yml" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)

    output = run_generator([], { database: "separate" })

    assert_match(/Detected database setup: separate/, output)
  end

  test "detects single database setup when database.yml uses YAML aliases" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml_with_aliases)

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Detected database setup: single/, output)
  end

  test "detects separate database setup when database.yml uses YAML aliases" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml_with_aliases)

    # Tables exist only on the ApplicationRecord connection (separate DB), not on
    # the primary ActiveRecord::Base connection — the real separate-database scenario.
    output = mock_tables_exist_on_app_record_only do
      run_generator([], {})
    end

    assert_match(/Detected database setup: separate/, output)
  end

  test "auto-detects separate database without explicit flag when tables are on separate connection" do
    # This is the regression test for issue #166 Bug 1: the generator was returning
    # :schema_only for separate-DB users because it checked ActiveRecord::Base.connection
    # (primary DB, no tables) before checking has_separate_database_config?.
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)

    output = mock_tables_exist_on_app_record_only do
      run_generator([], {})
    end

    assert_match(/Detected database setup: separate/, output)
    assert_no_match(/schema detected but no tables found/, output)
  end

  test "detects schema_only when schema exists but no tables" do
    output = mock_no_tables_exist do
      run_generator([], {})
    end

    assert_match(/schema detected but no tables found/, output)
  end

  test "detects not_installed when no schema and no tables" do
    FileUtils.rm_f(File.join(destination_root, "db/rails_pulse_schema.rb"))

    assert_raises SystemExit do
      mock_no_tables_exist do
        run_generator([], {})
      end
    end
  end

  # Single Database Migration Copying Tests

  test "single database upgrade copies new migrations from gem" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("add_new_feature", "20251019000000")

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Found 1 new migration/, output)
    assert_file "db/migrate/20251019000000_add_new_feature.rb"
    assert_no_match(/rails rails_pulse:migrate_routes/, output)
    assert_no_match(/IMPORTANT: This upgrade changes how routes are identified/, output)
  end

  test "single database upgrade copies multiple new migrations" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("add_feature_one", "20251019000000")
    create_gem_migration("add_feature_two", "20251019000001")

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Found 2 new migration/, output)
    assert_file "db/migrate/20251019000000_add_feature_one.rb"
    assert_file "db/migrate/20251019000001_add_feature_two.rb"
  end

  test "single database upgrade warns when copying route identity migrations" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("change_rails_pulse_routes_to_multi_verb_model", "20260610000002")

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/IMPORTANT: This upgrade changes how routes are identified/, output)
    assert_match(/Action column empty/, output)
    assert_match(/rails rails_pulse:migrate_routes/, output)
  end

  test "single database upgrade doesn't copy existing migrations" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("add_tags_to_rails_pulse_tables", "20251018000000")

    # Pre-create the migration in user's app
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(
      File.join(destination_root, "db/migrate/20251018000000_add_tags_to_rails_pulse_tables.rb"),
      "# Already migrated"
    )

    mock_tables_exist do
      run_generator([], {})
    end

    # File should not be overwritten - verify content is unchanged
    assert_file "db/migrate/20251018000000_add_tags_to_rails_pulse_tables.rb" do |content|
      assert_match(/# Already migrated/, content)
      assert_no_match(/add_column/, content)
    end
  end

  test "prints exception tracking notice when exceptions migration is newly copied" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("create_rails_pulse_exceptions", "20260506000001")

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Exception tracking \(opt-in\)/, output)
    assert_match(/rails_pulse_exception_groups/, output)
    assert_match(/rails_pulse_exception_occurrences/, output)
    assert_match(/config\.track_exceptions = true/, output)
    assert_match(/delete the copied/, output)
    assert_file "db/migrate/20260506000001_create_rails_pulse_exceptions.rb"
  end

  test "appends missing initializer settings and preserves existing values" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(
      File.join(destination_root, "config/initializers/rails_pulse.rb"),
      <<~RUBY
        RailsPulse.configure do |config|
          config.enabled = true
          config.tags = [ "keep-me" ]
          config.max_table_records = {
            rails_pulse_requests: 42,
            rails_pulse_queries: 500
          }
        end
      RUBY
    )
    create_gem_migration("add_new_feature", "20251019000000")

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Updated config\/initializers\/rails_pulse\.rb/, output)
    assert_match(/config\.track_exceptions/, output)
    assert_match(/git diff/, output)
    assert_file "config/initializers/rails_pulse.rb" do |content|
      assert_match(/config\.tags = \[ "keep-me" \]/, content)
      assert_match(/rails_pulse_requests: 42/, content)
      assert_match(/config\.track_exceptions = false/, content)
      assert_match(/config\.capture_exception_params = true/, content)
      assert_match(/rails_pulse_exception_occurrences/, content)
    end
  end

  test "does not print exception tracking notice when exceptions migration already present" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    create_gem_migration("create_rails_pulse_exceptions", "20260506000001")
    create_gem_migration("add_unrelated_feature", "20260507000001")

    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(
      File.join(destination_root, "db/migrate/20260506000001_create_rails_pulse_exceptions.rb"),
      "# Already migrated"
    )

    output = mock_tables_exist do
      run_generator([], {})
    end

    assert_match(/Found 1 new migration/, output)
    assert_no_match(/Exception tracking \(new\)/, output)
  end

# Separate Database Migration Copying Tests

test "separate database upgrade copies migrations to rails_pulse_migrate" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)
    create_gem_migration("add_new_feature", "20251019000000")

    output = mock_tables_exist do
      run_generator([], { database: "separate" })
    end

    assert_match(/Found 1 new migration/, output)
    assert_file "db/rails_pulse_migrate/20251019000000_add_new_feature.rb"
    assert_match(/rails db:migrate:rails_pulse/, output)
    assert_no_match(/rails rails_pulse:migrate_routes/, output)
  end

  test "separate database upgrade warns when schema_dump is not false" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml_without_schema_dump)
    create_gem_migration("add_new_feature", "20251019000000")

    output = mock_tables_exist do
      run_generator([], { database: "separate" })
    end

    assert_match(/Add schema_dump: false/, output)
    assert_match(/rails_pulse_structure\.sql/, output)
  end

  test "separate database upgrade does not warn when schema_dump is false" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)
    create_gem_migration("add_new_feature", "20251019000000")

    output = mock_tables_exist do
      run_generator([], { database: "separate" })
    end

    assert_no_match(/Add schema_dump: false/, output)
  end

  # Missing Column Detection Tests

  # Outstanding Work Tests

  test "says up to date only when nothing is pending" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:detect_missing_columns).returns({})

    output = mock_complete_tables { run_generator([], {}) }

    assert_match(/Rails Pulse is up to date! No migration needed/, output)
    assert_no_match(/not up to date/, output)
  end

  test "reports migration files that are present but have not been run" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:detect_missing_columns).returns({})
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:pending_migration_files)
      .returns([ "20260610000002_change_rails_pulse_routes_to_multi_verb_model.rb" ])

    output = mock_complete_tables { run_generator([], {}) }

    assert_no_match(/up to date! No migration needed/, output)
    assert_match(/1 migration file\(s\) have not been run/, output)
    assert_match(/20260610000002_change_rails_pulse_routes_to_multi_verb_model\.rb/, output)
    assert_match(/1\. Run: rails db:migrate/, output)
    # The unrun file is a route identity migration, so the backfill is announced too.
    assert_match(/rails rails_pulse:migrate_routes/, output)
    assert_match(/IMPORTANT: This upgrade changes how routes are identified/, output)
  end

  test "reports an outstanding route backfill even when every migration has run" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:detect_missing_columns).returns({})
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:route_backfill_outstanding?).returns(true)

    output = mock_complete_tables { run_generator([], {}) }

    assert_no_match(/up to date! No migration needed/, output)
    assert_match(/Route actions have not been backfilled/, output)
    assert_match(/rails rails_pulse:migrate_routes/, output)
  end

  test "separate database pending migrations name the rails_pulse migrate command" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)
    RailsPulse::Generators::UpgradeGenerator.any_instance.stubs(:pending_migration_files)
      .returns([ "20260419000001_add_p95_p99_duration_to_rails_pulse_jobs.rb" ])

    output = run_generator([], { database: "separate" })

    assert_match(/have not been run/, output)
    assert_match(/1\. Run: rails db:migrate:rails_pulse/, output)
    assert_no_match(/migrate_routes/, output)
  end

  test "generates migration for missing columns when no new migrations" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)

    output = mock_tables_with_missing_columns do
      run_generator([], {})
    end

    assert_match(/Creating upgrade migration for missing columns/, output)
    assert_migration "db/migrate/upgrade_rails_pulse_tables.rb" do |content|
      assert_match(/add_column :rails_pulse_routes, :tags, :text/, content)
    end
  end

  test "generated migration escapes quotes inside column comments" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)

    mock_tables_with_missing_columns do
      run_generator([], {})
    end

    assert_migration "db/migrate/upgrade_rails_pulse_tables.rb" do |content|
      assert_includes content,
        %{comment: "JSON array of HTTP methods accepted by this route (e.g., [\\"GET\\",\\"POST\\"])"}
      assert_not_nil Ripper.sexp(content), "Generated migration is not valid Ruby:\n#{content}"
    end
  end

  test "separate database generates migration for missing columns" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)

    output = mock_tables_with_missing_columns do
      run_generator([], { database: "separate" })
    end

    assert_migration "db/rails_pulse_migrate/upgrade_rails_pulse_tables.rb" do |content|
      assert_match(/add_column :rails_pulse_routes, :tags, :text/, content)
    end
  end

  # Helper Methods

  private

  def mock_tables_exist
    connection = build_connection_with_tables(complete_schema_columns)
    ActiveRecord::Base.stubs(:connection).returns(connection)
    RailsPulse::ApplicationRecord.stubs(:connection).returns(connection)
    result = yield if block_given?
    ActiveRecord::Base.unstub(:connection)
    RailsPulse::ApplicationRecord.unstub(:connection)
    result
  end

  # Simulates a separate-database user: Rails Pulse tables exist only on the
  # ApplicationRecord connection, not on the primary ActiveRecord::Base connection.
  # This is the scenario that previously triggered the :schema_only false positive.
  def mock_tables_exist_on_app_record_only
    tables_connection = build_connection_with_tables(complete_schema_columns)
    no_tables_connection = build_connection_without_tables

    ActiveRecord::Base.stubs(:connection).returns(no_tables_connection)
    RailsPulse::ApplicationRecord.stubs(:connection).returns(tables_connection)
    result = yield if block_given?
    ActiveRecord::Base.unstub(:connection)
    RailsPulse::ApplicationRecord.unstub(:connection)
    result
  end

  def mock_no_tables_exist
    connection = build_connection_without_tables
    ActiveRecord::Base.stubs(:connection).returns(connection)
    RailsPulse::ApplicationRecord.stubs(:connection).returns(connection)
    result = yield if block_given?
    ActiveRecord::Base.unstub(:connection)
    RailsPulse::ApplicationRecord.unstub(:connection)
    result
  end

  def mock_tables_with_missing_columns
    connection = build_connection_with_tables(schema_without_tags)
    ActiveRecord::Base.stubs(:connection).returns(connection)
    RailsPulse::ApplicationRecord.stubs(:connection).returns(connection)
    result = yield if block_given?
    ActiveRecord::Base.unstub(:connection)
    RailsPulse::ApplicationRecord.unstub(:connection)
    result
  end

  def mock_complete_tables
    connection = build_connection_with_tables(complete_schema_columns)
    ActiveRecord::Base.stubs(:connection).returns(connection)
    RailsPulse::ApplicationRecord.stubs(:connection).returns(connection)
    result = yield if block_given?
    ActiveRecord::Base.unstub(:connection)
    RailsPulse::ApplicationRecord.unstub(:connection)
    result
  end

  def build_connection_with_tables(schema)
    connection = Object.new
    def connection.table_exists?(_table) = true
    connection.define_singleton_method(:columns) do |table|
      (schema[table.to_s.to_sym] || []).map { |col| OpenStruct.new(name: col) }
    end
    connection
  end

  def build_connection_without_tables
    connection = Object.new
    def connection.table_exists?(_table) = false
    connection
  end
end
