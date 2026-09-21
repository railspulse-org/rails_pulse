require "test_helper"
require "generators/rails_pulse/base_methods"
require "generators/rails_pulse/upgrade_generator"

class BaseMethodsTest < ActiveSupport::TestCase
  # Use UpgradeGenerator as a concrete class that includes both
  # BaseMethods and Rails::Generators::Migration (needed for next_migration_number)
  class TestGenerator < Rails::Generators::Base
    include Rails::Generators::Migration
    include RailsPulse::Generators::BaseMethods

    source_root File.expand_path("../dummy", __dir__)

    # Expose private methods for testing
    public :rails_pulse_tables_exist?, :root_path, :gem_migrations_path
  end

  def setup
    @generator = TestGenerator.new
  end

  # RAILS_PULSE_TABLES Tests

  test "RAILS_PULSE_TABLES contains all expected table names" do
    expected = %w[
      rails_pulse_routes
      rails_pulse_queries
      rails_pulse_requests
      rails_pulse_operations
      rails_pulse_jobs
      rails_pulse_job_runs
      rails_pulse_summaries
      rails_pulse_deployments
    ]

    expected.each do |table|
      assert_includes RailsPulse::Generators::BaseMethods::RAILS_PULSE_TABLES, table
    end
  end

  test "RAILS_PULSE_TABLES is frozen" do
    assert_predicate RailsPulse::Generators::BaseMethods::RAILS_PULSE_TABLES, :frozen?
  end

  test "RAILS_PULSE_TABLES has 11 entries" do
    assert_equal 11, RailsPulse::Generators::BaseMethods::RAILS_PULSE_TABLES.size
  end

  # next_migration_number Tests

  test "next_migration_number returns a timestamp-format string" do
    Dir.mktmpdir do |path|
      result = TestGenerator.next_migration_number(path)

      assert_kind_of String, result
      # Migration numbers are timestamp strings like "20240101120000"
      assert_match(/\A\d{14}\z/, result)
    end
  end

  # rails_pulse_tables_exist? Tests

  test "rails_pulse_tables_exist? returns true when all tables exist" do
    # The test environment has Rails Pulse tables
    assert_predicate @generator, :rails_pulse_tables_exist?
  end

  test "rails_pulse_tables_exist? returns false when connection raises" do
    connection = mock("connection")
    connection.stubs(:table_exists?).raises(ActiveRecord::ConnectionNotEstablished)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    refute_predicate @generator, :rails_pulse_tables_exist?
  ensure
    ActiveRecord::Base.unstub(:connection)
  end

  test "rails_pulse_tables_exist? returns false when a table is missing" do
    connection = mock("connection")
    connection.stubs(:table_exists?).returns(false)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    refute_predicate @generator, :rails_pulse_tables_exist?
  ensure
    ActiveRecord::Base.unstub(:connection)
  end

  # gem_migrations_path Tests

  test "gem_migrations_path returns a string path" do
    path = @generator.gem_migrations_path

    assert_kind_of String, path
  end

  test "gem_migrations_path points to db/rails_pulse_migrate directory" do
    path = @generator.gem_migrations_path

    assert_match %r{db/rails_pulse_migrate}, path
  end

  test "gem_migrations_path directory exists" do
    path = @generator.gem_migrations_path

    assert File.directory?(path), "Expected #{path} to be a directory"
  end

  # root_path Tests

  test "root_path returns destination_root when generator responds to it" do
    path = @generator.root_path

    assert_predicate path, :present?
  end
end
