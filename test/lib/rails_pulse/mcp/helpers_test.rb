require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class HelpersTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      class Host
        extend Tools::Helpers
      end

      test "resolve_since maps named periods to ISO timestamps" do
        now = Time.now
        hour = Time.iso8601(Host.resolve_since("last_hour"))
        day = Time.iso8601(Host.resolve_since("last_24_hours"))
        week = Time.iso8601(Host.resolve_since("last_7_days"))

        assert_in_delta now - 3600, hour, 5
        assert_in_delta now - 86_400, day, 5
        assert_in_delta now - 604_800, week, 5
      end

      test "resolve_since passes unknown values through as timestamps" do
        assert_equal "2026-06-01T00:00:00Z", Host.resolve_since("2026-06-01T00:00:00Z")
      end

      test "percentile returns 0 for empty input and nearest rank otherwise" do
        assert_equal 0, Host.percentile([], 95)
        assert_equal 10, Host.percentile([ 10 ], 95)
        assert_equal 60, Host.percentile((10..100).step(10).to_a, 50)
        assert_equal 100, Host.percentile((10..100).step(10).to_a, 99)
      end

      test "truncate shortens long strings only" do
        assert_equal "short", Host.truncate("short", 10)
        assert_equal "abcde...", Host.truncate("abcdefghij", 5)
        assert_equal "", Host.truncate(nil, 5)
      end

      test "respond wraps the payload as pretty JSON" do
        result = Host.respond({ client: :client }) { |client| { got: client.to_s } }

        assert_not result.error?
        assert_equal({ "got" => "client" }, JSON.parse(result.content.first[:text]))
      end

      test "respond turns API errors into error responses" do
        result = Host.respond({ client: nil }) { raise CLI::Client::ApiError, "503 Service Unavailable" }

        assert_predicate result, :error?
        assert_includes result.content.first[:text], "503 Service Unavailable"
      end

      test "respond answers a Pro-required 402 as data the agent can relay, not as an error" do
        error = CLI::Client::ProRequiredError.new("Alert history needs Rails Pulse Pro.", feature: "alerts", url: "https://railspulse.com/pro")
        result = Host.respond({ client: nil }) { raise error }

        assert_not result.error?
        data = JSON.parse(result.content.first[:text])

        assert data["requires_pro"]
        assert_equal "alerts", data["feature"]
        assert_equal "https://railspulse.com/pro", data["url"]
        assert_includes data["next_steps"].join, "rails_pulse_routes"
      end
    end
  end
end
