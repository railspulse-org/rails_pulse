require "test_helper"

class DeploymentMarkersConcernTest < ActionController::TestCase
  class TestController < ActionController::Base
    include DeploymentMarkersConcern
  end

  fixtures :rails_pulse_deployments

  setup do
    ENV["TEST_TYPE"] = "functional"
    @controller = TestController.new
    @now = Time.current
    travel_to @now
  end

  teardown do
    travel_back
  end

  def set_window(start_time, end_time)
    @controller.instance_variable_set(:@time_range,
      RailsPulse::TimeRange::Result.new(window: RailsPulse::TimeWindow.new(start_time, end_time)))
  end

  # Structure Tests

  test "populate_deployment_markers sets @deployment_markers as array" do
    set_window(3.hours.ago, Time.current)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)

    assert_kind_of Array, markers
  end

  test "populate_deployment_markers returns markers within range" do
    set_window(3.hours.ago, Time.current)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)

    # v1_deploy (2.hours.ago) and v2_deploy (30.minutes.ago) are both in range
    assert_operator markers.length, :>=, 2
  end

  test "populate_deployment_markers excludes deployments outside range" do
    # Range that only includes v2_deploy (30 minutes ago), not v1_deploy (2 hours ago)
    set_window(45.minutes.ago, Time.current)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)
    revisions = markers.map { |m| m[:revision] }

    assert_includes revisions, "def5678"
    refute_includes revisions, "abc1234"
  end

  test "populate_deployment_markers returns empty array when no deployments in range" do
    set_window(5.hours.ago, 4.hours.ago)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)

    assert_empty markers
  end

  test "populate_deployment_markers does nothing when @time_range has no window" do
    @controller.instance_variable_set(:@time_range, nil)

    @controller.send(:populate_deployment_markers)

    refute @controller.instance_variable_defined?(:@deployment_markers)
  end

  # Marker Structure Tests

  test "each marker has timestamp, revision, and started_at keys" do
    set_window(3.hours.ago, Time.current)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)

    assert_not_empty markers
    markers.each do |marker|
      assert_includes marker.keys, :timestamp
      assert_includes marker.keys, :revision
      assert_includes marker.keys, :started_at
    end
  end

  test "marker timestamps are in milliseconds" do
    set_window(3.hours.ago, Time.current)

    @controller.send(:populate_deployment_markers)
    markers = @controller.instance_variable_get(:@deployment_markers)

    assert_not_empty markers
    markers.each do |marker|
      assert_operator marker[:timestamp], :>, 1_000_000_000_000
    end
  end
end
