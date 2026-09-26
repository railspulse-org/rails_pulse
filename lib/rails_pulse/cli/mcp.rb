require_relative "base_command"

module RailsPulse
  module CLI
    class Mcp < BaseCommand
      default_task :start

      desc "start", "Start the Rails Pulse MCP server (stdio transport)"
      long_desc <<~DESC
        Starts a Model Context Protocol (MCP) server over stdio.

        The MCP server exposes Rails Pulse performance data as structured tools
        for AI coding agents (Claude Code, Codex, Cursor, etc.).

        Configure your MCP client to run:
          rails-pulse mcp

        The server uses the same credentials as the CLI — set them with
        `rails-pulse configure` or via RAILS_PULSE_URL / RAILS_PULSE_TOKEN
        environment variables.

        Available tools:
          rails_pulse_routes                — Discover endpoints with traffic and latency
          rails_pulse_slow_requests         — Slowest endpoints for a period
          rails_pulse_errors                — Recent errors grouped by endpoint
          rails_pulse_endpoint              — Deep profile of a single endpoint
          rails_pulse_queries               — Expensive and N+1 SQL queries
          rails_pulse_jobs                  — Background job health and recent failures
          rails_pulse_deployments           — Deployments, with regression outcomes under Pro
          rails_pulse_request_stats         — Period stats with comparison (Rails Pulse Pro)
          rails_pulse_alerts                — Recent alert triggers grouped by rule (Rails Pulse Pro)
          rails_pulse_alert_rules           — Configured rules, cooldown state, quiet hours (Rails Pulse Pro)
          rails_pulse_suggested_thresholds  — Backtested alert threshold suggestions (Rails Pulse Pro)
          rails_pulse_setup                 — Setup and tuning checklist (Rails Pulse Pro)

        Tools marked Rails Pulse Pro need the rails_pulse_pro gem in the application;
        without it they explain what is missing instead of failing.
      DESC
      def start
        require_relative "../mcp/server"
        RailsPulse::Mcp::Server.start!
      rescue RailsPulse::CLI::Config::ConfigError => e
        # Write errors to stderr — stdout is reserved for MCP JSON-RPC
        $stderr.puts "Rails Pulse MCP error: #{e.message}"
        exit 1
      rescue RailsPulse::Mcp::Server::MissingDependencyError => e
        $stderr.puts "Rails Pulse MCP error: #{e.message}"
        exit 1
      end
    end
  end
end
