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

        Existing values are shown as defaults — press Enter to keep them.

        A test request is made before saving. If it fails, no file is written.
        Credentials are saved to ~/.rails-pulse (never to the project directory).

        You can also skip this command and set environment variables instead:
          RAILS_PULSE_URL, RAILS_PULSE_TOKEN, RAILS_PULSE_MOUNT_PATH (optional)
      DESC
      def setup
        current = begin
          Config.load
        rescue Config::ConfigError
          nil
        end

        url_prompt = current ? "Rails Pulse URL [#{current.url}]" : "Rails Pulse URL"
        url = ask("#{url_prompt}:")
        url = current.url if url.to_s.empty? && current

        token = ask("API token:")
        token = current.token if token.to_s.empty? && current

        say "Testing connection..."
        begin
          test_config = Config.new(url: url, token: token)
          Client.new(test_config).get("/routes", { limit: 1 })
        rescue Client::ApiError => e
          say "Connection failed: #{e.message}", :red
          return
        rescue => e
          say "Connection failed: #{e.message}", :red
          return
        end

        Config.write!(url: url, token: token)
        say "Configuration saved to ~/.rails-pulse", :green
      end
    end
  end
end
