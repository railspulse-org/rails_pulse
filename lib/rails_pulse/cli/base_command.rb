require "thor"
require_relative "config"
require_relative "client"

module RailsPulse
  module CLI
    class BaseCommand < Thor
      no_commands do
        def with_error_handling
          yield
        rescue RailsPulse::CLI::Config::ConfigError => e
          say "Error: #{e.message}.", :red
          exit 1
        rescue RailsPulse::CLI::Client::ExtensionRequiredError => e
          say e.message, :yellow
          say "See #{e.url}" if e.url
          exit 1
        rescue RailsPulse::CLI::Client::ApiError => e
          say "API error: #{e.message}", :red
          exit 1
        end
      end

      private

      def client
        @client ||= Client.new
      end
    end
  end
end
