require "test_helper"

module RailsPulse
  module Api
    module V1
      class RequestSerializerTest < ActiveSupport::TestCase
        test "serializes all expected fields" do
          request = rails_pulse_requests(:users_request_1)
          result = RequestSerializer.serialize(request)

          assert_equal request.id,                  result[:id]
          assert_equal request.route_id,            result[:route_id]
          assert_equal request.occurred_at,         result[:occurred_at]
          assert_equal request.duration,            result[:duration]
          assert_equal request.status,              result[:status]
          assert_equal request.is_error,            result[:is_error]
          assert_equal request.request_uuid,        result[:request_uuid]
          assert_equal request.controller_action,   result[:controller_action]
          assert_equal request.response_size_bytes, result[:response_size_bytes]
        end

        test "returns a hash with exactly the expected keys" do
          result = RequestSerializer.serialize(rails_pulse_requests(:users_request_1))

          assert_equal %i[id route_id occurred_at duration status is_error request_uuid controller_action response_size_bytes], result.keys
        end

        test "reflects is_error true for error requests" do
          result = RequestSerializer.serialize(rails_pulse_requests(:error_request))

          assert result[:is_error]
          assert_equal 500, result[:status]
        end
      end
    end
  end
end
