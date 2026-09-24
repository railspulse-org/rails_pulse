require "test_helper"
require "rails_pulse/cli/client"
require "rails_pulse/cli/config"

module RailsPulse
  module CLI
    class ClientTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      setup do
        @config = Config.new(url: "https://example.com", token: "test-token")
        @client = Client.new(@config)
      end

      teardown do
        restore_net_http_start
      end

      test "get sends X-Rails-Pulse-Token header" do
        sent_headers = {}
        stub_http_response(200, '{"data":[],"meta":{"total":0,"limit":25,"offset":0}}') do |req|
          sent_headers = req.to_hash
        end
        @client.get("/routes")

        assert_equal [ "test-token" ], sent_headers["x-rails-pulse-token"]
      end

      test "get builds correct URI with default mount path" do
        captured_uri = nil
        stub_http_response(200, '{"data":[],"meta":{"total":0,"limit":25,"offset":0}}') do |_req, uri|
          captured_uri = uri
        end
        @client.get("/routes")

        assert_equal "/rails_pulse/api/v1/routes", captured_uri.path
      end

      test "get uses custom mount_path from config" do
        config = Config.new(url: "https://example.com", token: "test-token", mount_path: "/monitoring")
        client = Client.new(config)
        captured_uri = nil
        stub_http_response(200, '{"data":[],"meta":{"total":0,"limit":25,"offset":0}}') do |_req, uri|
          captured_uri = uri
        end
        client.get("/routes")

        assert_equal "/monitoring/api/v1/routes", captured_uri.path
      end

      test "get appends query params to URI" do
        captured_uri = nil
        stub_http_response(200, '{"data":[],"meta":{"total":0,"limit":25,"offset":0}}') do |_req, uri|
          captured_uri = uri
        end
        @client.get("/requests", { limit: 10, status: "5xx" })

        assert_match(/limit=10/, captured_uri.query)
        assert_match(/status=5xx/, captured_uri.query)
      end

      test "get returns parsed JSON response" do
        body = '{"data":[{"id":1}],"meta":{"total":1,"limit":25,"offset":0}}'
        stub_http_response(200, body)
        result = @client.get("/routes")

        assert_equal [ { "id" => 1 } ], result["data"]
        assert_equal 1, result["meta"]["total"]
      end

      test "get raises ApiError on non-2xx response" do
        stub_http_response(401, '{"error":"Unauthorized"}')
        err = assert_raises(Client::ApiError) { @client.get("/routes") }
        assert_match(/401/, err.message)
      end

      test "get raises ApiError on 500 response" do
        stub_http_response(500, "Internal Server Error")
        assert_raises(Client::ApiError) { @client.get("/routes") }
      end

      test "get raises ProRequiredError with the feature and link on 402" do
        stub_http_response(402, { "error" => "requires_pro", "feature" => "alerts",
                                  "message" => "Alert history needs Rails Pulse Pro.", "url" => "https://railspulse.com/pro" }.to_json)
        err = assert_raises(Client::ProRequiredError) { @client.get("/alerts") }

        assert_kind_of Client::ApiError, err
        assert_equal "Alert history needs Rails Pulse Pro.", err.message
        assert_equal "alerts", err.feature
        assert_equal "https://railspulse.com/pro", err.url
      end

      test "get raises ProRequiredError with a default message when the 402 body is not JSON" do
        stub_http_response(402, "Payment Required")
        err = assert_raises(Client::ProRequiredError) { @client.get("/alerts") }

        assert_match(/Rails Pulse Pro/, err.message)
        assert_nil err.feature
      end

      test "get turns a refused connection into an ApiError naming the host" do
        stub_http_failure(Errno::ECONNREFUSED)
        err = assert_raises(Client::ApiError) { @client.get("/routes") }

        assert_match(/could not connect to example.com:443/, err.message)
      end
    end
  end
end
