require "test_helper"

# Behaviour of every dashboard page while the gem is newer than the tables it
# is connected to (deploy before migrate, or a rolling restart).
class RailsPulse::SchemaOutdatedTest < ActionDispatch::IntegrationTest
  def setup
    ENV["TEST_TYPE"] = "functional"
    super
    RailsPulse::SchemaCheck.reset!
  end

  def teardown
    RailsPulse::SchemaCheck.reset!
    super
  end

  test "dashboard renders normally when the schema is current" do
    get rails_pulse.root_path

    assert_response :success
  end

  test "dashboard renders the upgrade page with a 503 when the schema is outdated" do
    make_schema_outdated

    get rails_pulse.root_path

    assert_response :service_unavailable
    assert_match(/needs a schema upgrade/, response.body)
    assert_match(/rails generate rails_pulse:upgrade/, response.body)
    assert_match(/rails_pulse_routes/, response.body)
    assert_match(/not_a_real_column/, response.body)
  end

  test "every dashboard page is gated, not just the root" do
    make_schema_outdated

    get rails_pulse.routes_path

    assert_response :service_unavailable
    assert_match(/rails generate rails_pulse:upgrade/, response.body)
  end

  test "non-HTML requests get a JSON report" do
    make_schema_outdated

    get rails_pulse.root_path, as: :json

    assert_response :service_unavailable
    body = JSON.parse(response.body)

    assert_equal [ "not_a_real_column" ], body["missing"]["rails_pulse_routes"]
    assert_includes body["instructions"].first, "rails_pulse:upgrade"
  end

  private

  def make_schema_outdated
    RailsPulse::SchemaCheck.stubs(:expected_schema).returns(
      "rails_pulse_routes" => %w[http_methods not_a_real_column]
    )
  end
end
