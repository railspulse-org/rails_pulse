require "test_helper"
require "rails_pulse/cli/mcp"

module RailsPulse
  module CLI
    class McpTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      # --- registration ---

      test "mcp command is registered in Main" do
        require "rails_pulse/cli/main"
        registered = Main.all_tasks.keys

        assert_includes registered, "mcp"
      end

      # --- Pro gate: missing credentials ---

      test "mcp start fails without RAILS_PULSE_URL" do
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")

        cmd = Mcp.new([])

        err = assert_raises(SystemExit) do
          capture_io { cmd.start }
        end

        assert_equal 1, err.status
      end

      test "mcp start fails without RAILS_PULSE_TOKEN" do
        ENV["RAILS_PULSE_URL"] = "https://example.com"
        ENV.delete("RAILS_PULSE_TOKEN")

        cmd = Mcp.new([])

        err = assert_raises(SystemExit) do
          capture_io { cmd.start }
        end

        assert_equal 1, err.status
      ensure
        ENV.delete("RAILS_PULSE_URL")
      end

      # --- Pro gate: error message to stderr ---

      test "mcp start writes error to stderr not stdout" do
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")

        cmd = Mcp.new([])

        _out, err = capture_io do
          cmd.start
        rescue SystemExit
          # expected
        end

        assert_includes err, "Rails Pulse MCP error"
      end
    end
  end
end
