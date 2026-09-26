require "test_helper"
require "rails_pulse/cli/config"
require "tmpdir"

module RailsPulse
  module CLI
    class ConfigTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      setup do
        @config_path = config_path
      end

      test "path defaults to ~/.rails-pulse and follows RAILS_PULSE_CONFIG" do
        assert_equal @config_path, Config.path

        ENV.delete("RAILS_PULSE_CONFIG")

        assert_equal File.expand_path("~/.rails-pulse"), Config.path
      end

      test "loads url and token from environment variables" do
        ENV["RAILS_PULSE_URL"]   = "https://example.com"
        ENV["RAILS_PULSE_TOKEN"] = "env-token"
        config = Config.load

        assert_equal "https://example.com", config.url
        assert_equal "env-token", config.token
      end

      test "strips trailing slash from url when loading from env" do
        ENV["RAILS_PULSE_URL"]   = "https://example.com/"
        ENV["RAILS_PULSE_TOKEN"] = "token"
        config = Config.load

        assert_equal "https://example.com", config.url
      end

      test "loads url and token from yaml config file" do
        File.write(@config_path, { "url" => "https://myapp.com", "token" => "file-token" }.to_yaml)
        config = Config.load

        assert_equal "https://myapp.com", config.url
        assert_equal "file-token", config.token
      end

      test "strips trailing slash from yaml url on load" do
        File.write(@config_path, { "url" => "https://myapp.com/", "token" => "t" }.to_yaml)
        config = Config.load

        assert_equal "https://myapp.com", config.url
      end

      test "raises ConfigError when url is missing" do
        ENV["RAILS_PULSE_TOKEN"] = "token"
        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(/RAILS_PULSE_URL/, err.message)
      end

      test "raises ConfigError when token is missing" do
        ENV["RAILS_PULSE_URL"] = "https://example.com"
        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(/RAILS_PULSE_TOKEN/, err.message)
      end

      test "raises ConfigError when config file does not exist" do
        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(/RAILS_PULSE_URL/, err.message)
      end

      test "env vars take precedence over config file" do
        File.write(@config_path, { "url" => "https://file-url.com", "token" => "file-token" }.to_yaml)
        ENV["RAILS_PULSE_URL"]   = "https://env-url.com"
        ENV["RAILS_PULSE_TOKEN"] = "env-token"
        config = Config.load

        assert_equal "https://env-url.com", config.url
        assert_equal "env-token", config.token
      end

      test "defaults mount_path to /rails_pulse" do
        ENV["RAILS_PULSE_URL"]   = "https://example.com"
        ENV["RAILS_PULSE_TOKEN"] = "token"
        config = Config.load

        assert_equal "/rails_pulse", config.mount_path
      end

      test "loads mount_path from RAILS_PULSE_MOUNT_PATH env var" do
        ENV["RAILS_PULSE_URL"]        = "https://example.com"
        ENV["RAILS_PULSE_TOKEN"]      = "token"
        ENV["RAILS_PULSE_MOUNT_PATH"] = "/monitoring"
        config = Config.load

        assert_equal "/monitoring", config.mount_path
      end

      test "loads mount_path from yaml config file" do
        File.write(@config_path, { "url" => "https://myapp.com", "token" => "t", "mount_path" => "/custom" }.to_yaml)
        config = Config.load

        assert_equal "/custom", config.mount_path
      end

      test "normalizes mount_path to always have leading slash" do
        config = Config.new(url: "https://example.com", token: "t", mount_path: "rails_pulse")

        assert_equal "/rails_pulse", config.mount_path
      end

      test "normalizes mount_path to strip trailing slash" do
        config = Config.new(url: "https://example.com", token: "t", mount_path: "/rails_pulse/")

        assert_equal "/rails_pulse", config.mount_path
      end

      test "write! saves url and token to yaml file" do
        Config.write!(url: "https://saved.com", token: "saved-token")
        data = YAML.safe_load_file(@config_path)

        assert_equal "https://saved.com", data["url"]
        assert_equal "saved-token", data["token"]
      end

      test "write! strips trailing slash from url" do
        Config.write!(url: "https://saved.com/", token: "t")
        data = YAML.safe_load_file(@config_path)

        assert_equal "https://saved.com", data["url"]
      end

      test "write! omits mount_path when it is the default" do
        Config.write!(url: "https://saved.com", token: "t", mount_path: "/rails_pulse")
        data = YAML.safe_load_file(@config_path)

        assert_nil data["mount_path"]
      end

      test "write! saves mount_path when it differs from the default" do
        Config.write!(url: "https://saved.com", token: "t", mount_path: "/monitoring")
        data = YAML.safe_load_file(@config_path)

        assert_equal "/monitoring", data["mount_path"]
      end

      # --- file permissions ---

      test "write! makes the file readable by its owner only" do
        Config.write!(url: "https://saved.com", token: "secret")

        assert_equal 0o600, File.stat(@config_path).mode & 0o777
      end

      test "write! tightens the mode of an existing world-readable file" do
        File.write(@config_path, "", perm: 0o644)
        File.chmod(0o644, @config_path)

        Config.write!(url: "https://saved.com", token: "secret")

        assert_equal 0o600, File.stat(@config_path).mode & 0o777
      end

      # --- malformed input ---

      test "load raises ConfigError when the config file is not valid YAML" do
        File.write(@config_path, "url: [unclosed\ntoken: t\n")

        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(/not valid YAML/, err.message)
        assert_includes err.message, @config_path
      end

      test "load raises ConfigError when the config file is not a mapping" do
        File.write(@config_path, "- just\n- a list\n")

        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(/YAML mapping/, err.message)
      end

      test "load raises ConfigError when the url has no scheme" do
        ENV["RAILS_PULSE_URL"]   = "localhost:3000"
        ENV["RAILS_PULSE_TOKEN"] = "t"

        err = assert_raises(Config::ConfigError) { Config.load }

        assert_match(%r{must start with http:// or https://}, err.message)
      end

      test "new accepts http and https urls" do
        assert_equal "http://localhost:3000", Config.new(url: "http://localhost:3000/", token: "t").url
        assert_equal "https://example.com", Config.new(url: "HTTPS://example.com", token: "t").url.downcase
      end
    end
  end
end
