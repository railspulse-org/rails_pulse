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
      %w[db:prepare db:migrate].each do |name|
        next unless Rake::Task.task_defined?(name)

        assert_includes Rake::Task[name].prerequisites, "db:rails_pulse:load_central_schema"
      end
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
