require "test_helper"

# Regression tests for upgrade migrations.
# Each test starts from a historical schema snapshot, runs all current incremental
# migrations in order, then verifies the expected columns and tables exist and that
# records can be inserted into the affected tables.
#
# These tests use DDL directly and cannot be wrapped in transactions, so they
# manage their own schema lifecycle: setup loads a baseline, teardown restores
# the current schema.
class UpgradeMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  # Skip fixture loading — tables are in a historical state during these tests
  def setup_fixtures(*); end
  def teardown_fixtures(*); end

  MIGRATE_DIR = File.expand_path("../../db/rails_pulse_migrate", __dir__)

  MIGRATION_CLASSES = %w[
    AddDiagnosticFields
    AddP95P99DurationToRailsPulseJobs
    ExpandNormalizedQueryColumn
    CreateRailsPulseDeployments
    CreateRailsPulseExceptions
    AddActualQueryToOperations
    CreateRailsPulseJobRuns
    MakeCacheHitOnOperationsNullable
    AddControllerActionToRailsPulseRoutes
    ChangeRailsPulseRoutesToMultiVerbModel
    AddNullActionUniqueIndexToRoutes
    AddLocationToExceptionGroups
    CreateRailsPulseEvents
  ].freeze

  def setup
    @conn = ActiveRecord::Base.connection
    restore_current_schema
  end

  def teardown
    restore_current_schema
  end

  # Structure Tests

  test "upgrade from v0.2.7 adds controller_action to routes" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_routes, :controller_action), "controller_action missing on routes"

    col = @conn.columns(:rails_pulse_routes).find { |c| c.name == "controller_action" }

    assert col.null, "controller_action should be nullable"
  end

    test "upgrade from v0.3.3 converts routes to multi-verb model" do
      load_baseline(RailsPulse::TestSchemas::V033)
      run_all_migrations

      assert @conn.column_exists?(:rails_pulse_routes, :http_methods), "http_methods missing on routes"
      assert_not @conn.column_exists?(:rails_pulse_routes, :method), "old method column should be removed"
      assert @conn.column_exists?(:rails_pulse_requests, :method), "method column missing on requests"
      assert @conn.column_exists?(:rails_pulse_routes, :controller_action)

      http_methods_col = @conn.columns(:rails_pulse_routes).find { |c| c.name == "http_methods" }

      assert_not http_methods_col.null, "http_methods should be NOT NULL after upgrade"
    end

    test "upgrade from v0.3.3 creates exception tables and keeps existing 0.3.3 columns" do
      load_baseline(RailsPulse::TestSchemas::V033)
      run_all_migrations

      assert @conn.table_exists?(:rails_pulse_exception_groups)
      assert @conn.table_exists?(:rails_pulse_exception_occurrences)
      assert @conn.column_exists?(:rails_pulse_exception_groups, :location)
      assert @conn.table_exists?(:rails_pulse_deployments)
      assert @conn.column_exists?(:rails_pulse_operations, :actual_sql)
    end

    test "upgrade from v0.3.3 keeps GET and POST on the same path as separate routes" do
      load_baseline(RailsPulse::TestSchemas::V033)

      now = Time.current.strftime("%Y-%m-%d %H:%M:%S")
      @conn.execute(<<~SQL)
        INSERT INTO rails_pulse_routes (method, path, created_at, updated_at)
        VALUES ('GET', '/users', '#{now}', '#{now}')
      SQL
      get_id = @conn.select_value("SELECT id FROM rails_pulse_routes WHERE method = 'GET' AND path = '/users'")

      @conn.execute(<<~SQL)
        INSERT INTO rails_pulse_routes (method, path, created_at, updated_at)
        VALUES ('POST', '/users', '#{now}', '#{now}')
      SQL
      post_id = @conn.select_value("SELECT id FROM rails_pulse_routes WHERE method = 'POST' AND path = '/users'")

      is_error_value = @conn.adapter_name.downcase == "postgresql" ? "false" : "0"
      get_uuid = "upgrade-033-get-#{SecureRandom.hex(4)}"
      post_uuid = "upgrade-033-post-#{SecureRandom.hex(4)}"

      @conn.execute(<<~SQL)
        INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at)
        VALUES (#{get_id}, 10, 200, #{is_error_value}, '#{get_uuid}', '#{now}', '#{now}', '#{now}')
      SQL
      @conn.execute(<<~SQL)
        INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at)
        VALUES (#{post_id}, 20, 201, #{is_error_value}, '#{post_uuid}', '#{now}', '#{now}', '#{now}')
      SQL

      run_all_migrations

      rows = @conn.select_all("SELECT id, http_methods, controller_action FROM rails_pulse_routes WHERE path = '/users' ORDER BY id").to_a

      assert_equal 2, rows.size, "GET /users and POST /users must remain two routes until migrate_routes backfills actions"
      assert rows.all? { |row| row["controller_action"].nil? }

      methods = rows.map { |row| JSON.parse(row["http_methods"]) }.sort

      assert_equal [ [ "GET" ], [ "POST" ] ], methods
      assert_equal "GET", @conn.select_value("SELECT method FROM rails_pulse_requests WHERE request_uuid = '#{get_uuid}'")
      assert_equal "POST", @conn.select_value("SELECT method FROM rails_pulse_requests WHERE request_uuid = '#{post_uuid}'")
    end

    test "can insert records after upgrading from v0.3.3" do
      load_baseline(RailsPulse::TestSchemas::V033)
      run_all_migrations

      assert_can_insert_core_records
      assert_can_insert_deployment
      assert_can_insert_exception
      assert_can_insert_job_run
    end

    test "upgrade from v0.2.7 converts routes to multi-verb model" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_routes, :http_methods), "http_methods missing on routes"
    assert_not @conn.column_exists?(:rails_pulse_routes, :method), "old method column should be removed"
    assert @conn.column_exists?(:rails_pulse_requests, :method), "method column missing on requests"

    assert @conn.index_exists?(:rails_pulse_routes, [ :controller_action, :path ],
      name: "index_rails_pulse_routes_on_controller_action_and_path"),
      "new unique index missing on routes"
    assert RailsPulse::RouteIndexes.exists?(@conn),
      "null-action unique index should be added when no duplicate paths exist"
  end

  test "upgrade from v0.2.7 keeps GET and POST on the same path as separate routes" do
    load_baseline(RailsPulse::TestSchemas::V027)

    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")
    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_routes (method, path, created_at, updated_at)
      VALUES ('GET', '/users', '#{now}', '#{now}')
    SQL
    get_id = @conn.select_value("SELECT id FROM rails_pulse_routes WHERE method = 'GET' AND path = '/users'")

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_routes (method, path, created_at, updated_at)
      VALUES ('POST', '/users', '#{now}', '#{now}')
    SQL
    post_id = @conn.select_value("SELECT id FROM rails_pulse_routes WHERE method = 'POST' AND path = '/users'")

    is_error_value = @conn.adapter_name.downcase == "postgresql" ? "false" : "0"
    get_uuid = "upgrade-get-#{SecureRandom.hex(4)}"
    post_uuid = "upgrade-post-#{SecureRandom.hex(4)}"

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at)
      VALUES (#{get_id}, 10, 200, #{is_error_value}, '#{get_uuid}', '#{now}', '#{now}', '#{now}')
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at)
      VALUES (#{post_id}, 20, 201, #{is_error_value}, '#{post_uuid}', '#{now}', '#{now}', '#{now}')
    SQL

    run_all_migrations

    rows = @conn.select_all("SELECT id, http_methods, controller_action FROM rails_pulse_routes WHERE path = '/users' ORDER BY id").to_a

    assert_equal 2, rows.size, "GET /users and POST /users must remain two routes until migrate_routes backfills actions"
    assert rows.all? { |row| row["controller_action"].nil? }

    methods = rows.map { |row| JSON.parse(row["http_methods"]) }.sort

    assert_equal [ [ "GET" ], [ "POST" ] ], methods

    assert_equal "GET", @conn.select_value("SELECT method FROM rails_pulse_requests WHERE request_uuid = '#{get_uuid}'")
    assert_equal "POST", @conn.select_value("SELECT method FROM rails_pulse_requests WHERE request_uuid = '#{post_uuid}'")
    assert_equal get_id.to_i, @conn.select_value("SELECT route_id FROM rails_pulse_requests WHERE request_uuid = '#{get_uuid}'").to_i
    assert_equal post_id.to_i, @conn.select_value("SELECT route_id FROM rails_pulse_requests WHERE request_uuid = '#{post_uuid}'").to_i
    assert_not RailsPulse::RouteIndexes.exists?(@conn),
      "null-action unique index must wait until migrate_routes when REST siblings still have null controller_action"
  end

  test "migrate_routes after upgrade preserves distinct REST actions and merges same-action paths" do
    load_baseline(RailsPulse::TestSchemas::V027)
    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")

    [
      [ "GET", "/users" ],
      [ "POST", "/users" ],
      [ "GET", "/sign_in" ],
      [ "POST", "/sign_in" ],
      [ "GET", "/ghost/upgrade" ],
      [ "POST", "/ghost/upgrade" ]
    ].each do |method, path|
      @conn.execute(<<~SQL)
        INSERT INTO rails_pulse_routes (method, path, created_at, updated_at)
        VALUES ('#{method}', '#{path}', '#{now}', '#{now}')
      SQL
    end

    run_all_migrations

    RailsPulse::RouteControllerActionBackfiller.call
    RailsPulse::RouteIndexes.ensure_null_action_uniqueness!(@conn)

    users = @conn.select_all("SELECT controller_action, http_methods FROM rails_pulse_routes WHERE path = '/users' ORDER BY controller_action").to_a

    assert_equal 2, users.size
    assert_equal [ "home#create", "home#index" ], users.map { |row| row["controller_action"] }.sort

    sign_in = @conn.select_all("SELECT controller_action, http_methods FROM rails_pulse_routes WHERE path = '/sign_in'").to_a

    assert_equal 1, sign_in.size
    assert_equal "home#index", sign_in.first["controller_action"]
    assert_equal [ "GET", "POST" ], JSON.parse(sign_in.first["http_methods"]).sort

    ghost = @conn.select_all("SELECT controller_action, http_methods FROM rails_pulse_routes WHERE path = '/ghost/upgrade'").to_a

    assert_equal 1, ghost.size
    assert_nil ghost.first["controller_action"]
    assert_equal [ "GET", "POST" ], JSON.parse(ghost.first["http_methods"]).sort

    assert RailsPulse::RouteIndexes.exists?(@conn)
  end

    test "http_methods is NOT NULL after upgrading from v0.2.7" do
      load_baseline(RailsPulse::TestSchemas::V027)
      run_all_migrations

      col = @conn.columns(:rails_pulse_routes).find { |c| c.name == "http_methods" }

      assert_not col.null, "http_methods should be NOT NULL after upgrade"
    end

    test "upgrade from v0.2.7 adds diagnostic columns to operations and requests" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_operations, :row_count), "row_count missing on operations"
    assert @conn.column_exists?(:rails_pulse_operations, :cache_hit), "cache_hit missing on operations"
    assert @conn.column_exists?(:rails_pulse_operations, :repeated_query_group), "repeated_query_group missing on operations"
    assert @conn.column_exists?(:rails_pulse_operations, :repetition_count), "repetition_count missing on operations"
    assert @conn.column_exists?(:rails_pulse_requests, :response_size_bytes), "response_size_bytes missing on requests"

    cache_hit_col = @conn.columns(:rails_pulse_operations).find { |c| c.name == "cache_hit" }

    assert cache_hit_col.null, "cache_hit should be nullable after MakeCacheHitOnOperationsNullable"
  end

  test "upgrade from v0.2.7 adds p95 and p99 duration to jobs" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_jobs, :p95_duration), "p95_duration missing on jobs"
    assert @conn.column_exists?(:rails_pulse_jobs, :p99_duration), "p99_duration missing on jobs"
  end

  test "upgrade from v0.2.7 creates the events table" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_events), "events table missing"
    %w[kind subject outcome value occurred_at message metadata].each do |column|
      assert @conn.column_exists?(:rails_pulse_events, column), "#{column} missing on events"
    end
  end

  test "upgrade from v0.2.7 creates deployments table" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_deployments), "deployments table missing"
    assert @conn.column_exists?(:rails_pulse_deployments, :revision), "revision missing on deployments"
    assert @conn.column_exists?(:rails_pulse_deployments, :started_at), "started_at missing on deployments"
  end

  test "upgrade from v0.2.7 creates exception groups and occurrences tables" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_exception_groups), "exception_groups table missing"
    assert @conn.table_exists?(:rails_pulse_exception_occurrences), "exception_occurrences table missing"
    assert @conn.column_exists?(:rails_pulse_exception_groups, :fingerprint), "fingerprint missing on exception_groups"
    assert @conn.column_exists?(:rails_pulse_exception_groups, :status), "status missing on exception_groups"
    assert @conn.column_exists?(:rails_pulse_exception_groups, :location), "location missing on exception_groups"
    assert @conn.column_exists?(:rails_pulse_exception_occurrences, :exception_group_id), "exception_group_id missing on occurrences"
    assert @conn.column_exists?(:rails_pulse_exception_occurrences, :occurred_at), "occurred_at missing on occurrences"
  end

  test "upgrade from v0.2.7 adds actual_sql to operations" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_operations, :actual_sql), "actual_sql missing on operations"
  end

  test "upgrade from v0.2.7 ensures job_runs table exists" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_jobs), "jobs table missing"
    assert @conn.table_exists?(:rails_pulse_job_runs), "job_runs table missing"
  end

  test "upgrade from v0.3.1 creates deployments table" do
    load_baseline(RailsPulse::TestSchemas::V031)
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_deployments), "deployments table missing"
  end

  test "upgrade from v0.3.1 adds actual_sql to operations" do
    load_baseline(RailsPulse::TestSchemas::V031)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_operations, :actual_sql), "actual_sql missing on operations"
  end

  test "upgrade from v0.3.1 leaves existing columns intact" do
    load_baseline(RailsPulse::TestSchemas::V031)
    run_all_migrations

    assert @conn.column_exists?(:rails_pulse_jobs, :p95_duration)
    assert @conn.column_exists?(:rails_pulse_operations, :row_count)
    assert @conn.column_exists?(:rails_pulse_requests, :response_size_bytes)
  end

  # Edge Cases

  test "migrations are idempotent when run against current schema" do
    run_all_migrations

    assert @conn.table_exists?(:rails_pulse_deployments)
    assert @conn.table_exists?(:rails_pulse_exception_groups)
    assert @conn.table_exists?(:rails_pulse_exception_occurrences)
    assert @conn.table_exists?(:rails_pulse_job_runs)
    assert @conn.column_exists?(:rails_pulse_operations, :actual_sql)
    assert @conn.column_exists?(:rails_pulse_jobs, :p95_duration)
  end

  # Record Insertion Tests

  test "can insert records after upgrading from v0.2.7" do
    load_baseline(RailsPulse::TestSchemas::V027)
    run_all_migrations

    assert_can_insert_core_records
    assert_can_insert_deployment
    assert_can_insert_exception
    assert_can_insert_job_run
  end

  test "can insert records after upgrading from v0.3.1" do
    load_baseline(RailsPulse::TestSchemas::V031)
    run_all_migrations

    assert_can_insert_core_records
    assert_can_insert_deployment
    assert_can_insert_exception
    assert_can_insert_job_run
  end

  private

  def load_baseline(schema_lambda)
    drop_all_rails_pulse_tables
    silence_schema_output { schema_lambda.call(@conn) }
    @conn.schema_cache.clear!
  end

  def run_all_migrations
    load_migration_files
    MIGRATION_CLASSES.each do |class_name|
      migration = class_name.constantize.new
      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    end
    @conn.schema_cache.clear!
  end

  def load_migration_files
    Dir.glob("#{MIGRATE_DIR}/*.rb").sort.each { |f| load f }
  end

  def drop_all_rails_pulse_tables
    tables = @conn.tables.select { |t| t.start_with?("rails_pulse_") }
    @conn.disable_referential_integrity do
      tables.each { |t| @conn.drop_table(t, force: :cascade) }
    end
  end

  CURRENT_SCHEMA_FILE = File.expand_path("../../db/rails_pulse_schema.rb", __dir__)

  def restore_current_schema
    drop_all_rails_pulse_tables
    silence_schema_output { load CURRENT_SCHEMA_FILE }
    @conn.schema_cache.clear!
  end

  def silence_schema_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end

  def assert_can_insert_core_records
    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")
    uuid = SecureRandom.uuid
    path = "/migration-test-#{SecureRandom.hex(4)}"

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_routes (http_methods, path, controller_action, created_at, updated_at)
      VALUES ('["GET"]', '#{path}', 'home#index', '#{now}', '#{now}')
    SQL

    route_id = @conn.select_value("SELECT id FROM rails_pulse_routes WHERE path = '#{path}'")

    assert route_id, "route insert failed"

    is_error_value = @conn.adapter_name.downcase == "postgresql" ? "false" : "0"

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at)
      VALUES (#{route_id}, 42.5, 200, #{is_error_value}, '#{uuid}', '#{now}', '#{now}', '#{now}')
    SQL

    request_count = @conn.select_value("SELECT COUNT(*) FROM rails_pulse_requests WHERE request_uuid = '#{uuid}'").to_i

    assert_equal 1, request_count, "request insert failed"
  end

  def assert_can_insert_job_run
    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")
    job_name = "MigrationTestJob-#{SecureRandom.hex(4)}"
    run_id = SecureRandom.uuid

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_jobs (name, runs_count, failures_count, retries_count, created_at, updated_at)
      VALUES ('#{job_name}', 0, 0, 0, '#{now}', '#{now}')
    SQL

    job_id = @conn.select_value("SELECT id FROM rails_pulse_jobs WHERE name = '#{job_name}'")

    assert job_id, "job insert failed"

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_job_runs (job_id, run_id, status, attempts, occurred_at, created_at, updated_at)
      VALUES (#{job_id}, '#{run_id}', 'completed', 0, '#{now}', '#{now}', '#{now}')
    SQL

    count = @conn.select_value("SELECT COUNT(*) FROM rails_pulse_job_runs WHERE run_id = '#{run_id}'").to_i

    assert_equal 1, count, "job_run insert failed"
  end

  def assert_can_insert_deployment
    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_deployments (revision, started_at, created_at, updated_at)
      VALUES ('abc123', '#{now}', '#{now}', '#{now}')
    SQL

    count = @conn.select_value("SELECT COUNT(*) FROM rails_pulse_deployments WHERE revision = 'abc123'").to_i

    assert_equal 1, count, "deployment insert failed"
  end

  def assert_can_insert_exception
    now = Time.current.strftime("%Y-%m-%d %H:%M:%S")
    fingerprint = SecureRandom.hex(16)

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_exception_groups
        (fingerprint, exception_class, message, first_seen_at, last_seen_at, occurrence_count, status, preserve, created_at, updated_at)
      VALUES
        ('#{fingerprint}', 'RuntimeError', 'boom', '#{now}', '#{now}', 1, 'open', #{@conn.quote(false)}, '#{now}', '#{now}')
    SQL

    group_id = @conn.select_value("SELECT id FROM rails_pulse_exception_groups WHERE fingerprint = '#{fingerprint}'")

    assert group_id, "exception_group insert failed"

    @conn.execute(<<~SQL)
      INSERT INTO rails_pulse_exception_occurrences
        (exception_group_id, exception_class, message, occurred_at, created_at, updated_at)
      VALUES
        (#{group_id}, 'RuntimeError', 'boom', '#{now}', '#{now}', '#{now}')
    SQL

    count = @conn.select_value("SELECT COUNT(*) FROM rails_pulse_exception_occurrences WHERE exception_group_id = #{group_id}").to_i

    assert_equal 1, count, "exception_occurrence insert failed"
  end
end
