require "test_helper"
require "generators/rails_pulse/install_cloud_generator"
require_relative "../support/generator_test_helpers"

class InstallCloudGeneratorTest < Rails::Generators::TestCase
  include GeneratorTestHelpers

  tests RailsPulse::Generators::InstallCloudGenerator

  def destination_root
    # Use test-specific directory to avoid parallel test interference
    @destination_root ||= File.expand_path("../tmp/install_cloud_generator_test/#{name}", __dir__)
  end

  setup do
    prepare_destination
    setup_test_app_with_schema
  end

  # Single Database Tests

  test "copies the Cloud schema file" do
    run_generator

    assert_file "db/rails_pulse_cloud_schema.rb" do |content|
      assert_match(/RailsPulse::CloudSchema = lambda/, content)
      assert_match(/create_table :rails_pulse_cloud_installations/, content)
      assert_match(/create_table :rails_pulse_cloud_batches/, content)
    end
  end

  test "the generator template is a byte-identical copy of db/rails_pulse_cloud_schema.rb" do
    gem_root = File.expand_path("../..", __dir__)

    assert_equal File.read(File.join(gem_root, "db/rails_pulse_cloud_schema.rb")),
                 File.read(File.join(gem_root, "lib/generators/rails_pulse/templates/db/rails_pulse_cloud_schema.rb"))
  end

  test "the copied schema file is the gem's own" do
    run_generator

    assert_equal File.read(File.expand_path("../../db/rails_pulse_cloud_schema.rb", __dir__)),
                 File.read(File.join(destination_root, "db/rails_pulse_cloud_schema.rb"))
  end

  test "single database setup gets a migration in db/migrate that loads the Cloud schema" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    output = run_generator

    assert_migration "db/migrate/install_rails_pulse_cloud_tables.rb" do |content|
      assert_match(/class InstallRailsPulseCloudTables/, content)
      assert_match(/RailsPulse::CloudSchema.call/, content)
    end
    assert_match(/Run: rails db:migrate\n/, output)
  end

  test "the next steps name the settings, both scheduled jobs and the preview" do
    output = run_generator

    assert_match(/config\.cloud\.api_key/, output)
    assert_match(/config\.cloud\.application/, output)
    assert_match(/class: RailsPulse::SummaryJob/, output)
    assert_match(/class: RailsPulse::CloudHealthJob/, output)
    assert_no_match(/needs no schedule/, output)
    assert_match(/rails rails_pulse:cloud:preview/, output)
  end

  test "the next steps send people to Profile → API keys for the key" do
    output = run_generator

    assert_match(/Profile → API keys/, output)
    assert_no_match(/Application's settings/, output)
  end

  test "the initializer template sends people to Profile → API keys for the key" do
    template = File.read(File.expand_path("../../lib/generators/rails_pulse/templates/rails_pulse.rb", __dir__))

    assert_match(/Profile → API keys/, template)
    assert_no_match(/Application's settings/, template)
  end

  # Separate Database Tests

  test "a separate database detected from database.yml gets the migration in db/rails_pulse_migrate" do
    File.write(File.join(destination_root, "config/database.yml"), separate_database_yml)
    output = run_generator

    assert_migration "db/rails_pulse_migrate/install_rails_pulse_cloud_tables.rb"
    assert_no_migration "db/migrate/install_rails_pulse_cloud_tables.rb"
    assert_match(/Run: rails db:migrate:rails_pulse/, output)
  end

  test "--database overrides detection" do
    File.write(File.join(destination_root, "config/database.yml"), single_database_yml)
    run_generator [ "--database=separate" ]

    assert_migration "db/rails_pulse_migrate/install_rails_pulse_cloud_tables.rb"
  end

  # Edge Cases

  test "refuses without a Rails Pulse install" do
    FileUtils.rm_f(File.join(destination_root, "db/rails_pulse_schema.rb"))

    assert_raises(SystemExit) { capture(:stdout) { run_generator } }
    assert_no_file "db/rails_pulse_cloud_schema.rb"
  end
end
