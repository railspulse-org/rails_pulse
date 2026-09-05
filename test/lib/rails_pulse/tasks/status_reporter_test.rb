require "test_helper"

class RailsPulse::Tasks::StatusReporterTest < ActiveSupport::TestCase
  fixtures :rails_pulse_summaries

  def setup
    super
    @output = StringIO.new
    RailsPulse::SchemaCheck.reset!
  end

  def teardown
    RailsPulse::SchemaCheck.reset!
    super
  end

  # Structure Tests

  test "reports every section against the dummy app" do
    report

    assert_match(/\ARails Pulse #{Regexp.escape(RailsPulse::VERSION)}/, @output.string)
    %w[Database: Schema: Migrations: Routes: Initializer: Tracking: Dashboard: Summaries:].each do |label|
      assert_includes @output.string, label
    end
  end

  test "returns true and says OK when nothing needs action" do
    assume_clean_install

    assert report
    assert_includes @output.string, "Schema:     up to date"
    assert_includes @output.string, "Migrations: none pending"
    assert_includes @output.string, "OK — nothing to do."
    assert_not_includes @output.string, "Action needed"
  end

  # Action Tests

  test "schema drift is reported with the upgrade commands and fails the report" do
    assume_clean_install
    RailsPulse::SchemaCheck.stubs(:expected_schema).returns("rails_pulse_routes" => %w[http_methods ghost])

    assert_not report
    assert_includes @output.string, "Schema:     BEHIND this gem version"
    assert_includes @output.string, "rails_pulse_routes: missing ghost"
    assert_includes @output.string, "Routes:     (skipped — schema is behind)"
    assert_match(/Action needed:.*rails generate rails_pulse:upgrade/m, @output.string)
  end

  test "migration files present but not run are listed" do
    assume_clean_install
    RailsPulse::Tasks::StatusReporter.any_instance.stubs(:pending_migrations).returns([ "20990101000000_future_change.rb" ])

    assert_not report
    assert_includes @output.string, "1 migration file(s) present but not run"
    assert_includes @output.string, "20990101000000_future_change.rb"
    assert_match(/Run pending migrations: rails db:migrate/, @output.string)
  end

  test "gem migrations not yet copied into the app point at the upgrade generator" do
    assume_clean_install
    RailsPulse::Tasks::StatusReporter.any_instance.stubs(:gem_migrations_not_in_host).returns([ "20990101000000_new_feature.rb" ])

    assert_not report
    assert_includes @output.string, "not yet copied into this app"
    assert_match(/Copy this version's migrations: rails generate rails_pulse:upgrade/, @output.string)
  end

  test "an outstanding route backfill is reported" do
    assume_clean_install
    RailsPulse::Route.stubs(:needs_action_backfill?).returns(true)

    assert_not report
    assert_includes @output.string, "actions NOT backfilled"
    assert_match(/rails rails_pulse:migrate_routes/, @output.string)
  end

  test "initializer settings this version added but the host does not mention are listed" do
    assume_clean_install
    RailsPulse::Installers::ConfigUpdater.stubs(:missing).returns(keys: %w[authorize], hash_keys: %w[rails_pulse_deployments])

    assert_not report
    assert_includes @output.string, "2 setting(s) from this version not mentioned: authorize, rails_pulse_deployments"
    assert_match(/Append the new settings to the initializer/, @output.string)
  end

  test "a missing initializer points at the install generator" do
    assume_clean_install
    Rails.stubs(:root).returns(Pathname.new(Dir.mktmpdir))

    assert_not report
    assert_includes @output.string, "config/initializers/rails_pulse.rb not found"
    assert_match(/rails generate rails_pulse:install/, @output.string)
  end

  # Edge Cases

  test "stale summaries are called out but are not an action" do
    assume_clean_install
    RailsPulse::Summary.stubs(:maximum).returns(3.hours.ago)

    assert report
    assert_match(/Summaries:  last generated 3h ago — stale/, @output.string)
  end

  test "no summaries at all is called out but is not an action" do
    assume_clean_install
    RailsPulse::Summary.stubs(:maximum).returns(nil)

    assert report
    assert_includes @output.string, "Summaries:  none generated yet"
  end

  private

  def report
    RailsPulse::Tasks::StatusReporter.report(output: @output)
  end

  # The dummy app is not a host app: it has no config/initializers/rails_pulse.rb
  # at Rails.root's expected place in every worker, its migrations live in
  # test/dummy/db/migrate, and fixtures may leave routes without actions.
  # Pin those so each test controls exactly one variable.
  def assume_clean_install
    RailsPulse::Tasks::StatusReporter.any_instance.stubs(:gem_migrations_not_in_host).returns([])
    RailsPulse::Tasks::StatusReporter.any_instance.stubs(:pending_migrations).returns([])
    RailsPulse::Route.stubs(:needs_action_backfill?).returns(false)
    RailsPulse::RouteIndexes.stubs(:exists?).returns(true)
    RailsPulse::Installers::ConfigUpdater.stubs(:missing).returns(keys: [], hash_keys: [])
    RailsPulse::Summary.stubs(:maximum).returns(5.minutes.ago)
  end
end
