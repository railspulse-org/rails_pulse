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

      def make_cmd(url_input, token_input)
        cmd = Configure.new([])
        inputs = [ url_input, token_input ]
        idx = 0
        cmd.define_singleton_method(:ask) { |_prompt| inputs[idx].tap { idx += 1 } }
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

        assert_includes out, "Configuration saved"
      end

      test "saved file contains provided url and token" do
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("https://example.com", "my-token")

        capture_io { cmd.setup }

        data = YAML.safe_load_file(@config_path)

        assert_equal "https://example.com", data["url"]
        assert_equal "my-token",            data["token"]
      end

      # --- connection failure ---

      test "does not save config on API error" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        cmd = make_cmd("https://example.com", "bad-token")

        capture_io { cmd.setup }

        refute_path_exists @config_path
      end

      test "outputs 'Connection failed' on API error" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        cmd = make_cmd("https://example.com", "bad-token")

        out, _err = capture_io { cmd.setup }

        assert_includes out, "Connection failed"
      end

      test "does not save config on generic connection error" do
        stub_http_response(500, "Internal Server Error")
        cmd = make_cmd("https://example.com", "token")

        capture_io { cmd.setup }

        refute_path_exists @config_path
      end

      # --- existing config as default ---

      test "keeps existing url when input is blank" do
        File.write(@config_path, { "url" => "https://existing.com", "token" => "existing-token" }.to_yaml)
        stub_http_response(200, SUCCESS_BODY)
        cmd = make_cmd("", "")

        capture_io { cmd.setup }

        data = YAML.safe_load_file(@config_path)

        assert_equal "https://existing.com", data["url"]
        assert_equal "existing-token",       data["token"]
      end
    end
  end
end
