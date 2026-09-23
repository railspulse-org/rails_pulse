require "test_helper"

module RailsPulse
  module Dashboard
    class StoragePressureTest < ActiveSupport::TestCase
      fixtures :rails_pulse_events

      fixtures :rails_pulse_routes

      def setup
        RailsPulse::Summary.delete_all
        RailsPulse::Operation.delete_all
        RailsPulse::Request.delete_all
        @original_retention  = RailsPulse.configuration.full_retention_period
        @original_archiving  = RailsPulse.configuration.archiving_enabled
        @now = Time.current
        travel_to @now
      end

      def teardown
        RailsPulse.configuration.full_retention_period = @original_retention
        RailsPulse.configuration.archiving_enabled     = @original_archiving
        travel_back
      end

      # Structure Tests

      # Writer Drop Tests

      test "pressure items flag requests dropped by the writer in the last hour" do
        rails_pulse_events(:web_two_latest).update!(value: 7)
        item = StoragePressure.new.pressure_items.find { |i| i[:type] == "TRACKING" }

        assert item, "expected a TRACKING pressure item"
        assert_equal :critical, item[:severity]
        assert_includes item[:reason], "7 requests dropped in the last hour"
        assert_includes item[:popover_body], "async_queue_size"
      end

      test "no pressure item when nothing was dropped" do
        assert_nil StoragePressure.new.pressure_items.find { |i| i[:type] == "TRACKING" }
      end

      test "storage_counts ignore tracking items so the Storage badge stays about storage" do
        pressure = StoragePressure.new
        pressure.stubs(:pressure_items).returns([ { type: "TRACKING", severity: :critical } ])

        assert_equal({ healthy: 1, slow: 0, critical: 0 }, pressure.storage_counts)
      end

      test "pressure_items returns an array" do
        create_fresh_summary

        result = StoragePressure.new.pressure_items

        assert_kind_of Array, result
      end

      test "storage_counts returns hash with healthy, slow, critical keys" do
        create_fresh_summary

        result = StoragePressure.new.storage_counts

        assert_kind_of Hash, result
        assert_includes result.keys, :healthy
        assert_includes result.keys, :slow
        assert_includes result.keys, :critical
      end

      test "storage_counts values are 0 or 1" do
        create_fresh_summary

        result = StoragePressure.new.storage_counts

        result.each_value do |v|
          assert_includes [ 0, 1 ], v
        end
      end

      test "exactly one of healthy slow critical is 1" do
        create_fresh_summary

        result = StoragePressure.new.storage_counts

        assert_equal 1, result.values.sum
      end

      # Signal A — Summary Staleness

      test "returns no staleness item when summary is fresh" do
        create_overall_hourly_summary(period_end: 30.minutes.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Summary job" }

        assert_empty items
      end

      test "returns warning item when summary is 3 hours stale" do
        create_overall_hourly_summary(period_end: 3.hours.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Summary job" }

        assert_equal 1, items.size
        assert_equal :warning, items.first[:severity]
        assert_equal "STORAGE", items.first[:type]
      end

      test "returns critical item when summary is 25 hours stale" do
        create_overall_hourly_summary(period_end: 25.hours.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Summary job" }

        assert_equal 1, items.size
        assert_equal :critical, items.first[:severity]
      end

      test "returns critical item when summary job has never run" do
        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Summary job" }

        assert_equal 1, items.size
        assert_equal :critical, items.first[:severity]
        assert_includes items.first[:reason], "never"
      end

      test "staleness item metric includes stale hours when stale" do
        create_overall_hourly_summary(period_end: 3.hours.ago)

        item = StoragePressure.new.pressure_items.find { |i| i[:name] == "Summary job" }

        assert_includes item[:metric], "stale"
        assert_includes item[:metric_sub], "Last run:"
      end

      test "returns no staleness item after SummaryService runs with zero requests" do
        RailsPulse::SummaryService.new("hour", 1.hour.ago.beginning_of_hour).perform

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Summary job" }

        assert_empty items
      end

      # Signal B — Stuck Records

      test "returns no stuck-records item when no requests exist past retention" do
        RailsPulse.configuration.full_retention_period = 30.days
        create_overall_hourly_summary(period_end: 30.minutes.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Storage pressure" }

        assert_empty items
      end

      test "returns critical stuck-records item when requests are past retention and before oldest summary" do
        RailsPulse.configuration.full_retention_period = 30.days
        # Summary only covers recent time — oldest summary start is recent
        create_overall_hourly_summary(period_end: 30.minutes.ago)
        # Request older than 30-day retention AND before the oldest summary's period_start
        create_request(occurred_at: 45.days.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Storage pressure" }

        assert_equal 1, items.size
        assert_equal :critical, items.first[:severity]
      end

      test "stuck-records metric shows count of stuck requests" do
        RailsPulse.configuration.full_retention_period = 30.days
        create_overall_hourly_summary(period_end: 30.minutes.ago)
        create_request(occurred_at: 45.days.ago)
        create_request(occurred_at: 50.days.ago)

        item = StoragePressure.new.pressure_items.find { |i| i[:name] == "Storage pressure" }

        assert_includes item[:metric], "2"
      end

      test "returns no stuck-records item when archiving is disabled" do
        RailsPulse.configuration.archiving_enabled = false
        RailsPulse.configuration.full_retention_period = 30.days
        create_overall_hourly_summary(period_end: 30.minutes.ago)
        create_request(occurred_at: 45.days.ago)

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Storage pressure" }

        assert_empty items
      end

      test "returns no stuck-records item when no summaries exist" do
        RailsPulse.configuration.full_retention_period = 30.days
        create_request(occurred_at: 45.days.ago)

        # Without any summaries, oldest_summary_start is nil — no stuck detection
        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Storage pressure" }

        assert_empty items
      end

      # Signal C — Sub-hour Retention

      test "returns warning when full_retention_period is 30 minutes" do
        RailsPulse.configuration.instance_variable_set(:@full_retention_period, 30.minutes)
        create_fresh_summary

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Retention period misconfigured" }

        assert_equal 1, items.size
        assert_equal :warning, items.first[:severity]
        assert_includes items.first[:reason], "30m"
      end

      test "returns no misconfiguration warning when full_retention_period is 2 hours" do
        RailsPulse.configuration.full_retention_period = 2.hours
        create_fresh_summary

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Retention period misconfigured" }

        assert_empty items
      end

      test "returns no misconfiguration warning when full_retention_period is exactly 1 hour" do
        RailsPulse.configuration.instance_variable_set(:@full_retention_period, 1.hour)
        create_fresh_summary

        items = StoragePressure.new.pressure_items.select { |i| i[:name] == "Retention period misconfigured" }

        assert_empty items
      end

      # storage_counts

      test "storage_counts is healthy when summary is fresh and no other pressure" do
        create_fresh_summary

        counts = StoragePressure.new.storage_counts

        assert_equal 1, counts[:healthy]
        assert_equal 0, counts[:slow]
        assert_equal 0, counts[:critical]
      end

      test "storage_counts is slow when summary is 3 hours stale" do
        create_overall_hourly_summary(period_end: 3.hours.ago)

        counts = StoragePressure.new.storage_counts

        assert_equal 0, counts[:healthy]
        assert_equal 1, counts[:slow]
        assert_equal 0, counts[:critical]
      end

      test "storage_counts is critical when summary job has never run" do
        counts = StoragePressure.new.storage_counts

        assert_equal 0, counts[:healthy]
        assert_equal 0, counts[:slow]
        assert_equal 1, counts[:critical]
      end

      test "storage_counts is critical when stuck records exist" do
        RailsPulse.configuration.full_retention_period = 30.days
        create_overall_hourly_summary(period_end: 30.minutes.ago)
        create_request(occurred_at: 45.days.ago)

        counts = StoragePressure.new.storage_counts

        assert_equal 1, counts[:critical]
      end

      # Edge Cases

      test "pressure_items is empty when everything is healthy" do
        create_fresh_summary

        items = StoragePressure.new.pressure_items

        assert_empty items
      end

      test "each pressure item has required keys" do
        # Force a staleness item by not creating any summaries
        items = StoragePressure.new.pressure_items

        items.each do |item|
          assert_includes item.keys, :type
          assert_includes item.keys, :name
          assert_includes item.keys, :reason
          assert_includes item.keys, :metric
          assert_includes item.keys, :metric_sub
          assert_includes item.keys, :link
          assert_includes item.keys, :severity
          assert_includes item.keys, :sort_score
        end
      end

      private

      def create_overall_hourly_summary(period_end:)
        period_start = period_end.beginning_of_hour
        RailsPulse::Summary.create!(
          summarizable_type: "RailsPulse::Request",
          summarizable_id:   0,
          period_type:       "hour",
          period_start:      period_start,
          period_end:        period_end,
          count:             1,
          avg_duration:      100.0
        )
      end

      def create_fresh_summary
        create_overall_hourly_summary(period_end: 30.minutes.ago)
      end

      def create_request(occurred_at:)
        route = rails_pulse_routes(:api_users)
        RailsPulse::Request.create!(
          route:        route,
          duration:     100.0,
          status:       200,
          is_error:     false,
          request_uuid: SecureRandom.uuid,
          occurred_at:  occurred_at
        )
      end
    end
  end
end
