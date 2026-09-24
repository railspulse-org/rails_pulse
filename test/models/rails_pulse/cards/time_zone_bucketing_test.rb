require "test_helper"

# Sparkline buckets must follow Time.zone, not the UTC value stored in the
# database. A zone east of UTC puts local midnight on the previous UTC date,
# and a half-hour zone puts local hour starts thirty minutes off any UTC
# hour, so grouping with SQL DATE()/DATE_TRUNC() shifts or empties every
# card sparkline for those users.
module RailsPulse
  module Cards
    class TimeZoneBucketingTest < ActiveSupport::TestCase
      fixtures :rails_pulse_routes

      def setup
        @original_zone = Time.zone
        @route = rails_pulse_routes(:api_users)
        RailsPulse::Summary.delete_all
      end

      def teardown
        Time.zone = @original_zone
      end

      # Daily buckets

      %w[UTC America/Los_Angeles Europe/London Australia/Melbourne Asia/Tokyo].each do |zone|
        test "daily sparkline lines up with local dates in #{zone}" do
          Time.zone = zone
          first_day = Time.zone.parse("2026-09-10 00:00:00")
          seed_daily_route_summaries(first_day, counts: [ 100, 101, 102, 103, 104, 105, 106 ])

          card = RailsPulse::Routes::Cards::RequestCountTotals.new(
            period: 7, period_type: "day",
            window: RailsPulse::TimeWindow.new(first_day.to_i, (first_day + 6.days).end_of_day.to_i)
          ).to_metric_card

          assert_equal [ 100, 101, 102, 103, 104, 105, 106 ], card[:chart_data].values.map { |point| point[:value] }
        end
      end

      # Hourly buckets

      test "hourly sparkline lines up with local hour starts in a half-hour zone" do
        Time.zone = "Asia/Kolkata"
        first_hour = Time.zone.parse("2026-09-10 10:00:00")
        6.times do |i|
          hour = first_hour + i.hours
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Route", summarizable_id: @route.id, period_type: "hour",
            period_start: hour, period_end: hour.end_of_hour, count: 10 + i, avg_duration: 50
          )
        end

        card = RailsPulse::Routes::Cards::RequestCountTotals.new(
          period: 1, period_type: "hour",
          window: RailsPulse::TimeWindow.new(first_hour.to_i, (first_hour + 5.hours).end_of_hour.to_i)
        ).to_metric_card

        assert_equal [ 10, 11, 12, 13, 14, 15 ], card[:chart_data].values.map { |point| point[:value] }
      end

      # Edge Cases

      test "summaries that fall on the same local date are summed" do
        Time.zone = "Australia/Melbourne"
        day = Time.zone.parse("2026-09-10 00:00:00")
        other_route = rails_pulse_routes(:api_posts)
        [ @route, other_route ].each do |route|
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Route", summarizable_id: route.id, period_type: "day",
            period_start: day, period_end: day.end_of_day, count: 5, avg_duration: 50
          )
        end

        card = RailsPulse::Routes::Cards::RequestCountTotals.new(
          period: 1, period_type: "day", window: RailsPulse::TimeWindow.new(day.to_i, day.end_of_day.to_i)
        ).to_metric_card

        assert_equal [ 10 ], card[:chart_data].values.map { |point| point[:value] }
      end

      private

      def seed_daily_route_summaries(first_day, counts:)
        counts.each_with_index do |count, i|
          day = first_day + i.days
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Route", summarizable_id: @route.id, period_type: "day",
            period_start: day, period_end: day.end_of_day, count: count, avg_duration: 50,
            p50_duration: 40, p95_duration: 80, p99_duration: 120, error_count: 1, success_count: count - 1
          )
        end
      end
    end
  end
end
