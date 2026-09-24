require "mcp"
require "rails_pulse/version"
require_relative "../cli/config"
require_relative "../cli/client"
require_relative "tools/helpers"
require_relative "tools/slow_requests"
require_relative "tools/request_stats"
require_relative "tools/errors"
require_relative "tools/endpoint"
require_relative "tools/queries"
require_relative "tools/jobs"
require_relative "tools/routes"
require_relative "tools/alerts"
require_relative "tools/alert_rules"
require_relative "tools/deployments"
require_relative "tools/suggested_thresholds"
require_relative "tools/setup"

module RailsPulse
  module Mcp
    # Read-only MCP server over stdio. Every tool goes through the JSON API
    # with the same token as the CLI; nothing here touches the database or
    # the application directly.
    class Server
      def self.start!
        server = build_server
        transport = ::MCP::Server::Transports::StdioTransport.new(server)
        transport.open
      end

      def self.build_server(client: nil)
        config = CLI::Config.load
        client ||= CLI::Client.new(config)

        ::MCP::Server.new(
          name: "rails_pulse",
          version: RailsPulse::VERSION,
          tools: tools,
          server_context: { client: client }
        )
      end

      # The diagnosis tools work with the free gem alone. The rest read data
      # only rails_pulse_pro produces; without it they answer with what is
      # missing (see Tools::Helpers#respond).
      def self.tools
        [
          Tools::Routes,
          Tools::SlowRequests,
          Tools::Errors,
          Tools::Endpoint,
          Tools::Queries,
          Tools::Jobs,
          Tools::Deployments,
          Tools::RequestStats,
          Tools::Alerts,
          Tools::AlertRules,
          Tools::SuggestedThresholds,
          Tools::Setup
        ]
      end
    end
  end
end
