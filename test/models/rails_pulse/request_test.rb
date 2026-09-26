require "test_helper"

class RailsPulse::RequestTest < ActiveSupport::TestCase
  include Shoulda::Matchers::ActiveModel
  include Shoulda::Matchers::ActiveRecord

  # Test associations
  test "should have correct associations" do
    assert belong_to(:route).matches?(RailsPulse::Request.new)
    assert have_many(:operations).dependent(:destroy).matches?(RailsPulse::Request.new)
  end

  # Test validations
  test "should have correct validations" do
    request = RailsPulse::Request.new

    # Presence validations
    assert validate_presence_of(:route_id).matches?(request)
    assert validate_presence_of(:occurred_at).matches?(request)
    assert validate_presence_of(:duration).matches?(request)
    assert validate_presence_of(:status).matches?(request)
    # Numericality validation
    assert validate_numericality_of(:duration).is_greater_than_or_equal_to(0).matches?(request)
  end

  test "should be valid with required attributes" do
    request = rails_pulse_requests(:users_request_1)

    assert_predicate request, :valid?
  end

  test "should generate request_uuid when blank" do
    route = rails_pulse_routes(:api_users)
    request = RailsPulse::Request.create!(
      route: route,
      duration: 150.5,
      status: 200,
      controller_action: "UsersController#index",
      occurred_at: 1.hour.ago
      # request_uuid intentionally omitted - should be auto-generated
    )

    # Test indirectly - UUID should be generated on save via callback
    assert_not_nil request.request_uuid
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, request.request_uuid)
  end

  # Association tests are covered by shoulda matchers above

  test "should return formatted string representation" do
    request = rails_pulse_requests(:users_request_1)

    # to_s formats in Time.zone (the aggregation zone), not the server's OS zone
    expected_format = request.occurred_at.strftime("%b %d, %Y %l:%M %p")

    assert_equal expected_format, request.to_s
  end

  test "should include ransackable attributes" do
    expected_attributes = %w[id route_id occurred_at duration status status_category status_indicator route_path http_method controller_action response_size_bytes]

    assert_equal expected_attributes.sort, RailsPulse::Request.ransackable_attributes.sort
  end

  test "ransackable attributes should include response_size_bytes for sorting and filtering" do
    assert_includes RailsPulse::Request.ransackable_attributes, "response_size_bytes"
  end

  test "should include ransackable associations" do
    expected_associations = %w[route]

    assert_equal expected_associations.sort, RailsPulse::Request.ransackable_associations.sort
  end

  # Dependent destroy behavior is tested by shoulda matcher above

  test "operations association should return correct operations" do
    request1 = rails_pulse_requests(:users_request_1)
    request2 = rails_pulse_requests(:posts_request)

    # Get operations from fixtures
    operation1 = rails_pulse_operations(:sql_operation_1)
    operation2 = rails_pulse_operations(:controller_operation_1)

    # Test that each request returns only its own operations
    assert_operator request1.operations.count, :>, 0
    assert_includes request1.operations, operation1
    assert_includes request1.operations, operation2

    # request2 should not have the same operations as request1
    request1.operations.each do |op|
      assert_not_includes request2.operations, op
    end
  end

  test "should include Taggable concern" do
    assert_includes RailsPulse::Request.included_modules, RailsPulse::Taggable
  end

  test "should include Taggable methods" do
    assert_respond_to RailsPulse::Request.new, :tag_list
  end

  test "ransacker methods should be available" do
    # Test that ransacker class method exists
    assert_respond_to RailsPulse::Request, :ransacker
  end

  test "should handle edge case durations for status_indicator" do
    # Test with existing fixture data that has various durations
    request1 = rails_pulse_requests(:users_request_1)  # 150.5ms
    request2 = rails_pulse_requests(:users_request_2)  # 250.0ms
    request3 = rails_pulse_requests(:posts_request)     # 180.0ms

    # All should be valid
    assert_predicate request1, :valid?
    assert_predicate request2, :valid?
    assert_predicate request3, :valid?
  end

  test "request_uuid should be auto-generated if not provided" do
    route = rails_pulse_routes(:api_users)
    request = RailsPulse::Request.create!(
      route: route,
      duration: 150.5,
      status: 200,
      controller_action: "UsersController#index",
      occurred_at: 1.hour.ago
      # request_uuid intentionally omitted
    )

    # Test indirectly through public API - callback runs on create
    assert_not_nil request.request_uuid
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, request.request_uuid)
  end

  test "should not overwrite provided request_uuid" do
    # Test with existing fixture that has a pre-set UUID
    request = rails_pulse_requests(:users_request_1)

    assert_equal "test-uuid-1", request.request_uuid
  end

  test "should handle various HTTP status codes" do
    # Test with existing fixture data with different status codes
    success_request = rails_pulse_requests(:users_request_1)   # status: 200
    created_request = rails_pulse_requests(:posts_request)     # status: 201
    error_request = rails_pulse_requests(:error_request)       # status: 500

    assert_predicate success_request, :valid?
    assert_equal 200, success_request.status
    refute success_request.is_error

    assert_predicate created_request, :valid?
    assert_equal 201, created_request.status
    refute created_request.is_error

    assert_predicate error_request, :valid?
    assert_equal 500, error_request.status
    assert error_request.is_error
  end
end
