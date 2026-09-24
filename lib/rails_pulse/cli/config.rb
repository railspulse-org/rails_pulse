require "yaml"

module RailsPulse
  module CLI
    # Where the CLI and MCP server find the app to talk to. Environment
    # variables win; otherwise ~/.rails-pulse (or RAILS_PULSE_CONFIG), written
    # by `rails-pulse configure`.
    class Config
      class ConfigError < StandardError; end

      DEFAULT_PATH = "~/.rails-pulse".freeze
      DEFAULT_MOUNT_PATH = "/rails_pulse".freeze

      attr_reader :url, :token, :mount_path

      def initialize(url:, token:, mount_path: DEFAULT_MOUNT_PATH)
        @url        = url.to_s.chomp("/")
        @token      = token.to_s
        @mount_path = "/#{mount_path.to_s.delete_prefix("/").chomp("/")}"
      end

      def self.path
        File.expand_path(ENV.fetch("RAILS_PULSE_CONFIG", DEFAULT_PATH))
      end

      def self.load
        url        = ENV["RAILS_PULSE_URL"]
        token      = ENV["RAILS_PULSE_TOKEN"]
        mount_path = ENV["RAILS_PULSE_MOUNT_PATH"]

        if url.nil? || token.nil? || mount_path.nil?
          begin
            data       = YAML.safe_load_file(path) || {}
            url        ||= data["url"]
            token      ||= data["token"]
            mount_path ||= data["mount_path"]
          rescue Errno::ENOENT
            # Config file not yet created
          end
        end

        url = url.to_s.chomp("/")

        raise ConfigError, "RAILS_PULSE_URL is not set. Run 'rails-pulse configure'" if url.empty?
        raise ConfigError, "RAILS_PULSE_TOKEN is not set. Run 'rails-pulse configure'" if token.to_s.empty?

        new(url: url, token: token, mount_path: mount_path || DEFAULT_MOUNT_PATH)
      end

      def self.write!(url:, token:, mount_path: nil)
        data = { "url" => url.to_s.chomp("/"), "token" => token.to_s }
        data["mount_path"] = mount_path if mount_path && mount_path != DEFAULT_MOUNT_PATH
        File.write(path, YAML.dump(data))
      end
    end
  end
end
