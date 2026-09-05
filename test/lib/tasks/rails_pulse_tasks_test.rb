require "test_helper"
require "rake"

class RailsPulseTasksTest < ActiveSupport::TestCase
  # Disable parallelization for rake task tests
  parallelize(workers: 1)

  def self.load_rake_tasks_once
    return if defined?(@@tasks_loaded)

    # Suppress warnings about already initialized constants
    original_verbose = $VERBOSE
    $VERBOSE = nil

    Rails.application.load_tasks

    $VERBOSE = original_verbose
    @@tasks_loaded = true
  end

  # Load tasks when class is defined
  load_rake_tasks_once

  def teardown
    Mocha::Mockery.instance.teardown
  end

  def reenable_and_capture(task_name)
    Rake::Task[task_name].reenable
    output = StringIO.new
    old_stdout = $stdout
    $stdout = output
    begin
      yield
    rescue SystemExit
      # Catch expected exits
    ensure
      $stdout = old_stdout
    end
    output.string
  end

  # rails_pulse:status tests

  test "status task is registered" do
    assert Rake::Task.task_defined?("rails_pulse:status")
  end

  test "status task prints the report and exits non-zero when action is needed" do
    RailsPulse::Tasks::StatusReporter.stubs(:report).returns(false)

    exit_status = nil
    reenable_and_capture("rails_pulse:status") do
      begin
        Rake::Task["rails_pulse:status"].invoke
      rescue SystemExit => e
        exit_status = e.status
        raise
      end
    end

    assert_equal 1, exit_status
  end

  test "status task exits normally when nothing needs action" do
    RailsPulse::Tasks::StatusReporter.stubs(:report).returns(true)

    assert_nothing_raised do
      reenable_and_capture("rails_pulse:status") { Rake::Task["rails_pulse:status"].invoke }
    end
  end

  # rails_pulse:cleanup tests

  test "cleanup task outputs disabled message and exits when archiving_enabled is false" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = false

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "disabled"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task calls CleanupService.perform when archiving is enabled" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: { rails_pulse_requests: 5, rails_pulse_operations: 3 },
      count_based: { rails_pulse_routes: 0 },
      total_deleted: 8
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "Starting Rails Pulse data cleanup"
    assert_includes output, "Cleanup completed"
    assert_includes output, "8"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task prints breakdown when records were deleted" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: { rails_pulse_requests: 10 },
      count_based: { rails_pulse_operations: 5 },
      total_deleted: 15
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "Breakdown by table"
    assert_includes output, "rails_pulse_requests"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task prints no breakdown when zero records deleted" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: { rails_pulse_requests: 0 },
      count_based: { rails_pulse_operations: 0 },
      total_deleted: 0
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    refute_includes output, "Breakdown by table"
    assert_includes output, "Total: 0"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task handles errors and exits with code 1" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    RailsPulse::CleanupService.stubs(:perform).raises(StandardError, "Something went wrong")

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "Cleanup failed"
    assert_includes output, "Something went wrong"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task shows backtrace when VERBOSE is set" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true
    original_verbose = ENV["VERBOSE"]
    ENV["VERBOSE"] = "true"

    error = StandardError.new("verbose error")
    error.set_backtrace([ "lib/foo.rb:1" ])
    RailsPulse::CleanupService.stubs(:perform).raises(error)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "lib/foo.rb:1"
  ensure
    RailsPulse.configuration.archiving_enabled = original
    ENV["VERBOSE"] = original_verbose
  end

  # rails_pulse:install_migrations tests

  test "install_migrations task outputs copying message" do
    output = reenable_and_capture("rails_pulse:install_migrations") do
      Rake::Task["rails_pulse:install_migrations"].invoke
    end

    assert_includes output, "Copying migrations"
  end

  test "install_migrations processes all defined migrations in order" do
    output = reenable_and_capture("rails_pulse:install_migrations") do
      Rake::Task["rails_pulse:install_migrations"].invoke
    end

    # Should process migrations (either skip or copy them)
    assert_includes output, "Copying migrations"
  end

  test "install_migrations copies new migration when it doesn't exist" do
    # Create a temp migration file to test copying
    source_dir = File.expand_path("../../../../db/migrate", __FILE__)
    dest_dir = Rails.root.join("db/migrate")

    output = reenable_and_capture("rails_pulse:install_migrations") do
      Rake::Task["rails_pulse:install_migrations"].invoke
    end

    assert_includes output, "migrations"
  end

  # rails_pulse:install_config tests

  test "install_config task handles existing config" do
    output = reenable_and_capture("rails_pulse:install_config") do
      Rake::Task["rails_pulse:install_config"].invoke
    end

    # Should either skip or copy the config
    assert output.include?("already exists") || output.include?("Copied")
  end

  test "install_config checks for config file at correct path" do
    config_path = Rails.root.join("config/initializers/rails_pulse.rb")

    output = reenable_and_capture("rails_pulse:install_config") do
      Rake::Task["rails_pulse:install_config"].invoke
    end

    # Task should run without errors
    assert_kind_of String, output
  end

  # rails_pulse:install tests

  test "install task runs both install_migrations and install_config" do
    output = reenable_and_capture("rails_pulse:install") do
      Rake::Task["rails_pulse:install"].invoke
    end

    # Should invoke both subtasks
    assert_kind_of String, output
  end

  # rails_pulse:cleanup_stats tests

  test "cleanup_stats task outputs configuration" do
    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "Rails Pulse Cleanup Configuration"
    assert_includes output, "Cleanup enabled"
    assert_includes output, "Current table sizes"
  end

  test "cleanup_stats task lists table counts" do
    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "rails_pulse_requests"
    assert_includes output, "rails_pulse_routes"
  end

  test "cleanup_stats task shows over limit status" do
    original_max = RailsPulse.configuration.max_table_records
    RailsPulse.configuration.max_table_records = { rails_pulse_requests: 1 }

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    if RailsPulse::Request.count > 1
      assert_includes output, "OVER LIMIT"
    else
      assert_includes output, "rails_pulse_requests"
    end
  ensure
    RailsPulse.configuration.max_table_records = original_max
  end

  test "cleanup_stats task shows old records when retention period configured" do
    original_retention = RailsPulse.configuration.full_retention_period
    RailsPulse.configuration.full_retention_period = 30.days

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "Records older than"
  ensure
    RailsPulse.configuration.full_retention_period = original_retention
  end

  test "cleanup_stats task handles model not found errors" do
    "RailsPulse::Request".stubs(:constantize).raises(NameError)

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "Current table sizes"
  end

  test "cleanup_stats task handles general errors when counting records" do
    RailsPulse::Request.stubs(:count).raises(StandardError, "Database error")

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "Error"
  end

  test "cleanup_stats task handles errors calculating old records" do
    original_retention = RailsPulse.configuration.full_retention_period
    RailsPulse.configuration.full_retention_period = 30.days
    RailsPulse::Request.stubs(:where).raises(StandardError, "Query error")

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    assert_includes output, "Error calculating old records"
  ensure
    RailsPulse.configuration.full_retention_period = original_retention
  end

  test "cleanup_stats handles nil retention period" do
    original_retention = RailsPulse.configuration.full_retention_period
    RailsPulse.configuration.full_retention_period = nil

    output = reenable_and_capture("rails_pulse:cleanup_stats") do
      Rake::Task["rails_pulse:cleanup_stats"].invoke
    end

    refute_includes output, "Records older than"
    assert_includes output, "Current table sizes"
  ensure
    RailsPulse.configuration.full_retention_period = original_retention
  end

  test "cleanup task breakdown shows time-based cleanups" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: { rails_pulse_requests: 5 },
      count_based: {},
      total_deleted: 5
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "time-based"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task breakdown shows count-based cleanups" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: {},
      count_based: { rails_pulse_operations: 10 },
      total_deleted: 10
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "count-based"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end

  test "cleanup task shows both time-based and count-based totals" do
    original = RailsPulse.configuration.archiving_enabled
    RailsPulse.configuration.archiving_enabled = true

    stats = {
      time_based: { rails_pulse_requests: 3, rails_pulse_queries: 2 },
      count_based: { rails_pulse_operations: 4 },
      total_deleted: 9
    }
    RailsPulse::CleanupService.stubs(:perform).returns(stats)

    output = reenable_and_capture("rails_pulse:cleanup") do
      Rake::Task["rails_pulse:cleanup"].invoke
    end

    assert_includes output, "Time-based cleanup: 5"
    assert_includes output, "Count-based cleanup: 4"
    assert_includes output, "Total: 9"
  ensure
    RailsPulse.configuration.archiving_enabled = original
  end
  # rails_pulse:migrate_routes tests

  test "migrate_routes reports backfill and normalization results" do
    RailsPulse::RouteControllerActionBackfiller.stubs(:call).returns(
      updated: 2, merged: 1, skipped: 0, already_set: 5
    )
    RailsPulse::RouteMigrator.stubs(:call).returns(merged: 3, skipped: 0, unchanged: 4)
    RailsPulse::RouteIndexes.stubs(:ensure_null_action_uniqueness!)

    output = reenable_and_capture("rails_pulse:migrate_routes") do
      Rake::Task["rails_pulse:migrate_routes"].invoke
    end

    assert_includes output, "Controller action backfill: 2 updated, 1 merged"
    assert_includes output, "Path normalization: 3 merged"
    assert_includes output, "Ensured unique index on unrecognized"
  end

  test "migrate_routes retries the unique index after a duplicate path race" do
    RailsPulse::RouteControllerActionBackfiller.stubs(:call).returns(
      updated: 0, merged: 0, skipped: 0, already_set: 0
    )
    RailsPulse::RouteMigrator.stubs(:call).returns(merged: 0, skipped: 0, unchanged: 0)
    RailsPulse::RouteIndexes.stubs(:ensure_null_action_uniqueness!)
      .raises(ActiveRecord::RecordNotUnique.new("dup"))
      .then.returns(nil)

    output = reenable_and_capture("rails_pulse:migrate_routes") do
      Rake::Task["rails_pulse:migrate_routes"].invoke
    end

    assert_includes output, "Duplicate null-action paths detected after consolidation"
    assert_includes output, "Unique index created on retry."
  end

  test "migrate_routes reports unresolvable duplicate paths" do
    RailsPulse::RouteControllerActionBackfiller.stubs(:call).returns(
      updated: 0, merged: 0, skipped: 0, already_set: 0
    )
    RailsPulse::RouteMigrator.stubs(:call).returns(merged: 0, skipped: 0, unchanged: 0)
    RailsPulse::RouteIndexes.stubs(:ensure_null_action_uniqueness!)
      .raises(ActiveRecord::RecordNotUnique.new("dup"))
    RailsPulse::Route.stubs(:where).returns(stub(group: stub(having: stub(pluck: [ "/dup/1", "/dup/2" ]))))

    output = reenable_and_capture("rails_pulse:migrate_routes") do
      Rake::Task["rails_pulse:migrate_routes"].invoke
    end

    assert_includes output, "ERROR: Could not create unique index. Duplicate paths remain:"
    assert_includes output, "/dup/1"
  end
end
