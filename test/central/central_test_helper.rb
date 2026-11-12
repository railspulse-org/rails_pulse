# Boots the dummy app as a central (RailsPulse::Central) receiving from two
# applications, alpha and beta, each in its own SQLite database, and loads
# the Rails Pulse schema into both through db:schema:load_rails_pulse, the
# task a central's db:prepare runs first.
#
# Run with `rake test_central`, or `RAILS_PULSE_TEST_CENTRAL=true bin/rails
# test test/central`. test/test_helper.rb boots the same app as an ordinary
# install, with fixtures in its one database; a central has no default
# database to load fixtures into, so the two cannot share a process, and
# these tests skip themselves when the process was booted the other way.
ENV["RAILS_ENV"] = "test"

require "dotenv/load" if File.exist?(".env")
require "fileutils"
require "rake"

unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.initialized?
  ENV["RAILS_PULSE_TEST_CENTRAL"] ||= "true"
  # A fresh database per run, so the schema loaded is this checkout's.
  FileUtils.rm_f(Dir[File.expand_path("../dummy/storage/test_central_*.sqlite3*", __dir__)])
end

require_relative "../dummy/config/environment"
require "rails/test_help"
require "mocha/minitest"
require_relative "../support/rails_pulse_test_reporter"
require_relative "../support/api_client_test_helpers"
require_relative "../support/configuration_test_helpers"

Minitest::Reporters.use!(RailsPulseTestReporter.new)

if RailsPulse::Central.enabled? && !defined?(CENTRAL_SCHEMA_LOADED)
  CENTRAL_SCHEMA_LOADED = true
  Rails.application.load_tasks unless Rake::Task.task_defined?("db:schema:load_rails_pulse")
  original_stdout = $stdout
  $stdout = StringIO.new
  begin
    Rake::Task["db:schema:load_rails_pulse"].invoke
  ensure
    $stdout = original_stdout
  end
end

module RailsPulse
  class CentralTestCase < ActiveSupport::TestCase
    include ConfigurationTestHelpers

    self.use_transactional_tests = true

    ALPHA_TOKEN = "alpha-#{'a' * 40}".freeze
    BETA_TOKEN = "beta-#{'b' * 40}".freeze

    setup do
      skip "central mode tests run in their own process: rake test_central" unless RailsPulse::Central.enabled?

      RailsPulse::Tracker.reset_rollups!
      RailsPulse::SchemaCheck.reset!
      RailsPulse::ExceptionCaptureService.reset_deploy_sha_cache!
    end

    private

    def in_application(name, &block)
      RailsPulse::Central.with_application(name, &block)
    end
  end

  class CentralIntegrationTest < ActionDispatch::IntegrationTest
    include ConfigurationTestHelpers

    self.use_transactional_tests = true

    ALPHA_TOKEN = CentralTestCase::ALPHA_TOKEN
    BETA_TOKEN = CentralTestCase::BETA_TOKEN

    setup do
      skip "central mode tests run in their own process: rake test_central" unless RailsPulse::Central.enabled?

      RailsPulse::Tracker.reset_rollups!
      RailsPulse::SchemaCheck.reset!
      RailsPulse::ExceptionCaptureService.reset_deploy_sha_cache!
    end

    private

    def in_application(name, &block)
      RailsPulse::Central.with_application(name, &block)
    end

    # A batch as RailsPulse::Remote::Batch builds it, posted the way
    # RailsPulse::Remote::Client posts it.
    def post_batch(items, token: ALPHA_TOKEN, batch_id: SecureRandom.uuid, gzip: true, body: nil)
      body ||= begin
        batch = RailsPulse::Remote::Batch.new(items, batch_id: batch_id)
        gzip ? batch.body : Zlib.gunzip(batch.body)
      end
      headers = {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => RailsPulse::Remote::Client::CONTENT_TYPE
      }
      headers["Content-Encoding"] = "gzip" if gzip
      post "/rails_pulse/v1/batches", params: body, headers: headers
    end

    def item(type, attributes)
      RailsPulse::Remote::Item.new(type, attributes)
    end
  end
end
