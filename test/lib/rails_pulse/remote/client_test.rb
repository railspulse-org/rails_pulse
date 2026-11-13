require "test_helper"

module RailsPulse
  module Remote
    class ClientTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      setup do
        @settings = Configuration::RemoteSettings.new
        @settings.url = "https://pulse.example.com"
        @settings.token = "remote-token-#{'x' * 32}"
      end

      # Structure Tests

      test "posts the gzipped batch with the token, the contract version and a vendor content type" do
        captured = nil
        stub_http_response(202, { accepted: 1 }.to_json) { |request, uri| captured = [ request, uri ] }
        body = Batch.new([ Item.new("writer_heartbeat", { pid: 1 }) ]).body

        response = Client.new(@settings).post(body)
        request, uri = captured

        assert_equal 202, response.status
        assert_equal 1, response.json["accepted"]
        assert_equal "https://pulse.example.com/rails_pulse/v1/batches", uri.to_s
        assert_equal "Bearer remote-token-#{'x' * 32}", request["Authorization"]
        assert_equal "gzip", request["Content-Encoding"]
        assert_equal "application/vnd.rails-pulse.batch+json", request["Content-Type"]
        assert_equal "1", request["Rails-Pulse-Remote-Contract"]
        assert_match %r{\Arails_pulse/#{Regexp.escape(RailsPulse::VERSION)} \(remote; ruby .+; rails .+\)\z}, request["User-Agent"]
        assert_equal body, request.body
      end

      test "keeps a path on the configured URL" do
        @settings.url = "https://example.com/pulse/"
        captured = nil
        stub_http_response(202, "{}") { |_request, uri| captured = uri }

        Client.new(@settings).post("")

        assert_equal "https://example.com/pulse/rails_pulse/v1/batches", captured.to_s
      end

      test "reads the settings from the configuration when none are given" do
        with_remote(url: "https://central.example.com", token: "t" * 40) do
          assert_equal "https://central.example.com/rails_pulse/v1/batches", Client.new.endpoint.to_s
        end
      end

      test "an error body is read for its message" do
        stub_http_response(422, { error: "contract version 2 is not supported" }.to_json)

        assert_equal "contract version 2 is not supported", Client.new(@settings).post("").message
      end

      # Edge Cases

      test "a refused connection or a timeout is raised as Unavailable" do
        stub_http_failure(Net::OpenTimeout)

        error = assert_raises(Client::Unavailable) { Client.new(@settings).post("") }

        assert_includes error.message, "Net::OpenTimeout"
      end

      test "a body that is not JSON gives the status as the message" do
        stub_http_response(502, "<html>Bad Gateway</html>")

        response = Client.new(@settings).post("")

        assert_equal "HTTP 502", response.message
        assert_equal({}, response.json)
      end

      private

      def with_remote(url:, token:)
        remote = RailsPulse.configuration.remote
        remote.url = url
        remote.token = token
        yield
      ensure
        remote.remove_instance_variable(:@url)
        remote.remove_instance_variable(:@token)
      end
    end
  end
end
