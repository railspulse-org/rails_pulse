require "test_helper"
require "rails_pulse/installers/config_updater"

module RailsPulse
  module Installers
    class ConfigUpdaterTest < ActiveSupport::TestCase
      def setup
        @dir = Dir.mktmpdir("rails_pulse_config_updater")
        @template = File.join(@dir, "template.rb")
        @destination = File.join(@dir, "rails_pulse.rb")
        @output = StringIO.new
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      # Missing (read-only) Tests

      test "missing reports what update would add without writing" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
            config.track_exceptions = true
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
          end
        RUBY
        before = File.read(@destination)

        missing = ConfigUpdater.missing(destination: @destination, source: @template)

        assert_equal({ keys: %w[track_exceptions], hash_keys: [] }, missing)
        assert_equal before, File.read(@destination)
      end

      test "missing is empty when the host file does not exist" do
        write_template "RailsPulse.configure do |config|\n  config.enabled = true\nend\n"

        assert_equal({ keys: [], hash_keys: [] }, ConfigUpdater.missing(destination: @destination, source: @template))
      end

      # Insert Tests

      test "inserts missing settings without rewriting existing values" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true

            # Exception tracking
            config.track_exceptions = true
            config.capture_exception_params = true
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
            config.tags = [ "custom" ]
          end
        RUBY

        result = update_config

        assert_equal :updated, result[:status]
        assert_equal %w[track_exceptions capture_exception_params], result[:keys]
        host = File.read(@destination)

        assert_includes host, 'config.tags = [ "custom" ]'
        assert_includes host, "config.enabled = true"
        assert_includes host, "config.track_exceptions = false"
        assert_includes host, "config.capture_exception_params = true"
        assert_includes host, "ADDED BY rails generate rails_pulse:upgrade"
        assert_valid_ruby host
      end

      test "uses gem default for track_exceptions instead of the install template value" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.track_exceptions = true
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
          end
        RUBY

        update_config

        assert_includes File.read(@destination), "config.track_exceptions = false"
        refute_includes File.read(@destination), "config.track_exceptions = true"
      end

      test "is a no-op when every template setting is already mentioned" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
            config.track_exceptions = true
          end
        RUBY
        original = <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = false
            # config.track_exceptions = true
          end
        RUBY
        write_host original

        result = update_config

        assert_equal :unchanged, result[:status]
        assert_equal original, File.read(@destination)
      end

      test "skips when the initializer is missing" do
        write_template "RailsPulse.configure do |config|\nend\n"

        result = update_config

        assert_equal :missing, result[:status]
        refute_path_exists @destination
      end

      test "does not duplicate settings when run twice" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.track_exceptions = true
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
          end
        RUBY

        update_config
        result = update_config

        assert_equal :unchanged, result[:status]
        assert_equal 1, File.read(@destination).scan("config.track_exceptions").size
      end

      test "inserts inside RailsPulse.configure when another end follows it" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.track_exceptions = true
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
          end

          Rails.application.config.to_prepare do
            RailsPulse::ApplicationController.skip_after_action :intercom_rails_auto_include, raise: false
          end
        RUBY

        update_config
        host = File.read(@destination)
        configure, trailing = host.split(/Rails\.application\.config\.to_prepare/, 2)

        assert_includes configure, "config.track_exceptions = false"
        refute_includes trailing, "config.track_exceptions"
        assert_includes trailing, "skip_after_action :intercom_rails_auto_include"
        assert_valid_ruby host
      end

      # Hash Entry Tests

      test "inserts missing max_table_records keys and preserves existing limits" do
        write_template <<~RUBY
          RailsPulse.configure do |config|
            config.max_table_records = {
              rails_pulse_requests: 10000,
              rails_pulse_exception_occurrences: 50000,
              rails_pulse_exception_groups: 10000
            }
          end
        RUBY
        write_host <<~RUBY
          RailsPulse.configure do |config|
            config.max_table_records = {
              rails_pulse_requests: 42,
              rails_pulse_queries: 500
            }
          end
        RUBY

        result = update_config

        assert_equal :updated, result[:status]
        assert_empty result[:keys]
        assert_equal %w[rails_pulse_exception_occurrences rails_pulse_exception_groups], result[:hash_keys]
        host = File.read(@destination)

        assert_includes host, "rails_pulse_requests: 42"
        assert_includes host, "rails_pulse_queries: 500,"
        assert_includes host, "rails_pulse_exception_occurrences: 50000"
        assert_includes host, "rails_pulse_exception_groups: 10000"
        assert_valid_ruby host
      end

      # Install Template Tests

      test "adds exception settings from the real install template into a 0.3.3 initializer" do
        write_host File.read(v033_initializer_path).sub(
          'config.tags = [ "ignored", "critical", "experimental" ]',
          'config.tags = [ "keep-me" ]'
        )

        result = RailsPulse::Installers::ConfigUpdater.update(
          destination: @destination,
          output: @output
        )

        assert_equal :updated, result[:status]
        assert_includes result[:keys], "track_exceptions"
        assert_includes result[:keys], "capture_exception_params"
        host = File.read(@destination)

        assert_includes host, 'config.tags = [ "keep-me" ]'
        assert_includes host, "config.track_exceptions = false"
        assert_includes host, "config.capture_exception_params = true"
        assert_includes host, "rails_pulse_exception_occurrences"
        assert_includes host, "rails_pulse_exception_groups"
        assert_valid_ruby host
      end

      private

      def write_template(content)
        File.write(@template, content)
      end

      def write_host(content)
        File.write(@destination, content)
      end

      def update_config
        ConfigUpdater.update(destination: @destination, source: @template, output: @output)
      end

      def v033_initializer_path
        path = File.join(@dir, "v0_3_3.rb")
        File.write(path, v033_initializer)
        path
      end

      def assert_valid_ruby(source)
        RubyVM::InstructionSequence.compile(source)
      end

      def v033_initializer
        # Shape of the 0.3.3 generated initializer: no exception settings, no
        # exception table limits, and a typical max_table_records hash.
        <<~RUBY
          RailsPulse.configure do |config|
            config.enabled = true
            config.track_assets = false
            config.tags = [ "ignored", "critical", "experimental" ]
            config.track_jobs = false
            config.archiving_enabled = true
            config.full_retention_period = 2.weeks
            config.max_table_records = {
              rails_pulse_requests: 10000,
              rails_pulse_operations: 50000,
              rails_pulse_routes: 1000,
              rails_pulse_queries: 500
            }
          end
        RUBY
      end
    end
  end
end
