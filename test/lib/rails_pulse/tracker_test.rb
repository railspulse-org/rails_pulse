require "test_helper"

class RailsPulse::TrackerTest < ActiveSupport::TestCase
  def setup
    super
    RailsPulse::SchemaCheck.reset!
  end

  def teardown
    RailsPulse::SchemaCheck.reset!
    super
  end

  # Schema Gate Tests

  test "track_request persists a request when the schema is current" do
    assert_difference "RailsPulse::Request.count", 1 do
      RailsPulse::Tracker.track_request(tracking_data)
    end
  end

  test "track_request persists nothing while the schema is outdated" do
    RailsPulse::SchemaCheck.stubs(:expected_schema).returns("rails_pulse_routes" => [ "ghost" ])

    assert_no_difference [ "RailsPulse::Request.count", "RailsPulse::Route.count" ] do
      RailsPulse::Tracker.track_request(tracking_data)
    end
  end

  private

  def tracking_data
    {
      method: "GET",
      path: "/tracker-test",
      duration: 12.5,
      status: 200,
      is_error: false,
      request_uuid: SecureRandom.uuid,
      controller_action: "home#index",
      occurred_at: Time.current,
      response_size_bytes: 128,
      operations: []
    }
  end
end
