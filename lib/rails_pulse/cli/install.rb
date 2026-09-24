require "fileutils"
require_relative "base_command"

module RailsPulse
  module CLI
    class Install < BaseCommand
      AGENT_FILES_DIR = File.expand_path("agent_files", __dir__)

      # Claude Code loads skills from ~/.claude/skills/<name>/SKILL.md; the
      # file carries its own name and description in YAML front matter.
      CLAUDE_SKILL_PATH = "~/.claude/skills/rails-pulse/SKILL.md".freeze

      INTEGRATIONS = {
        "claude" => {
          description: "Claude Code skill → #{CLAUDE_SKILL_PATH}",
          source: "claude_skill.md"
        },
        "agents" => {
          description: "Generic agent descriptor → ./agents.md",
          source: "agents.md"
        }
      }.freeze

      default_task :perform

      desc "perform [INTEGRATION]", "Install an AI agent integration file"
      long_desc <<~DESC
        Copy a pre-built integration file to the correct location for the given agent framework.

        Available integrations:
          claude   Installs a Claude Code skill to #{CLAUDE_SKILL_PATH}.
                   Claude Code then knows when and how to use the Rails Pulse MCP tools and CLI.
          agents   Installs a generic agent descriptor to ./agents.md in the current directory.
                   Compatible with other AI agent frameworks.

        Run --list to see all available integrations.
      DESC
      option :list, type: :boolean, desc: "List all available integrations and their destinations"
      def perform(integration = nil)
        if options[:list]
          say "Available integrations:"
          INTEGRATIONS.each { |name, meta| say "  #{name.ljust(10)} #{meta[:description]}" }
          return
        end

        case integration
        when "claude"
          install_claude
        when "agents"
          install_agents
        else
          say "Usage: rails-pulse install [claude|agents]", :yellow
          say "       rails-pulse install --list"
        end
      end

      private

      def install_claude
        dest = File.expand_path(CLAUDE_SKILL_PATH)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(File.join(AGENT_FILES_DIR, "claude_skill.md"), dest)
        say "Installed Claude Code skill to #{dest}", :green
      end

      def install_agents
        dest = File.join(Dir.pwd, "agents.md")
        FileUtils.cp(File.join(AGENT_FILES_DIR, "agents.md"), dest)
        say "Installed agent descriptor to #{dest}", :green
      end
    end
  end
end
