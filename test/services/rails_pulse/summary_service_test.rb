require "test_helper"

module RailsPulse
  class SummaryServiceTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes

    def setup
      RailsPulse::Summary.delete_all
      RailsPulse::Operation.delete_all
      RailsPulse::Request.delete_all
      @route = rails_pulse_routes(:api_users)
      @hour_start = Time.current.beginning_of_hour
    end

    # ============================================================================
    # Error Count Tests
    # ============================================================================

    test "error_count only counts 5xx responses, not 4xx" do
      travel_to @hour_start + 1.minute do
        RailsPulse::Request.create!(
          route: @route, duration: 50.0, status: 422,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Request.create!(
          route: @route, duration: 60.0, status: 404,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Request.create!(
          route: @route, duration: 70.0, status: 200,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
      end

      SummaryService.new("hour", @hour_start).perform

      summary = Summary.find_by!(
        summarizable_type: "RailsPulse::Request",
        summarizable_id: 0,
        period_type: "hour",
        period_start: @hour_start
      )

      assert_equal 0, summary.error_count
      assert_equal 3, summary.count
      assert_equal 0, summary.status_5xx
      assert_equal 2, summary.status_4xx
      assert_equal 1, summary.status_2xx
      assert_equal 3, summary.success_count
    end

    test "error_count counts 5xx responses" do
      travel_to @hour_start + 1.minute do
        RailsPulse::Request.create!(
          route: @route, duration: 50.0, status: 500,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Request.create!(
          route: @route, duration: 60.0, status: 503,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Request.create!(
          route: @route, duration: 70.0, status: 200,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
      end

      SummaryService.new("hour", @hour_start).perform

      summary = Summary.find_by!(
        summarizable_type: "RailsPulse::Request",
        summarizable_id: 0,
        period_type: "hour",
        period_start: @hour_start
      )

      assert_equal 2, summary.error_count
      assert_equal 3, summary.count
      assert_equal 2, summary.status_5xx
      assert_equal 0, summary.status_4xx
      assert_equal 1, summary.status_2xx
      assert_equal 1, summary.success_count
    end

    test "error_count in route summaries only counts 5xx" do
      travel_to @hour_start + 1.minute do
        RailsPulse::Request.create!(
          route: @route, duration: 50.0, status: 422,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Request.create!(
          route: @route, duration: 60.0, status: 500,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
      end

      SummaryService.new("hour", @hour_start).perform

      summary = Summary.find_by!(
        summarizable_type: "RailsPulse::Route",
        summarizable_id: @route.id,
        period_type: "hour",
        period_start: @hour_start
      )

      assert_equal 1, summary.error_count
      assert_equal 1, summary.status_5xx
      assert_equal 1, summary.status_4xx
    end

    # ============================================================================
    # Empty Period Tests
    # ============================================================================

    test "aggregate_requests writes an overall summary with count 0 when there are no requests" do
      SummaryService.new("hour", @hour_start).perform

      summary = Summary.find_by!(
        summarizable_type: "RailsPulse::Request",
        summarizable_id: 0,
        period_type: "hour",
        period_start: @hour_start
      )

      assert_equal 0, summary.count
      assert_equal 0, summary.avg_duration
      assert_nil summary.min_duration
      assert_nil summary.max_duration
      assert_nil summary.p50_duration
      assert_nil summary.p95_duration
      assert_nil summary.p99_duration
      assert_nil summary.stddev_duration
    end
  end
end
