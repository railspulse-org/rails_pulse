require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # CI runs one cell with a non-UTC zone so time bucketing bugs that only
    # show east of UTC (or in half-hour zones) fail the suite.
    config.time_zone = ENV["RAILS_PULSE_TEST_TIME_ZONE"] if ENV["RAILS_PULSE_TEST_TIME_ZONE"].present?

    # Simulates a host app that declares acronym inflections, which change the
    # constant names Zeitwerk expects from file names. Set by
    # test/lib/rails_pulse/zeitwerk_test.rb when it runs zeitwerk:check.
    if ENV["RAILS_PULSE_TEST_ACRONYMS"].present?
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        ENV["RAILS_PULSE_TEST_ACRONYMS"].split(",").each { |acronym| inflect.acronym(acronym.strip) }
      end
    end

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false
  end
end
