# Enable code coverage tracking when COVERAGE env var is set
# Configuration loaded from .simplecov file
# NOTE: compare against "true" — CI exports COVERAGE="" for non-coverage
# cells, and "" is truthy in Ruby (see test/dummy/config/boot.rb).
if ENV["COVERAGE"] == "true"
  require "simplecov"

  # Support parallel test execution with unique command names
  SimpleCov.command_name "test:#{Process.pid}"
end

ENV["RAILS_ENV"] = "test"

# Load environment variables from .env file for database configuration
require "dotenv/load" if File.exist?(".env")

require_relative "../test/dummy/config/environment"
require "rails/test_help"
require "shoulda-matchers"
require "mocha/minitest"

# Load rails-controller-testing for controller tests
begin
  require "rails-controller-testing"
rescue LoadError
  puts "Warning: rails-controller-testing not available for testing"
end

# Load support files needed for controller tests
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

# Single-row live progress output (see test/support/rails_pulse_test_reporter.rb)
Minitest::Reporters.use!(RailsPulseTestReporter.new)

class ActiveSupport::TestCase
  # Enable parallel testing for local performance
  # Disable when BROWSER is set to avoid multiple browser windows
  # Disable when COVERAGE is set for accurate coverage tracking
  parallelize(workers: (ENV["BROWSER"] == "true" || ENV["COVERAGE"] == "true") ? 0 : :number_of_processors)

  parallelize_setup do |worker|
    require "mocha/minitest"
  end

  # Use Rails' built-in transactional cleanup
  self.use_transactional_tests = true

  # Configure fixture paths for Rails engine
  self.fixture_paths = [ File.join(File.dirname(__FILE__), "fixtures") ]

  # Load all fixtures for faster test execution
  fixtures :all

  # Dynamically configure fixture class names for all Rails engine models
  Dir[File.join(File.dirname(__FILE__), "fixtures", "rails_pulse_*.yml")].each do |fixture_file|
    table_name = File.basename(fixture_file, ".yml")

    # Convert rails_pulse_routes -> RailsPulse::Route
    # Handle both single words and compound words correctly
    class_name = table_name.sub(/^rails_pulse_/, "").classify
    namespaced_class = "RailsPulse::#{class_name}"

    begin
      model_class = namespaced_class.constantize
      set_fixture_class table_name.to_sym => model_class
    rescue NameError => e
      # Skip if model class doesn't exist yet (useful during development)
      Rails.logger&.warn "Could not find model class #{namespaced_class} for fixture #{table_name}"
    end
  end

  # Configure Shoulda Matchers
  Shoulda::Matchers.configure do |config|
    config.integrate do |with|
      with.test_framework :minitest
      with.library :rails
    end
  end

  include Shoulda::Matchers::ActiveModel
  include Shoulda::Matchers::ActiveRecord
  include ConfigurationTestHelpers
end
