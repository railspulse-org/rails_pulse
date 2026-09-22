require "test_helper"

module RailsPulse
  module Routes
    module Cards
      class RequestCountTotalsTest < ActiveSupport::TestCase
        fixtures :rails_pulse_routes, :rails_pulse_summaries

        test "returns hash with required keys" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_kind_of Hash, card
          assert_includes card.keys, :id
          assert_includes card.keys, :title
          assert_includes card.keys, :summary
          assert_includes card.keys, :chart_data
          assert_includes card.keys, :trend_icon
          assert_includes card.keys, :trend_amount
          assert_includes card.keys, :trend_text
          assert_includes card.keys, :help_heading
          assert_includes card.keys, :help_text
        end

        test "id is request_count_totals" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_equal "request_count_totals", card[:id]
        end

        test "chart_color is DEFAULT color" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_equal RailsPulse::ChartColors::DEFAULT, card[:chart_color]
        end

        test "context is routes" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_equal "routes", card[:context]
        end

        test "summary format is rate or —" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7).to_metric_card

          assert card[:summary] == "—" || card[:summary].match?(/\d+\.\d+ \/ (min|hour|day)/)
        end

        test "chart_data is a hash" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_kind_of Hash, card[:chart_data]
        end

        test "trend_icon is valid" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_includes [ "move-right", "trending-up", "trending-down" ], card[:trend_icon]
        end

        test "trend_amount is percentage or —" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert card[:trend_amount] == "—" || card[:trend_amount].end_with?("%")
        end

        test "trend_text reflects the selected period" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new.to_metric_card

          assert_equal "Compared to previous 7 days", card[:trend_text]
        end

        test "7-day period has correct sparkline size" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7).to_metric_card

          assert_operator card[:chart_data].size, :>=, 7
          assert_operator card[:chart_data].size, :<=, 8
        end

        test "14-day period has correct sparkline size" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 14).to_metric_card

          assert_operator card[:chart_data].size, :>=, 14
          assert_operator card[:chart_data].size, :<=, 15
        end

        test "30-day period has correct sparkline size" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 30).to_metric_card

          assert_operator card[:chart_data].size, :>=, 30
          assert_operator card[:chart_data].size, :<=, 31
        end

        test "sparkline data has correct structure" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7).to_metric_card
          card[:chart_data].values.each do |data_point|
            assert_kind_of Hash, data_point
            assert_includes data_point.keys, :value
            assert_kind_of Numeric, data_point[:value]
          end
        end

        test "date labels formatted correctly" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7).to_metric_card

          card[:chart_data].keys.each do |label|
            assert_match(/[A-Z][a-z]{2} \d{1,2}/, label)
          end
        end

        test "route-specific mode works" do
          route = rails_pulse_routes(:api_users)
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(route: route, period: 7).to_metric_card

          assert_kind_of Hash, card
        end

        test "aggregate mode works" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(route: nil, period: 7).to_metric_card

          assert_kind_of Hash, card
        end

        test "respects disabled_tags parameter" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(
            disabled_tags: [ 999999 ],
            period: 7
          ).to_metric_card

          assert_kind_of Hash, card
        end

        test "respects show_non_tagged false" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(
            show_non_tagged: false,
            period: 7
          ).to_metric_card

          assert_kind_of Hash, card
        end

        test "handles periods with limited data" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 90).to_metric_card
          # Should return valid structure regardless of data availability
          assert_kind_of String, card[:summary]
          # Trend is hidden for periods > 14 days
          assert_nil card[:trend_amount]
          assert_nil card[:trend_icon]
        end

        test "uses hourly summaries for period_type hour" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 1, period_type: "hour").to_metric_card

          # Should have ~24 data points for 1 day
          assert_operator card[:chart_data].size, :>=, 24
          assert_operator card[:chart_data].size, :<=, 25

          # Keys should be timestamps in milliseconds when using hourly data
          card[:chart_data].keys.each do |key|
            assert_kind_of Integer, key
            assert_operator key, :>, 1000000000000 # Millisecond timestamp
          end
        end

        test "headline total honours the global tag filter like the sparkline does" do
          RailsPulse::Summary.delete_all
          day = 1.day.ago.beginning_of_day
          create_day_summary(rails_pulse_routes(:api_users), day, count: 10) # tagged api, users
          create_day_summary(rails_pulse_routes(:api_other), day, count: 5)  # untagged

          unfiltered = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7).to_metric_card
          users_disabled = RailsPulse::Routes::Cards::RequestCountTotals.new(disabled_tags: [ "users" ], show_non_tagged: true, period: 7).to_metric_card
          tagged_only = RailsPulse::Routes::Cards::RequestCountTotals.new(disabled_tags: [], show_non_tagged: false, period: 7).to_metric_card

          assert_equal "15 requests", unfiltered[:period_stat]
          assert_equal "5 requests", users_disabled[:period_stat]
          assert_equal 5, users_disabled[:chart_data].values.sum { |point| point[:value] }
          assert_equal "10 requests", tagged_only[:period_stat]
        end

        test "uses daily summaries for period_type day" do
          card = RailsPulse::Routes::Cards::RequestCountTotals.new(period: 7, period_type: "day").to_metric_card

          # Should have ~7 data points for 7 days
          assert_operator card[:chart_data].size, :>=, 7
          assert_operator card[:chart_data].size, :<=, 8

          # Keys should be date strings when using daily data
          card[:chart_data].keys.each do |label|
            assert_match(/[A-Z][a-z]{2} \d{1,2}/, label)
          end
        end

        private

        def create_day_summary(route, day, count:)
          RailsPulse::Summary.create!(
            summarizable_type: "RailsPulse::Route", summarizable_id: route.id,
            period_type: "day", period_start: day, period_end: day.end_of_day,
            count: count, success_count: count, error_count: 0,
            avg_duration: 100.0, p95_duration: 100.0
          )
        end
      end
    end
  end
end
