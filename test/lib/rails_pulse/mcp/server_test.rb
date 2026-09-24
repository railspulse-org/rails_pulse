require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ServerTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      setup do
        ENV["RAILS_PULSE_URL"]   = "https://example.com"
        ENV["RAILS_PULSE_TOKEN"] = "test-token"
      end

      teardown do
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")
      end

      test "build_server returns an MCP::Server" do
        server = Server.build_server

        assert_kind_of ::MCP::Server, server
      end

      test "server has correct name and version" do
        server = Server.build_server

        assert_equal "rails_pulse", server.name
        assert_equal RailsPulse::VERSION, server.version
      end

      test "server registers all twelve expected tools" do
        server = Server.build_server
        tool_names = server.tools.keys.sort

        assert_equal %w[
          rails_pulse_alert_rules
          rails_pulse_alerts
          rails_pulse_deployments
          rails_pulse_endpoint
          rails_pulse_errors
          rails_pulse_jobs
          rails_pulse_queries
          rails_pulse_request_stats
          rails_pulse_routes
          rails_pulse_setup
          rails_pulse_slow_requests
          rails_pulse_suggested_thresholds
        ], tool_names
      end

      test "all tools are read-only" do
        server = Server.build_server

        server.tools.each_value do |tool|
          assert tool.annotations.read_only_hint,
                 "Expected #{tool.tool_name} to have read_only_hint: true"
        end
      end

      test "all tools have descriptions" do
        server = Server.build_server

        server.tools.each_value do |tool|
          assert_predicate tool.description, :present?,
                 "Expected #{tool.tool_name} to have a description"
        end
      end

      test "server passes client through server_context" do
        config = CLI::Config.new(url: "https://example.com", token: "tok")
        client = CLI::Client.new(config)
        server = Server.build_server(client: client)

        assert_equal client, server.instance_variable_get(:@server_context)[:client]
      end

      test "tools list matches Server.tools" do
        expected = Server.tools.map(&:tool_name).sort
        server = Server.build_server
        actual = server.tools.keys.sort

        assert_equal expected, actual
      end

      test "build_server fails without credentials" do
        ENV.delete("RAILS_PULSE_URL")
        ENV.delete("RAILS_PULSE_TOKEN")

        assert_raises(CLI::Config::ConfigError) { Server.build_server }
      end
    end
  end
end
