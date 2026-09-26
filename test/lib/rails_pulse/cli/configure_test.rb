require "test_helper"
require "rails_pulse/cli/configure"
require "tmpdir"

module RailsPulse
  module CLI
    class ConfigureTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      SUCCESS_BODY = '{"data":[],"meta":{"total":0,"limit":1,"offset":0}}'.freeze

      def setup
        @config_path = config_path
      end

      # Answers the URL, token and mount path prompts in turn and records
      # each prompt with the options it was asked with.
      def make_cmd(url_input, token_input, mount_input = "")
        cmd = Configure.new([])
        inputs = [ url_input, token_input, mount_input ]
        prompts = []
        cmd.define_singleton_method(:ask) { |prompt, **opts| prompts << [ prompt, opts ]; inputs.shift }
        cmd.define_singleton_method(:prompts) { prompts }
        cmd
      end

      # --- successful setup ---

      test "outputs 'Testing connection' before making the request" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        out, _err = capture_io { cmd.setup }

        assert_includes out, "Testing connection"
      end

      test "saves config file on successful connection" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        capture_io { cmd.setup }

        assert_path_exists @config_path
      end

      test "outputs confirmation on successful save" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        out, _err = capture_io { cmd.setup }

        assert_includes out, "Configuration saved to #{@config_path}"
      end

      test "saved file contains provided url and token" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        capture_io { cmd.setup }

        data = YAML.safe_load_file(@config_path)

        assert_equal "https://example.com", data["url"]
        assert_equal "my-token",            data["token"]
        assert_nil data["mount_path"]
      end

      test "asks for the token without echoing it" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        capture_io { cmd.setup }

        token_prompt = cmd.prompts.find { |prompt, _opts| prompt.start_with?("API token") }

        assert_equal({ echo: false }, token_prompt.last)
      end

      # --- mount path ---

      test "tests the connection against the given mount path and saves it" do
        requested = nil
        stub_http_response(200, SUCCESS_BODY) { |req, _uri| requested = req.path }
        cmd = make_cmd("https://example.com", "my-token", "/monitoring")

        capture_io { cmd.setup }

        assert_equal "/monitoring/api/v1/routes?limit=1", requested
        assert_equal "/monitoring", YAML.safe_load_file(@config_path)["mount_path"]
      end

      test "keeps an existing mount path when the answer is blank" do
        File.write(@config_path, { "url" => "https://existing.com", "token" => "existing-token", "mount_path" => "/monitoring" }.to_yaml)
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("", "", "")

        capture_io { cmd.setup }

        assert_equal "/monitoring", YAML.safe_load_file(@config_path)["mount_path"]
        assert_includes cmd.prompts.map(&:first), "Mount path [/monitoring]:"
      end

      # --- connection failure ---

      test "does not save config on API error" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        cmd = make_cmd("https://example.com", "bad-token")

        capture_io { cmd.setup }

        refute_path_exists @config_path
      end

      test "outputs 'Connection failed' with the API's reason" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        cmd = make_cmd("https://example.com", "bad-token")

        out, _err = capture_io { cmd.setup }

        assert_includes out, "Connection failed: 401: Unauthorized"
      end

      test "does not save config on generic connection error" do
        stub_http_response(500, "Internal Server Error")
        cmd = make_cmd("https://example.com", "token")

        capture_io { cmd.setup }

        refute_path_exists @config_path
      end

      test "rejects a url without a scheme before making a request" do
        cmd = make_cmd("localhost:3000", "token")

        out, _err = capture_io { cmd.setup }

        assert_includes out, "Connection failed"
        assert_includes out, "must start with http:// or https://"
        refute_path_exists @config_path
      end

      # --- existing config as default ---

      test "keeps existing url and token when input is blank" do
        File.write(@config_path, { "url" => "https://existing.com", "token" => "existing-token" }.to_yaml)
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("", "")

        capture_io { cmd.setup }

        data = YAML.safe_load_file(@config_path)

        assert_equal "https://existing.com", data["url"]
        assert_equal "existing-token",       data["token"]
      end

      test "never shows the existing token in the prompt" do
        File.write(@config_path, { "url" => "https://existing.com", "token" => "existing-token" }.to_yaml)
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("", "")

        capture_io { cmd.setup }

        token_prompt = cmd.prompts.map(&:first).find { |prompt| prompt.start_with?("API token") }

        assert_equal "API token [keep current]:", token_prompt
      end
    end
  end
end
