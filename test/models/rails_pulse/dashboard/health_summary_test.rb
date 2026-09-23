require "test_helper"

module RailsPulse
  module Dashboard
    class HealthSummaryTest < ActiveSupport::TestCase
      fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_jobs, :rails_pulse_events

      def setup
        RailsPulse::Summary.delete_all
        RailsPulse::Job.update_all(runs_count: 0, failures_count: 0, p95_duration: nil)
        @now = Time.current
        travel_to @now
      end

      def teardown
        travel_back
      end

      # Structure Tests

      # Tracking Tests

      test "tracking counts writers as writing, backlogged or dropping" do
        # web-1 is live with 12 of 1000 queued and no drops; web-2 dropped 7 in the hour.
        rails_pulse_events(:web_two_latest).update!(value: 7)

        assert_equal({ healthy: 1, slow: 0, critical: 1 }, RailsPulse::Dashboard::HealthSummary.new.to_health_data[:tracking])
      end

      test "tracking counts a writer whose queue is at least half full as backlogged" do
        heartbeat = rails_pulse_events(:web_one_latest)
        heartbeat.update!(metadata: heartbeat.metadata_hash.merge("queue_depth" => 500).to_json)

        assert_equal({ healthy: 1, slow: 1, critical: 0 }, RailsPulse::Dashboard::HealthSummary.new.to_health_data[:tracking])
      end

      test "tracking still counts a writer that dropped and then went away" do
        RailsPulse::Event.where(subject: "web-2:202").update_all(value: 7, occurred_at: 10.minutes.ago)

        assert_equal({ healthy: 1, slow: 0, critical: 1 }, RailsPulse::Dashboard::HealthSummary.new.to_health_data[:tracking])
      end

      test "tracking is nil until any writer has reported" do
        RailsPulse::Event.delete_all

        assert_nil RailsPulse::Dashboard::HealthSummary.new.to_health_data[:tracking]
      end

      test "returns hash with routes, queries, jobs, and storage keys" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_kind_of Hash, result
        assert_includes result.keys, :routes
        assert_includes result.keys, :queries
        assert_includes result.keys, :jobs
        assert_includes result.keys, :storage
      end

      test "routes and queries values have healthy, slow, and critical keys" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        [ :routes, :queries ].each do |category|
          assert_includes result[category].keys, :healthy
          assert_includes result[category].keys, :slow
          assert_includes result[category].keys, :critical
        end
      end

      test "jobs is nil when track_jobs is disabled" do
        saved = RailsPulse.configuration.track_jobs
        RailsPulse.configuration.track_jobs = false

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_nil result[:jobs]
      ensure
        RailsPulse.configuration.track_jobs = saved
      end

      test "jobs has healthy, slow, and critical keys when track_jobs is enabled" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_includes result[:jobs].keys, :healthy
        assert_includes result[:jobs].keys, :slow
        assert_includes result[:jobs].keys, :critical
      end

      # Edge Cases — No Data

      test "returns all zeros when no summaries exist" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
        assert_equal 0, result[:queries][:healthy]
        assert_equal 0, result[:queries][:slow]
        assert_equal 0, result[:queries][:critical]
      end

      test "returns all zeros for jobs when no jobs have runs" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:jobs][:healthy]
        assert_equal 0, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      # Route Tier Assignment

      test "route with p95 below slow threshold and low error rate is healthy" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 2, p95: 300.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
      end

      test "route with p95 >= slow threshold is slow" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 0, p95: 800.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 1, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
      end

      test "route with p95 >= critical threshold is critical" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 0, p95: 3000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 1, result[:routes][:critical]
      end

      test "route with error rate >= 10% is critical" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 10, p95: 200.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 1, result[:routes][:critical]
      end

      test "route with error rate >= 5% and < 10% is slow" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 7, p95: 200.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 1, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
      end

      test "route with exactly 5% error rate is slow" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 5, p95: 200.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
      end

      test "route with exactly 10% error rate is critical" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 10, p95: 200.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:routes][:critical]
      end

      test "multiple routes are tallied independently" do
        create_route_summary(route: rails_pulse_routes(:api_users),  count: 100, errors: 0,  p95: 200.0)   # healthy
        create_route_summary(route: rails_pulse_routes(:api_posts),  count: 100, errors: 6,  p95: 200.0)   # slow
        create_route_summary(route: rails_pulse_routes(:api_test),   count: 100, errors: 12, p95: 200.0)   # critical
        create_route_summary(route: rails_pulse_routes(:api_other),  count: 100, errors: 0,  p95: 200.0)   # healthy
        create_route_summary(route: rails_pulse_routes(:api_cleanup), count: 100, errors: 0, p95: 3500.0)  # critical

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 2, result[:routes][:healthy]
        assert_equal 1, result[:routes][:slow]
        assert_equal 2, result[:routes][:critical]
      end

      # Edge Case — All Healthy Routes

      test "all healthy routes returns all in healthy bucket" do
        routes = [ :api_users, :api_posts, :api_test ]
        routes.each { |r| create_route_summary(route: rails_pulse_routes(r), count: 100, errors: 1, p95: 200.0) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 3, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 0, result[:routes][:critical]
      end

      # Edge Case — All Critical Routes

      test "all critical routes returns all in critical bucket" do
        routes = [ :api_users, :api_posts, :api_test ]
        routes.each { |r| create_route_summary(route: rails_pulse_routes(r), count: 100, errors: 15, p95: 200.0) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:routes][:healthy]
        assert_equal 0, result[:routes][:slow]
        assert_equal 3, result[:routes][:critical]
      end

      # Query Tier Assignment

      test "query with p95 below slow threshold is healthy" do
        query = rails_pulse_queries(:simple_query)
        create_query_summary(query: query, count: 100, p95: 50.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:queries][:healthy]
        assert_equal 0, result[:queries][:slow]
        assert_equal 0, result[:queries][:critical]
      end

      test "query with p95 >= slow threshold is slow" do
        query = rails_pulse_queries(:simple_query)
        create_query_summary(query: query, count: 100, p95: 200.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:queries][:healthy]
        assert_equal 1, result[:queries][:slow]
        assert_equal 0, result[:queries][:critical]
      end

      test "query with p95 >= critical threshold is critical" do
        query = rails_pulse_queries(:simple_query)
        create_query_summary(query: query, count: 100, p95: 1000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:queries][:healthy]
        assert_equal 0, result[:queries][:slow]
        assert_equal 1, result[:queries][:critical]
      end

      test "multiple queries are tallied independently" do
        create_query_summary(query: rails_pulse_queries(:simple_query),  count: 100, p95: 50.0)    # healthy
        create_query_summary(query: rails_pulse_queries(:complex_query), count: 100, p95: 200.0)   # slow
        create_query_summary(query: rails_pulse_queries(:analyzed_query), count: 100, p95: 1500.0) # critical

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:queries][:healthy]
        assert_equal 1, result[:queries][:slow]
        assert_equal 1, result[:queries][:critical]
      end

      # Edge Case — All Healthy Queries

      test "all healthy queries returns all in healthy bucket" do
        queries = [ :simple_query, :complex_query ]
        queries.each { |q| create_query_summary(query: rails_pulse_queries(q), count: 100, p95: 30.0) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 2, result[:queries][:healthy]
        assert_equal 0, result[:queries][:slow]
        assert_equal 0, result[:queries][:critical]
      end

      # Edge Case — All Critical Queries

      test "all critical queries returns all in critical bucket" do
        queries = [ :simple_query, :complex_query ]
        queries.each { |q| create_query_summary(query: rails_pulse_queries(q), count: 100, p95: 2000.0) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:queries][:healthy]
        assert_equal 0, result[:queries][:slow]
        assert_equal 2, result[:queries][:critical]
      end

      # Job Tier Assignment

      test "job below failure rate and p95 thresholds is healthy" do
        RailsPulse::Job.create!(name: "HealthyJob", runs_count: 100, failures_count: 2, p95_duration: 1000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:jobs][:healthy]
        assert_equal 0, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      test "job with failure rate >= 5% and < 10% is slow" do
        RailsPulse::Job.create!(name: "SlowJob", runs_count: 100, failures_count: 7, p95_duration: 1000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      test "job with failure rate >= 10% is critical" do
        RailsPulse::Job.create!(name: "CriticalJob", runs_count: 100, failures_count: 10, p95_duration: 1000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:jobs][:critical]
        assert_equal 0, result[:jobs][:slow]
      end

      test "job with p95 >= slow threshold is slow" do
        RailsPulse::Job.create!(name: "SlowDurationJob", runs_count: 100, failures_count: 0, p95_duration: 6000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      test "job with p95 >= critical threshold is critical" do
        RailsPulse::Job.create!(name: "CriticalDurationJob", runs_count: 100, failures_count: 0, p95_duration: 60_000.0)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:jobs][:critical]
      end

      test "jobs with zero runs are excluded" do
        # All jobs already have runs_count: 0 from setup, none should appear
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:jobs][:healthy]
        assert_equal 0, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      # Edge Case — All Healthy Jobs

      test "all healthy jobs returns all in healthy bucket" do
        3.times { |i| RailsPulse::Job.create!(name: "HealthyJob#{i}", runs_count: 100, failures_count: 1) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 3, result[:jobs][:healthy]
        assert_equal 0, result[:jobs][:slow]
        assert_equal 0, result[:jobs][:critical]
      end

      # Edge Case — All Critical Jobs

      test "all critical jobs returns all in critical bucket" do
        3.times { |i| RailsPulse::Job.create!(name: "CriticalJob#{i}", runs_count: 100, failures_count: 15) }

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 0, result[:jobs][:healthy]
        assert_equal 0, result[:jobs][:slow]
        assert_equal 3, result[:jobs][:critical]
      end

      # Period Filtering Tests

      test "excludes summaries outside period range" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 20, p95: 200.0, days_ago: 10)

        result = RailsPulse::Dashboard::HealthSummary.new(period: 7).to_health_data

        assert_equal 0, result[:routes][:healthy] + result[:routes][:slow] + result[:routes][:critical]
      end

      test "includes summaries within period range" do
        route = rails_pulse_routes(:api_users)
        create_route_summary(route: route, count: 100, errors: 20, p95: 200.0, days_ago: 5)

        result = RailsPulse::Dashboard::HealthSummary.new(period: 7).to_health_data

        assert_equal 1, result[:routes][:critical]
      end

      test "period 30 includes data from 25 days ago" do
        query = rails_pulse_queries(:simple_query)
        create_query_summary(query: query, count: 100, p95: 2000.0, days_ago: 25)

        result = RailsPulse::Dashboard::HealthSummary.new(period: 30).to_health_data

        assert_equal 1, result[:queries][:critical]
      end

      private

      # Storage Health Badge Tests

      test "storage value has healthy, slow, and critical keys" do
        create_overall_hourly_summary(period_end: 30.minutes.ago)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_includes result[:storage].keys, :healthy
        assert_includes result[:storage].keys, :slow
        assert_includes result[:storage].keys, :critical
      end

      test "storage is healthy when summary is fresh" do
        create_overall_hourly_summary(period_end: 30.minutes.ago)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:storage][:healthy]
        assert_equal 0, result[:storage][:slow]
        assert_equal 0, result[:storage][:critical]
      end

      test "storage is slow when summary is 3 hours stale" do
        create_overall_hourly_summary(period_end: 3.hours.ago)

        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:storage][:slow]
        assert_equal 0, result[:storage][:critical]
      end

      test "storage is critical when summary job has never run" do
        result = RailsPulse::Dashboard::HealthSummary.new.to_health_data

        assert_equal 1, result[:storage][:critical]
        assert_equal 0, result[:storage][:healthy]
      end

      def create_overall_hourly_summary(period_end:)
        RailsPulse::Summary.create!(
          summarizable_type: "RailsPulse::Request",
          summarizable_id:   0,
          period_type:       "hour",
          period_start:      period_end.beginning_of_hour,
          period_end:        period_end,
          count:             1,
          avg_duration:      100.0
        )
      end

      def create_route_summary(route:, count:, errors:, p95:, days_ago: 2)
        period_start = days_ago.days.ago.beginning_of_day
        RailsPulse::Summary.create!(
          summarizable_type: "RailsPulse::Route",
          summarizable_id:   route.id,
          period_start:      period_start,
          period_end:        period_start.end_of_day,
          period_type:       "day",
          count:             count,
          error_count:       errors,
          avg_duration:      p95 * 0.7,
          p95_duration:      p95
        )
      end

      def create_query_summary(query:, count:, p95:, days_ago: 2)
        period_start = days_ago.days.ago.beginning_of_day
        RailsPulse::Summary.create!(
          summarizable_type: "RailsPulse::Query",
          summarizable_id:   query.id,
          period_start:      period_start,
          period_end:        period_start.end_of_day,
          period_type:       "day",
          count:             count,
          avg_duration:      p95 * 0.7,
          p95_duration:      p95
        )
      end
    end
  end
end
