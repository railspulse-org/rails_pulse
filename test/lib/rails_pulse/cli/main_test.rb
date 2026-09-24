require "test_helper"
require "rails_pulse/cli/main"

module RailsPulse
  module CLI
    class MainTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      # --- help output ---

      test "help with no command outputs examples section" do
        cmd = Main.new([])

        out, _err = capture_io { cmd.help(nil) }

        assert_includes out, "Examples:"
        assert_includes out, "rails-pulse configure"
        assert_includes out, "rails-pulse summary show"
      end

      test "help with a specific command does not output examples section" do
        cmd = Main.new([])

        out, _err = capture_io { cmd.help("routes") }

        refute_includes out, "Examples:"
      end

      # --- subcommand registration ---

      test "all expected subcommands are registered" do
        registered = Main.all_tasks.keys

        %w[configure install routes requests queries jobs alerts job_runs alert_rules deployments thresholds summary mcp].each do |name|
          assert_includes registered, name, "Expected '#{name}' to be registered"
        end
      end
    end
  end
end
