require "thor"
require_relative "configure"
require_relative "install"
require_relative "routes"
require_relative "requests"
require_relative "queries"
require_relative "jobs"
require_relative "alerts"
require_relative "job_runs"
require_relative "alert_rules"
require_relative "deployments"
require_relative "thresholds"
require_relative "summary"
require_relative "setup"
require_relative "mcp"

module RailsPulse
  module CLI
    class Main < Thor
      register(Configure, "configure", "configure",
               "Prompt for URL and API token, test the connection, and write ~/.rails-pulse")
      register(Install,   "install",   "install [INTEGRATION]",
               "Install AI agent integration files (claude, agents). Use --list to see options")
      register(Routes,    "routes",    "routes SUBCOMMAND",
               "List tracked HTTP routes and their tags")
      register(Requests,  "requests",  "requests SUBCOMMAND",
               "List recorded HTTP requests with optional status and time filters")
      register(Queries,   "queries",   "queries SUBCOMMAND",
               "List tracked SQL queries and their analysis results")
      register(Jobs,      "jobs",      "jobs SUBCOMMAND",
               "List background jobs with run counts, failure rates, and duration stats")
      register(Alerts,    "alerts",    "alerts SUBCOMMAND",
               "List fired alert events with optional rule and time filters (extension)")
      register(JobRuns,   "job_runs",  "job_runs SUBCOMMAND",
               "List individual job runs with status, job, and time filters")
      register(AlertRules, "alert_rules", "alert_rules SUBCOMMAND",
               "List configured alert rules with cooldown state and recent trigger counts (extension)")
      register(Deployments, "deployments", "deployments SUBCOMMAND",
               "List deployments; regression check outcomes come from an extension")
      register(Thresholds, "thresholds", "thresholds SUBCOMMAND",
               "Suggest backtested alert thresholds from recent performance data (extension)")
      register(Summary,   "summary",   "summary SUBCOMMAND",
               "Show a weekly or monthly performance summary with insights and recommendations (extension)")
      register(Setup,     "setup",     "setup SUBCOMMAND",
               "Check what still needs configuring and get data-driven config suggestions (extension)")
      register(Mcp,       "mcp",       "mcp",
               "Start MCP server for AI coding agents (Claude Code, Codex, Cursor)")

      no_commands do
        def help(command = nil, subcommand = false)
          super
          return if command

          say ""
          say "Examples:"
          say "  rails-pulse configure                                       # Set up credentials interactively"
          say "  rails-pulse routes list                                     # List all tracked routes"
          say "  rails-pulse requests list --status 5xx --limit 10          # Last 10 server errors"
          say "  rails-pulse requests list --since 2026-06-01T00:00:00Z     # Requests since a timestamp"
          say "  rails-pulse queries list --json                             # Queries with full analysis fields"
          say "  rails-pulse jobs list --status failed                      # Jobs with at least one failure"
          say "  rails-pulse alerts list --rule \"High P95 Response Time\"    # Events for a specific rule"
          say "  rails-pulse alert_rules list                                # Configured rules and cooldown state"
          say "  rails-pulse job_runs list --status failed --job ReportJob   # Recent failed runs of one job"
          say "  rails-pulse deployments list                                # Deploys with regression outcomes"
          say "  rails-pulse thresholds show --days 14                       # Backtested alert threshold suggestions"
          say "  rails-pulse summary show                                    # This week's performance summary"
          say "  rails-pulse summary show --period month --json              # Last month as JSON for AI agents"
          say "  rails-pulse setup check                                     # What still needs configuring, with snippets"
          say "  rails-pulse install claude                                  # Install Claude Code skill file"
          say "  rails-pulse mcp                                             # Start MCP server for AI agents"
          say ""
          say "Credentials are read from RAILS_PULSE_URL / RAILS_PULSE_TOKEN env vars or ~/.rails-pulse."
          say "Commands marked (extension) need an extension the application may not have; they say so when run."
          say "Run 'rails-pulse configure' to set them up, or 'rails-pulse help COMMAND' for detailed flags."
        end
      end
    end
  end
end
