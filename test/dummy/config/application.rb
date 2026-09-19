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

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false
  end
end
