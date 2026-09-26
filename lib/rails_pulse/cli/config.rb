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
      URL_SCHEMES = %r{\Ahttps?://\S+\z}i

      # The file holds the API token, so nobody else on the machine may read it.
      FILE_MODE = 0o600

      attr_reader :url, :token, :mount_path

      def initialize(url:, token:, mount_path: DEFAULT_MOUNT_PATH)
        @url        = url.to_s.chomp("/")
        @token      = token.to_s
        @mount_path = "/#{mount_path.to_s.delete_prefix("/").chomp("/")}"

        raise ConfigError, "RAILS_PULSE_URL must start with http:// or https:// (got #{@url.inspect})" unless @url.match?(URL_SCHEMES)
      end

      def self.path
        File.expand_path(ENV.fetch("RAILS_PULSE_CONFIG", DEFAULT_PATH))
      end

      def self.load
        url        = ENV["RAILS_PULSE_URL"]
        token      = ENV["RAILS_PULSE_TOKEN"]
        mount_path = ENV["RAILS_PULSE_MOUNT_PATH"]

        if url.nil? || token.nil? || mount_path.nil?
          data       = read_file
          url        ||= data["url"]
          token      ||= data["token"]
          mount_path ||= data["mount_path"]
        end

        url = url.to_s.chomp("/")

        raise ConfigError, "RAILS_PULSE_URL is not set. Run 'rails-pulse configure'" if url.empty?
        raise ConfigError, "RAILS_PULSE_TOKEN is not set. Run 'rails-pulse configure'" if token.to_s.empty?

        new(url: url, token: token, mount_path: mount_path || DEFAULT_MOUNT_PATH)
      end

      def self.write!(url:, token:, mount_path: nil)
        data = { "url" => url.to_s.chomp("/"), "token" => token.to_s }
        data["mount_path"] = mount_path if mount_path && mount_path != DEFAULT_MOUNT_PATH
        File.write(path, YAML.dump(data), perm: FILE_MODE)
        File.chmod(FILE_MODE, path)
      end

      # The parsed config file, or an empty hash when there is none yet.
      def self.read_file
        data = YAML.safe_load_file(path)
        raise ConfigError, "#{path} should be a YAML mapping with url and token keys" unless data.nil? || data.is_a?(Hash)

        data || {}
      rescue Errno::ENOENT
        {}
      rescue Psych::SyntaxError => e
        raise ConfigError, "#{path} is not valid YAML (#{e.message}). Fix it or run 'rails-pulse configure'"
      end
      private_class_method :read_file
    end
  end
end
