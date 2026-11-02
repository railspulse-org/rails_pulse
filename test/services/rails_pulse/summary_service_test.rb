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
      # The service only summarizes finished periods, so use the last full hour.
      @hour_start = 1.hour.ago.beginning_of_hour
    end

    # ============================================================================
    # Rollup Merge Tests (detail capture, decision 0022)
    # ============================================================================

    test "an hour with no rollups summarizes exactly as before" do
      travel_to @hour_start + 1.minute do
        [ 10.0, 20.0, 30.0, 40.0 ].each do |duration|
          RailsPulse::Request.create!(
            route: @route, duration: duration, status: 200,
            request_uuid: SecureRandom.uuid, occurred_at: Time.current
          )
        end
      end

      SummaryService.new("hour", @hour_start).perform

      summary = overall_summary

      assert_equal 4, summary.count
      assert_in_delta 25.0, summary.avg_duration, 1e-6
      assert_in_delta Statistics.calculate_percentile([ 10.0, 20.0, 30.0, 40.0 ], 0.9), summary.p90_duration, 1e-6
      assert_in_delta Statistics.calculate_percentile([ 10.0, 20.0, 30.0, 40.0 ], 0.95), summary.p95_duration, 1e-6
      # 0.001: MySQL stores summary metrics in single-precision float columns
      assert_in_delta Statistics.calculate_stddev([ 10.0, 20.0, 30.0, 40.0 ], 25.0), summary.stddev_duration, 0.001
    end

    test "route counts, sums and status counts merge raw rows with rollups exactly" do
      raw = [ 100.0, 300.0 ]
      folded = [ 10.0, 20.0, 30.0 ]
      travel_to @hour_start + 1.minute do
        raw.each do |duration|
          RailsPulse::Request.create!(
            route: @route, duration: duration, status: 200,
            request_uuid: SecureRandom.uuid, occurred_at: Time.current
          )
        end
      end
      write_route_rollup(folded, statuses: [ 200, 200, 503 ])

      SummaryService.new("hour", @hour_start).perform

      all = raw + folded
      summary = route_summary

      assert_equal 5, summary.count
      assert_in_delta all.sum, summary.total_duration, 1e-6
      assert_in_delta all.sum / 5, summary.avg_duration, 1e-6
      assert_in_delta 10.0, summary.min_duration, 1e-6
      assert_in_delta 300.0, summary.max_duration, 1e-6
      assert_equal 1, summary.error_count
      assert_equal 4, summary.success_count
      assert_equal 4, summary.status_2xx
      assert_equal 1, summary.status_5xx
      # 0.001: MySQL stores summary metrics in single-precision float columns
      assert_in_delta Statistics.calculate_stddev(all, all.sum / 5), summary.stddev_duration, 0.001
    end

    test "merged percentiles stay within the histogram tolerance and are exact in the kept tail" do
      folded = Array.new(95) { |i| 10.0 + i }           # fast traffic, rolled up
      raw = [ 1_000.0, 2_000.0, 3_000.0, 4_000.0, 5_000.0 ] # the kept slow tail
      travel_to @hour_start + 1.minute do
        raw.each do |duration|
          RailsPulse::Request.create!(
            route: @route, duration: duration, status: 200,
            request_uuid: SecureRandom.uuid, occurred_at: Time.current
          )
        end
      end
      write_route_rollup(folded)

      SummaryService.new("hour", @hour_start).perform

      all = (raw + folded).sort
      summary = route_summary
      # p99 of 100 values lands among the exactly-kept slow requests
      assert_in_delta Statistics.calculate_percentile(all, 0.99), summary.p99_duration, 1e-6
      # p50 and p90 land in the folded traffic: approximate within the bucket width
      bucket_width = Math.sqrt(DurationHistogram::GROWTH) - 1
      { p50_duration: 0.5, p90_duration: 0.9 }.each do |column, quantile|
        exact = Statistics.calculate_percentile(all, quantile)

        assert_in_delta exact, summary.public_send(column), exact * bucket_width, column
      end
    end

    test "a route whose every request was folded still gets a summary row" do
      write_route_rollup([ 15.0, 25.0 ])

      SummaryService.new("hour", @hour_start).perform

      summary = route_summary

      assert_equal 2, summary.count
      assert_in_delta 20.0, summary.avg_duration, 1e-6
    end

    test "the overall row folds every route's rollups together with raw rows" do
      other_route = rails_pulse_routes(:api_posts)
      travel_to @hour_start + 1.minute do
        RailsPulse::Request.create!(
          route: other_route, duration: 100.0, status: 200,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
      end
      write_route_rollup([ 10.0 ])
      write_route_rollup([ 20.0 ], route_id: other_route.id, writer_id: "host:2:def")

      SummaryService.new("hour", @hour_start).perform

      summary = overall_summary

      assert_equal 3, summary.count
      assert_in_delta 130.0, summary.total_duration, 1e-6
    end

    test "rollup rows from several writers are summed" do
      write_route_rollup([ 10.0 ], writer_id: "host:1:abc")
      write_route_rollup([ 20.0, 30.0 ], writer_id: "host:2:def")

      SummaryService.new("hour", @hour_start).perform

      assert_equal 3, route_summary.count
    end

    test "query summaries merge raw operations with query rollups" do
      query = RailsPulse::Query.create!(normalized_sql: "SELECT * FROM widgets WHERE id = ?")
      travel_to @hour_start + 1.minute do
        request = RailsPulse::Request.create!(
          route: @route, duration: 50.0, status: 200,
          request_uuid: SecureRandom.uuid, occurred_at: Time.current
        )
        RailsPulse::Operation.create!(
          request: request, query: query, operation_type: "sql",
          label: "SELECT * FROM widgets WHERE id = ?", duration: 40.0,
          start_time: 0.0, occurred_at: Time.current
        )
      end
      write_query_rollup(query.id, [ 2.0, 4.0 ])

      SummaryService.new("hour", @hour_start).perform

      summary = Summary.find_by!(
        summarizable_type: "RailsPulse::Query", summarizable_id: query.id,
        period_type: "hour", period_start: @hour_start
      )

      assert_equal 3, summary.count
      assert_in_delta 46.0, summary.total_duration, 1e-6
      assert_in_delta 2.0, summary.min_duration, 1e-6
      assert_in_delta 40.0, summary.max_duration, 1e-6
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

        def summary_rows
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
    # ============================================================================
    # In-Progress Periods
    # ============================================================================

    test "a period that has not ended is not summarized" do
      RailsPulse::Request.create!(
        route: @route, duration: 50.0, status: 200,
        request_uuid: SecureRandom.uuid, occurred_at: Time.current
      )

      SummaryService.new("hour", Time.current).perform
      SummaryService.new("day", Time.current).perform

      assert_equal 0, Summary.count
    end

    private

    def create_request(duration:, status:, route: @route)
      RailsPulse::Request.create!(
        route: route, duration: duration, status: status,
        request_uuid: SecureRandom.uuid, occurred_at: @hour_start + 1.minute
      )
    end

    # A rollup row shaped exactly as RollupAccumulator writes it.
    def write_rollup(type, id, durations, statuses: nil, writer_id: "host:1:abc")
      histogram = DurationHistogram.new
      durations.each { |d| histogram.record(d) }
      statuses ||= []
      Rollup.upsert_rows([ {
        rollupable_type: type,
        rollupable_id: id,
        period_start: @hour_start,
        writer_id: writer_id,
        count: durations.size,
        error_count: statuses.count { |s| s >= 500 },
        status_2xx: statuses.count { |s| s.between?(200, 299) },
        status_3xx: statuses.count { |s| s.between?(300, 399) },
        status_4xx: statuses.count { |s| s.between?(400, 499) },
        status_5xx: statuses.count { |s| s.between?(500, 599) },
        sum_duration: durations.sum,
        sum_square_duration: durations.sum { |d| d * d },
        min_duration: durations.min,
        max_duration: durations.max,
        histogram: histogram.dump,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end

    def write_route_rollup(durations, statuses: nil, route_id: @route.id, writer_id: "host:1:abc")
      statuses ||= [ 200 ] * durations.size
      write_rollup("RailsPulse::Route", route_id, durations, statuses: statuses, writer_id: writer_id)
    end

    def write_query_rollup(query_id, durations, writer_id: "host:1:abc")
      write_rollup("RailsPulse::Query", query_id, durations, writer_id: writer_id)
    end

    def overall_summary
      Summary.find_by!(
        summarizable_type: "RailsPulse::Request", summarizable_id: 0,
        period_type: "hour", period_start: @hour_start
      )
    end

    def route_summary(route_id = @route.id)
      Summary.find_by!(
        summarizable_type: "RailsPulse::Route", summarizable_id: route_id,
        period_type: "hour", period_start: @hour_start
      )
    end
  end
end
