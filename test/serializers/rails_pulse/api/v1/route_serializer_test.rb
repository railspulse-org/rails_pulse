require "test_helper"

module RailsPulse
  module Api
    module V1
      class RouteSerializerTest < ActiveSupport::TestCase
        test "serializes all expected fields" do
          route = rails_pulse_routes(:api_users)
          result = RouteSerializer.serialize(route)

          assert_equal route.id,                result[:id]
          assert_equal route.http_methods_list, result[:http_methods]
          assert_equal route.path,              result[:path]
          assert_equal route.created_at,        result[:created_at]
          assert_equal "api/users#index",       result[:controller_action]
          assert_equal %w[api users],           result[:tags]
          assert_nil result[:stats]
        end

        test "returns a hash with exactly the expected keys" do
          result = RouteSerializer.serialize(rails_pulse_routes(:api_users))

          assert_equal %i[id http_methods path controller_action tags created_at stats], result.keys
        end

        test "passes stats through when given" do
          stats = { request_count: 5, avg_duration_ms: 12.5, error_count: 1 }
          result = RouteSerializer.serialize(rails_pulse_routes(:api_users), stats: stats)

          assert_equal stats, result[:stats]
        end
      end
    end
  end
end
