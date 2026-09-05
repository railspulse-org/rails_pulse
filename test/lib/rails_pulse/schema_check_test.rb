require "test_helper"
require "generators/rails_pulse/schema_parser"

class RailsPulse::SchemaCheckTest < ActiveSupport::TestCase
  def setup
    super
    RailsPulse::SchemaCheck.reset!
  end

  def teardown
    RailsPulse::SchemaCheck.reset!
    super
  end

  # Structure Tests

  test "expected_schema covers every Rails Pulse table" do
    expected = RailsPulse::SchemaCheck.expected_schema

    assert_equal RailsPulse::Generators::BaseMethods::RAILS_PULSE_TABLES.sort, expected.keys.sort
    assert_equal %w[controller_action http_methods], expected["rails_pulse_routes"]
    assert_equal %w[method response_size_bytes], expected["rails_pulse_requests"]
    assert_empty expected["rails_pulse_summaries"]
  end

  test "every sentinel column exists in the gem's schema file" do
    schema_path = RailsPulse::Engine.root.join("db", "rails_pulse_schema.rb").to_s
    parsed = RailsPulse::Generators::SchemaParser.new(schema_path).extract_expected_schema

    RailsPulse::SchemaCheck::SENTINEL_COLUMNS.each do |table, columns|
      assert_includes parsed.keys, table, "#{table} is not defined in db/rails_pulse_schema.rb"
      columns.each do |column|
        assert_includes parsed[table].keys, column, "#{table}.#{column} is a sentinel but not in db/rails_pulse_schema.rb"
      end
    end
  end

  test "every sentinel column is added by an incremental migration" do
    migrations = Dir.glob(RailsPulse::Engine.root.join("db", "rails_pulse_migrate", "*.rb").to_s).map { |f| File.read(f) }.join

    RailsPulse::SchemaCheck::SENTINEL_COLUMNS.each do |table, columns|
      columns.each do |column|
        assert_match(/add_column :#{table}, :#{column}\b/, migrations, "#{table}.#{column} has no add_column migration")
      end
    end
  end

  test "current schema has nothing missing" do
    assert_predicate RailsPulse::SchemaCheck, :current?
    assert_empty RailsPulse::SchemaCheck.missing
  end

  # Drift Detection Tests

  test "missing lists columns the live table lacks" do
    stub_expected_schema("rails_pulse_routes" => %w[http_methods not_a_real_column])

    assert_not_predicate RailsPulse::SchemaCheck, :current?
    assert_equal({ "rails_pulse_routes" => [ "not_a_real_column" ] }, RailsPulse::SchemaCheck.missing)
  end

  test "missing marks a table that does not exist" do
    stub_expected_schema("rails_pulse_not_a_table" => %w[id])

    assert_equal({ "rails_pulse_not_a_table" => [ :table ] }, RailsPulse::SchemaCheck.missing)
  end

  test "the comparison is memoized after it completes" do
    RailsPulse::SchemaCheck.missing
    RailsPulse::SchemaCheck.stubs(:expected_schema).returns("rails_pulse_routes" => [ "ghost" ])

    assert_predicate RailsPulse::SchemaCheck, :current?
  end

  test "reset! discards the memoized comparison" do
    RailsPulse::SchemaCheck.missing
    RailsPulse::SchemaCheck.reset!
    stub_expected_schema("rails_pulse_routes" => [ "ghost" ])

    assert_not_predicate RailsPulse::SchemaCheck, :current?
  end

  # Tracking Gate Tests

  test "tracking_allowed? is true when the schema is current" do
    assert_predicate RailsPulse::SchemaCheck, :tracking_allowed?
  end

  test "tracking_allowed? refuses and logs the upgrade instructions exactly once when outdated" do
    stub_expected_schema("rails_pulse_routes" => [ "ghost" ])
    output = StringIO.new
    RailsPulse.stubs(:logger).returns(Logger.new(output))

    assert_not RailsPulse::SchemaCheck.tracking_allowed?
    assert_not RailsPulse::SchemaCheck.tracking_allowed?

    assert_equal 1, output.string.scan("rails generate rails_pulse:upgrade").size
    assert_match(/rails_pulse_routes: ghost/, output.string)
  end

  # Configuration Tests

  test "schema_check_enabled = false reports nothing missing and allows tracking" do
    stub_expected_schema("rails_pulse_routes" => [ "ghost" ])
    RailsPulse.configuration.stubs(:schema_check_enabled).returns(false)

    assert_predicate RailsPulse::SchemaCheck, :current?
    assert_empty RailsPulse::SchemaCheck.missing
    assert_predicate RailsPulse::SchemaCheck, :tracking_allowed?
  end

  # Edge Cases

  test "a database error is not treated as an outdated schema and is not memoized" do
    RailsPulse::ApplicationRecord.stubs(:connection).raises(ActiveRecord::ConnectionNotEstablished)

    assert_predicate RailsPulse::SchemaCheck, :current?

    RailsPulse::ApplicationRecord.unstub(:connection)
    stub_expected_schema("rails_pulse_routes" => [ "ghost" ])

    assert_not_predicate RailsPulse::SchemaCheck, :current?
  end

  private

  def stub_expected_schema(schema)
    RailsPulse::SchemaCheck.reset!
    RailsPulse::SchemaCheck.stubs(:expected_schema).returns(schema)
  end
end
