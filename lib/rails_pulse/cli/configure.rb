require_relative "base_command"
require_relative "config"
require_relative "client"

module RailsPulse
  module CLI
    class Configure < BaseCommand
      default_task :setup

      desc "setup", "Prompt for URL and API token, test the connection, and write ~/.rails-pulse"
      long_desc <<~DESC
        Interactively configure credentials for the Rails Pulse JSON API.

        Prompts for:
          - Rails Pulse URL  (e.g. http://localhost:3000)
          - API token        (matches config.api_token in the app's Rails Pulse initializer)
          - Mount path       (where the engine is mounted; default /rails_pulse)

        Existing values are shown as defaults — press Enter to keep them.
        The token is not echoed as you type it.

        A test request is made before saving. If it fails, no file is written.
        Credentials are saved to ~/.rails-pulse (never to the project directory),
        readable only by you.

        You can also skip this command and set environment variables instead:
          RAILS_PULSE_URL, RAILS_PULSE_TOKEN, RAILS_PULSE_MOUNT_PATH (optional)
      DESC
      def setup
        current = begin
          Config.load
        rescue Config::ConfigError
          nil
        end

        url = ask_with_default("Rails Pulse URL", current&.url)
        token = ask_with_default("API token", current&.token, echo: false, mask: true)
        mount_path = ask_with_default("Mount path", current&.mount_path || Config::DEFAULT_MOUNT_PATH)

        say "Testing connection..."
        begin
          test_config = Config.new(url: url, token: token, mount_path: mount_path)
          Client.new(test_config).get("/routes", { limit: 1 })
        rescue Config::ConfigError, Client::ApiError => e
          say "Connection failed: #{e.message}", :red
          return
        end

        Config.write!(url: url, token: token, mount_path: test_config.mount_path)
        say "Configuration saved to #{Config.path}", :green
      end

      private

      # Prompts with the current value as the default; an empty answer keeps
      # it. A masked default shows only that a value exists, never the token.
      def ask_with_default(label, default, echo: true, mask: false)
        prompt = if default.to_s.empty?
          "#{label}:"
        else
          "#{label} [#{mask ? 'keep current' : default}]:"
        end
        answer = ask(prompt, echo: echo)
        say "" unless echo
        answer.to_s.empty? ? default.to_s : answer
      end
    end
  end
end
