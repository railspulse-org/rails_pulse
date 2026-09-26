require "test_helper"

module RailsPulse
  class SummaryServiceTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes

    def setup
      RailsPulse::Summary.delete_all
      RailsPulse::Operation.delete_all
      RailsPulse::Request.delete_all
      # Job run and exception fixtures use relative timestamps (e.g. 30.minutes.ago)
      # that fall inside the current hour late in the hour, which would add rows
      # and statements the assertions below do not expect.
      RailsPulse::JobRun.delete_all
      RailsPulse::ExceptionOccurrence.delete_all
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

    # ============================================================================
    # Write Mechanics
    # ============================================================================

    test "re-running a period updates the existing rows instead of duplicating them" do
      create_request(duration: 100, status: 200)
      SummaryService.new("hour", @hour_start).perform
      create_request(duration: 300, status: 200)

      assert_no_difference -> { Summary.count } do
        SummaryService.new("hour", @hour_start).perform
      end

      route_summary = Summary.find_by!(summarizable_type: "RailsPulse::Route", summarizable_id: @route.id, period_start: @hour_start)

      assert_equal 2, route_summary.count
      assert_in_delta 200.0, route_summary.avg_duration
    end

    test "writes each summarizable kind with a single statement regardless of row count" do
      other_route = rails_pulse_routes(:api_posts)
      3.times { create_request(duration: 100, status: 200) }
      2.times { create_request(duration: 50, status: 200, route: other_route) }
      inserts = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        inserts += 1 if payload[:sql] =~ /\AINSERT INTO .rails_pulse_summaries./
      end

      SummaryService.new("hour", @hour_start).perform

      assert_equal 1, inserts, "overall and per-route rows should share one INSERT"
      assert_equal 3, Summary.count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # ============================================================================
    # Transaction Timing
    # ============================================================================

    test "row computation runs before the transaction opens, not inside it" do
      create_request(duration: 100, status: 200)
      # The test itself runs inside a transactional fixture, so the baseline
      # depth (not necessarily 0) is what "no transaction of ours is open yet"
      # looks like here.
      baseline = RailsPulse::ApplicationRecord.connection.open_transactions

      service = Class.new(SummaryService) do
        attr_reader :open_transactions_while_computing

        private

        def query_summary_rows
          @open_transactions_while_computing = RailsPulse::ApplicationRecord.connection.open_transactions
          super
        end
      end.new("hour", @hour_start)

      service.perform

      assert_equal baseline, service.open_transactions_while_computing
    end

    test "a write failure rolls back summaries already staged earlier in the same transaction" do
      create_request(duration: 100, status: 200)

      service = Class.new(SummaryService) do
        private

        def upsert_summaries(rows)
          @upsert_call_count = (@upsert_call_count || 0) + 1
          raise ActiveRecord::StatementInvalid, "boom" if @upsert_call_count == 2
          super
        end
      end.new("hour", @hour_start)

      assert_raises(ActiveRecord::StatementInvalid) { service.perform }

      assert_nil Summary.find_by(
        summarizable_type: "RailsPulse::Request", summarizable_id: 0,
        period_type: "hour", period_start: @hour_start
      )
    end

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
    private

    def create_request(duration:, status:, route: @route)
      RailsPulse::Request.create!(
        route: route, duration: duration, status: status,
        request_uuid: SecureRandom.uuid, occurred_at: @hour_start + 1.minute
      )
    end
  end
end
