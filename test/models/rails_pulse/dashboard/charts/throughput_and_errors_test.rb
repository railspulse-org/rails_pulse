require "test_helper"

module RailsPulse
  module Dashboard
    module Charts
      class ThroughputAndErrorsTest < ActiveSupport::TestCase
        fixtures :rails_pulse_routes, :rails_pulse_summaries

        def setup
          RailsPulse::Summary.delete_all
          @now = Time.current
          travel_to @now
        end

        def teardown
          travel_back
        end

        # Structure Tests

        test "returns nil when no summaries exist" do
          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new.to_chart_data

          assert_nil result
        end

        test "returns hash with labels and series keys" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new.to_chart_data

          assert_kind_of Hash, result
          assert_includes result.keys, :labels
          assert_includes result.keys, :series
        end

        test "returns two series" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new.to_chart_data

          assert_equal 2, result[:series].length
        end

        test "first series is named Requests with bar type" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new.to_chart_data
          requests_series = result[:series][0]

          assert_equal "Requests", requests_series[:name]
          assert_equal "bar", requests_series[:type]
        end

        test "second series is named Errors with bar type" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new.to_chart_data
          errors_series = result[:series][1]

          assert_equal "Errors", errors_series[:name]
          assert_equal "bar", errors_series[:type]
        end

        test "labels count matches period days plus today" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data

          assert_equal 8, result[:labels].length
        end

        # Calculation Tests

        test "returns correct request count for a day" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 200, error_count: 10)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 200, result[:series][0][:data][yesterday_index]
        end

        test "returns correct error count for a day" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 200, error_count: 10)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 10, result[:series][1][:data][yesterday_index]
        end

        test "fills zero for days with no data" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          five_days_ago_index = result[:labels].index(5.days.ago.to_date.strftime("%b %-d"))

          assert_equal 0, result[:series][0][:data][five_days_ago_index]
          assert_equal 0, result[:series][1][:data][five_days_ago_index]
        end

        # Multi-day Aggregation Tests

        test "aggregates request counts across multiple routes on the same day" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_posts), 1.day.ago, count: 50, error_count: 3)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 150, result[:series][0][:data][yesterday_index]
        end

        test "aggregates error counts across multiple routes on the same day" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_posts), 1.day.ago, count: 50, error_count: 3)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 8, result[:series][1][:data][yesterday_index]
        end

        test "tracks data across multiple days independently" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_users), 3.days.ago, count: 200, error_count: 20)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))
          three_days_ago_index = result[:labels].index(3.days.ago.to_date.strftime("%b %-d"))

          assert_equal 100, result[:series][0][:data][yesterday_index]
          assert_equal 200, result[:series][0][:data][three_days_ago_index]
        end

        test "excludes data outside the period" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_users), 10.days.ago, count: 999, error_count: 99)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data

          assert_equal 8, result[:labels].length
          total_requests = result[:series][0][:data].sum

          assert_equal 100, total_requests
        end

        # Tag Filtering Tests

        test "excludes summaries for routes with disabled tags" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_cleanup), 1.day.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(
            period: 7,
            disabled_tags: [ "maintenance" ]
          ).to_chart_data

          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 100, result[:series][0][:data][yesterday_index]
        end

        test "excludes non-tagged routes when show_non_tagged is false" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 5)
          create_route_day_summary(rails_pulse_routes(:api_other), 1.day.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(
            period: 7,
            show_non_tagged: false
          ).to_chart_data

          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 100, result[:series][0][:data][yesterday_index]
        end

        test "returns nil when all summaries filtered out by tags" do
          create_route_day_summary(rails_pulse_routes(:api_cleanup), 1.day.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(
            period: 7,
            disabled_tags: [ "maintenance" ]
          ).to_chart_data

          assert_nil result
        end

        # Edge Cases

        test "handles zero error count" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 0)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 0, result[:series][1][:data][yesterday_index]
        end

        test "includes 4xx errors in the Errors series" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 200, error_count: 5, status_4xx: 3)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 8, result[:series][1][:data][yesterday_index]  # 5xx (5) + 4xx (3) = 8
        end

        test "shows zero errors when both error_count and status_4xx are zero" do
          create_route_day_summary(rails_pulse_routes(:api_users), 1.day.ago, count: 100, error_count: 0, status_4xx: 0)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7).to_chart_data
          yesterday_index = result[:labels].index(1.day.ago.to_date.strftime("%b %-d"))

          assert_equal 0, result[:series][1][:data][yesterday_index]
        end

        test "works with 30-day period" do
          create_route_day_summary(rails_pulse_routes(:api_users), 15.days.ago, count: 100, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 30).to_chart_data

          assert_equal 31, result[:labels].length
          assert_includes result[:labels], 15.days.ago.to_date.strftime("%b %-d")
        end

        # Hourly Structure Tests

        test "hourly mode returns nil when no summaries exist" do
          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period_type: "hour").to_chart_data

          assert_nil result
        end

        test "hourly mode returns hash with series key" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data

          assert_kind_of Hash, result
          assert_includes result.keys, :series
        end

        test "hourly mode does not return a labels key" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data

          refute_includes result.keys, :labels
        end

        test "hourly mode returns two series" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data

          assert_equal 2, result[:series].length
        end

        test "hourly mode series data contains [timestamp_ms, value] pairs" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data
          first_point = result[:series][0][:data][0]

          assert_kind_of Array, first_point
          assert_equal 2, first_point.length
          assert_operator first_point[0], :>, 1_000_000_000_000, "first element should be a ms timestamp"
          assert_kind_of Integer, first_point[1]
        end

        test "hourly mode series data does not contain plain integers" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data

          result[:series].each do |series|
            series[:data].each do |point|
              refute_kind_of Integer, point, "data points should be [timestamp, value] pairs, not plain integers"
            end
          end
        end

        test "hourly mode returns correct request count at the right timestamp" do
          target_hour = 2.hours.ago.beginning_of_hour
          create_route_hour_summary(rails_pulse_routes(:api_users), target_hour, count: 99, error_count: 3)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data
          target_ms = target_hour.to_i * 1000
          matching = result[:series][0][:data].find { |ts, _| ts == target_ms }

          assert_not_nil matching, "Expected a data point with timestamp #{target_ms}"
          assert_equal 99, matching[1]
        end

        test "hourly mode fills zero for hours with no data" do
          create_route_hour_summary(rails_pulse_routes(:api_users), 1.hour.ago, count: 50, error_count: 2)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(period: 7, period_type: "hour").to_chart_data
          zero_points = result[:series][0][:data].select { |_, val| val == 0 }

          assert_operator zero_points.length, :>, 0, "Expected some zero-value data points for hours with no data"
        end

        # Explicit Range Tests

        test "explicit range buckets exactly the selected days and ignores the trailing window" do
          travel_to Time.zone.parse("2026-09-19 12:00")
          route = rails_pulse_routes(:api_users)
          create_route_day_summary(route, Time.zone.parse("2026-09-15"), count: 9000, error_count: 1000)
          create_route_day_summary(route, Time.zone.parse("2026-09-16"), count: 50, error_count: 5)

          result = RailsPulse::Dashboard::Charts::ThroughputAndErrors.new(
            period: 3, period_type: "day",
            start_time: Time.zone.parse("2026-09-16 00:00").to_i, end_time: Time.zone.parse("2026-09-19 23:59:59").to_i
          ).to_chart_data

          assert_equal [ "Sep 16", "Sep 17", "Sep 18", "Sep 19" ], result[:labels]
          requests = result[:series].find { |s| s[:name] == "Requests" }

          assert_equal [ 50, 0, 0, 0 ], requests[:data]
        end

        private

        def create_route_day_summary(route, date, count:, error_count:, status_4xx: 0)
          RailsPulse::Summary.create!(
            summarizable: route,
            period_start: date.beginning_of_day,
            period_end: date.end_of_day,
            period_type: "day",
            count: count,
            error_count: error_count,
            status_4xx: status_4xx,
            avg_duration: 100.0
          )
        end

        def create_route_hour_summary(route, time, count:, error_count:)
          hour = time.beginning_of_hour
          RailsPulse::Summary.create!(
            summarizable: route,
            period_start: hour,
            period_end: hour.end_of_hour,
            period_type: "hour",
            count: count,
            error_count: error_count,
            avg_duration: 100.0
          )
        end
      end
    end
  end
end
