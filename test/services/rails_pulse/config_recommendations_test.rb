require "test_helper"

module RailsPulse
  class ConfigRecommendationsTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes, :rails_pulse_queries

    # Default route thresholds: slow 500, very_slow 1500, critical 3000.
    # Default query thresholds: slow 100, very_slow 500, critical 1000.
    # Default job thresholds: slow 5000, very_slow 30000, critical 60000.

    # Structure Tests

    test "a recommendation has a title, detail and config snippet" do
      rec = recommendations(route_rows: rows(600, 700, 800, 100, 100)).first

      assert_equal "Route slow threshold may be too low", rec[:title]
      assert_includes rec[:detail], "3 of 5 sampled routes exceeded the 500ms slow threshold"
      assert_equal "config.route_thresholds = { slow: 750, very_slow: 1500, critical: 3000 }", rec[:config_snippet]
    end

    # Calculation Tests

    test "recommends raising the route slow threshold when 40% of routes exceed it" do
      # 500 * 1.5 = 750, already a multiple of 50
      recs = recommendations(route_rows: rows(600, 700, 800, 100, 100))

      assert_includes titles(recs), "Route slow threshold may be too low"
    end

    test "does not recommend raising the route slow threshold when under 40% exceed it" do
      recs = recommendations(route_rows: rows(600, 600, 100, 100, 100, 100, 100, 100))

      assert_not_includes titles(recs), "Route slow threshold may be too low"
    end

    test "recommends lowering the route critical threshold when nothing came within half of it" do
      # max(ceil_to(1000 * 2, 500), 500 * 3, very_slow 1500) = 2000
      rec = recommendations(route_rows: rows(1000, 900, 800)).find { |r| r[:title] == "Route critical threshold may be too permissive" }

      assert_equal "config.route_thresholds = { slow: 500, very_slow: 1500, critical: 2000 }", rec[:config_snippet]
      assert_includes rec[:detail], "highest P95: 1000ms"
    end

    test "a lowered critical threshold stays one step above very_slow" do
      # ceil_to(200 * 2, 500) = 500 and 500 * 3 = 1500; very_slow 2500 + 500 wins
      with_route_thresholds(slow: 500, very_slow: 2500, critical: 5000) do
        rec = recommendations(route_rows: rows(200, 150, 100)).find { |r| r[:title].include?("critical") }

        assert_equal "config.route_thresholds = { slow: 500, very_slow: 2500, critical: 3000 }", rec[:config_snippet]
      end
    end

    test "a lowered query critical threshold stays one step above very_slow" do
      # ceil_to(5 * 2, 100) = 100 and 100 * 3 = 300; very_slow 500 + 100 wins
      rec = recommendations(query_rows: rows(5, 4, 3)).find { |r| r[:title] == "Query critical threshold may be too permissive" }

      assert_equal "config.query_thresholds = { slow: 100, very_slow: 500, critical: 600 }", rec[:config_snippet]
    end

    test "the query critical check reads the slowest query, not just the most expensive" do
      # The sampled queries peak at 5ms, but a rarer query in the period reached 450ms:
      # max(ceil_to(450 * 2, 100), 300, 600) = 900
      rec = recommendations(query_rows: rows(5, 4, 3), query_max_p95: 450).find { |r| r[:title].include?("critical") }

      assert_equal "config.query_thresholds = { slow: 100, very_slow: 500, critical: 900 }", rec[:config_snippet]
      assert_includes rec[:detail], "highest P95: 450ms"
    end

    test "does not recommend a query critical threshold below a rare query it would flag" do
      # 550ms is past critical / 2, so the critical threshold is not idle
      recs = recommendations(query_rows: rows(5, 4, 3), query_max_p95: 550)

      assert_not_includes titles(recs), "Query critical threshold may be too permissive"
    end

    test "does not recommend a critical threshold that fails to lower it" do
      # max(ceil_to(1499 * 2, 500), 1500, 1500) = 3000, the current critical
      recs = recommendations(route_rows: rows(1499, 100, 100))

      assert_not_includes titles(recs), "Route critical threshold may be too permissive"
    end

    test "does not recommend a slow threshold at or past very_slow" do
      # ceil_to(1200 * 1.5, 50) = 1800, past very_slow 1500
      with_route_thresholds(slow: 1200, very_slow: 1500, critical: 3000) do
        recs = recommendations(route_rows: rows(1300, 1400, 1400))

        assert_not_includes titles(recs), "Route slow threshold may be too low"
      end
    end

    test "does not recommend a query critical threshold that fails to lower it" do
      # max(ceil_to(499 * 2, 100), 300, 500) = 1000, the current critical
      recs = recommendations(query_rows: rows(499, 400, 300))

      assert_not_includes titles(recs), "Query critical threshold may be too permissive"
    end

    test "returns both route recommendations when both conditions hold" do
      recs = recommendations(route_rows: rows(600, 700, 800, 600, 600))

      assert_equal 2, recs.size
    end

    test "recommends raising the query slow threshold when 40% of queries exceed it" do
      rec = recommendations(query_rows: rows(200, 300, 400, 50, 50)).find { |r| r[:title] == "Query slow threshold may be too low" }

      assert_equal "config.query_thresholds = { slow: 150, very_slow: 500, critical: 1000 }", rec[:config_snippet]
    end

    test "recommends lowering the query critical threshold when nothing came within half of it" do
      # max(ceil_to(400 * 2, 100), 100 * 3, very_slow 500) = 800
      rec = recommendations(query_rows: rows(400, 300, 200)).find { |r| r[:title] == "Query critical threshold may be too permissive" }

      assert_equal "config.query_thresholds = { slow: 100, very_slow: 500, critical: 800 }", rec[:config_snippet]
    end

    test "recommends raising the job slow threshold when 40% of jobs exceed it" do
      # 5000 * 1.5 = 7500, already a multiple of 500
      rec = recommendations(job_rows: rows(6_000, 7_000, 8_000, 100, 100)).find { |r| r[:title] == "Job slow threshold may be too low" }

      assert_includes rec[:detail], "3 of 5 sampled jobs exceeded the 5000ms slow threshold this period."
      assert_equal "config.job_thresholds = { slow: 7500, very_slow: 30000, critical: 60000 }", rec[:config_snippet]
    end

    test "recommends lowering the job critical threshold when nothing came within half of it" do
      # max(ceil_to(20000 * 2, 5000), 5000 * 3, very_slow 30000 + 5000) = 40000
      rec = recommendations(job_rows: rows(20_000, 1_000, 900)).find { |r| r[:title] == "Job critical threshold may be too permissive" }

      assert_includes rec[:detail], "No job came close to the 60000ms critical threshold this period (highest P95: 20000ms)."
      assert_equal "config.job_thresholds = { slow: 5000, very_slow: 30000, critical: 40000 }", rec[:config_snippet]
    end

    test "a lowered job critical threshold stays one step above very_slow" do
      # ceil_to(100 * 2, 5000) = 5000 and 5000 * 3 = 15000; very_slow 30000 + 5000 wins
      rec = recommendations(job_rows: rows(100, 90, 80)).find { |r| r[:title].include?("critical") }

      assert_equal "config.job_thresholds = { slow: 5000, very_slow: 30000, critical: 35000 }", rec[:config_snippet]
    end

    test "does not recommend a job critical threshold that fails to lower it" do
      # max(ceil_to(29999 * 2, 5000), 15000, 35000) = 60000, the current critical
      recs = recommendations(job_rows: rows(29_999, 100, 100))

      assert_not_includes titles(recs), "Job critical threshold may be too permissive"
    end

    test "job recommendations follow the configured job thresholds" do
      with_job_thresholds(slow: 1_000, very_slow: 10_000, critical: 20_000) do
        rec = recommendations(job_rows: rows(2_000, 3_000, 4_000)).find { |r| r[:title] == "Job slow threshold may be too low" }

        assert_equal "config.job_thresholds = { slow: 1500, very_slow: 10000, critical: 20000 }", rec[:config_snippet]
      end
    end

    test "slow threshold suggestions round up to the step" do
      # 510 * 1.5 = 765, rounded up to 800
      with_route_thresholds(slow: 510, very_slow: 1500, critical: 3000) do
        rec = recommendations(route_rows: rows(600, 700, 800)).find { |r| r[:title].include?("slow") }

        assert_includes rec[:config_snippet], "slow: 800"
      end
    end

    test "for_period samples the period's slowest routes and most expensive queries" do
      RailsPulse::Summary.delete_all
      period_start = Time.zone.parse("2026-06-01")
      %i[api_users api_posts api_test].each { |name| summary(rails_pulse_routes(name), period_start, p95: 900) }
      summary(rails_pulse_routes(:api_other), period_start - 1.week, p95: 9000)

      recs = ConfigRecommendations.for_period(period_type: "week", period_start: period_start).to_recommendations

      assert_includes titles(recs), "Route slow threshold may be too low"
      assert_includes recs.first[:detail], "3 of 3 sampled routes"
    end

    test "for_period reads the period's slowest query for the critical check" do
      RailsPulse::Summary.delete_all
      period_start = Time.zone.parse("2026-06-01")
      # Three cheap, frequent queries make up the expensive sample; a rare slow
      # one has little total time but the period's highest P95.
      RailsPulse::Query.limit(3).each { |query| summary(query, period_start, p95: 4, count: 10_000) }
      rare = RailsPulse::Query.create!(normalized_sql: "SELECT * FROM rare_table WHERE id = ?")
      summary(rare, period_start, p95: 450, count: 1)

      rec = ConfigRecommendations.for_period(period_type: "week", period_start: period_start)
        .to_recommendations.find { |r| r[:title] == "Query critical threshold may be too permissive" }

      assert_includes rec[:detail], "highest P95: 450ms"
    end

    test "for_period samples the period's slowest jobs" do
      RailsPulse::Summary.delete_all
      period_start = Time.zone.parse("2026-06-01")
      3.times { |i| summary(RailsPulse::Job.create!(name: "SlowJob#{i}"), period_start, p95: 9_000) }

      recs = ConfigRecommendations.for_period(period_type: "week", period_start: period_start).to_recommendations

      assert_includes titles(recs), "Job slow threshold may be too low"
    end

    # Edge Cases

    test "returns nothing with fewer than 3 job rows" do
      assert_empty recommendations(job_rows: rows(9_000, 9_000))
    end

    test "returns nothing with fewer than 3 route rows" do
      assert_empty recommendations(route_rows: rows(600, 700))
    end

    test "returns nothing with fewer than 3 query rows" do
      assert_empty recommendations(query_rows: rows(200, 300))
    end

    test "returns nothing when no condition is met" do
      # 1 of 5 exceed slow (20%); max 1600 is past critical / 2
      assert_empty recommendations(route_rows: rows(1600, 100, 100, 100, 100))
    end

    test "rows with no P95 count as zero" do
      assert_empty recommendations(route_rows: [ { p95_duration: nil } ] * 3)
    end

    test "for_period with no summaries recommends nothing" do
      RailsPulse::Summary.delete_all

      assert_empty ConfigRecommendations.for_period(period_type: "week", period_start: Time.zone.parse("2026-06-01")).to_recommendations
    end

    private

    def recommendations(route_rows: [], query_rows: [], query_max_p95: nil, job_rows: [])
      ConfigRecommendations.new(route_rows: route_rows, query_rows: query_rows, query_max_p95: query_max_p95, job_rows: job_rows).to_recommendations
    end

    def with_job_thresholds(thresholds)
      original = RailsPulse.configuration.job_thresholds
      RailsPulse.configuration.job_thresholds = thresholds
      yield
    ensure
      RailsPulse.configuration.job_thresholds = original
    end

    def rows(*p95s)
      p95s.map { |p95| { p95_duration: p95 } }
    end

    def titles(recs)
      recs.map { |r| r[:title] }
    end

    def with_route_thresholds(thresholds)
      original = RailsPulse.configuration.route_thresholds
      RailsPulse.configuration.route_thresholds = thresholds
      yield
    ensure
      RailsPulse.configuration.route_thresholds = original
    end

    def summary(record, period_start, p95:, count: 100)
      RailsPulse::Summary.create!(
        summarizable: record, period_type: "week", period_start: period_start,
        period_end: period_start.end_of_week, count: count, avg_duration: p95 / 2,
        p95_duration: p95, error_count: 0, success_count: count
      )
    end
  end
end
