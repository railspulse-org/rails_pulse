require "test_helper"
require "open3"

module RailsPulse
  # Everything under app/ is loaded by the host's Zeitwerk autoloader, which
  # derives constant names from file names through the host's inflections. A
  # host that declares `inflect.acronym "SQL"` must still get
  # RailsPulse::SqlQueryNormalizer from sql_query_normalizer.rb, or production
  # (eager_load = true) fails to boot.
  class ZeitwerkTest < ActiveSupport::TestCase
    DUMMY_ROOT = File.expand_path("../../dummy", __dir__)

    test "eager loading succeeds when the host declares acronym inflections" do
      # COVERAGE => nil: the child must not inherit the coverage cell's
      # SimpleCov, whose minimum-coverage at_exit gate exits 2 on a process
      # that only boots the app.
      env = {
        "RAILS_ENV" => "test",
        "RAILS_PULSE_TEST_ACRONYMS" => "SQL,CSP,API",
        "DB" => ENV.fetch("DB", "sqlite3"),
        "COVERAGE" => nil
      }
      output, status = Open3.capture2e(env, "bundle", "exec", "rails", "zeitwerk:check", chdir: DUMMY_ROOT)

      assert_predicate status, :success?, output
      assert_includes output, "All is good!"
    end

    test "acronym-safe inflections resolve to the constants the files define" do
      inflector = Rails.autoloaders.main.inflector

      RailsPulse::Engine::ACRONYM_SAFE_INFLECTIONS.each do |basename, constant|
        assert_equal constant, inflector.camelize(basename, nil)
      end
    end
  end
end
