require "test_helper"

module RailsPulse
  module Queries
    module Charts
      class QueryPerformanceTest < ActiveSupport::TestCase
        def setup
          @query = rails_pulse_queries(:complex_query)
          @start_time = 1.day.ago.beginning_of_day
          @end_time = Time.current.end_of_day
          @ransack_query = RailsPulse::Summary.ransack
        end

        test "initializes with required parameters" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          assert_kind_of QueryPerformance, chart
        end

        test "returns chart data with series" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert data.key?(:series)
          assert_kind_of Array, data[:series]
        end

        test "includes P95 and P99 series" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          series_names = data[:series].map { |s| s[:name] }

          assert_includes series_names, "P95"
          assert_includes series_names, "P99"
        end

        test "P95 series has correct configuration" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          p95_series = data[:series].find { |s| s[:name] == "P95" }

          assert_equal "line", p95_series[:type]
          assert_equal RailsPulse::ChartColors::P95, p95_series[:color]
          assert_kind_of Array, p95_series[:data]
        end

        test "P99 series has correct configuration" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          p99_series = data[:series].find { |s| s[:name] == "P99" }

          assert_equal "line", p99_series[:type]
          assert_equal "#3b82f6", p99_series[:color]
          assert_kind_of Array, p99_series[:data]
        end

        test "filters by query when provided" do
          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            query: @query,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          # Should not raise error
          data = chart.to_chart_data

          assert data.key?(:series)
        end

        test "handles empty data gracefully" do
          # Create a ransack query that returns no results
          empty_query = RailsPulse::Summary.ransack(period_start_lt: 1.year.ago)

          chart = QueryPerformance.new(
            ransack_query: empty_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data

          assert data.key?(:series)
          # Should still have P95 and P99 series with zero values
          series_names = data[:series].map { |s| s[:name] }

          assert_includes series_names, "P95"
          assert_includes series_names, "P99"
        end

        test "includes SLO series when configured" do
          # Skip if no query SLOs configured
          skip if RailsPulse.configuration.query_service_level_objectives.empty?

          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          series_names = data[:series].map { |s| s[:name] }

          assert series_names.any? { |name| name.match?(/P\d+ SLO \(\d+ms\)/) }
        end

        test "renders one SLO line per configured SLO entry" do
          original_config = RailsPulse.configuration.query_service_level_objectives
          RailsPulse.configuration.query_service_level_objectives = [
            { percentile: 95, threshold: 50 },
            { percentile: 99, threshold: 100 }
          ]

          chart = QueryPerformance.new(
            ransack_query: @ransack_query,
            period_type: :day,
            window: RailsPulse::TimeWindow.new(@start_time, @end_time)
          )

          data = chart.to_chart_data
          slo_series = data[:series].select { |s| s[:name].match?(/P\d+ SLO/) }

          assert_equal 2, slo_series.length
          p95_slo = slo_series.find { |s| s[:name].include?("P95") }
          p99_slo = slo_series.find { |s| s[:name].include?("P99") }

          assert_equal RailsPulse::ChartColors::P95, p95_slo[:color]
          assert_equal "#3b82f6", p99_slo[:color]
        ensure
          RailsPulse.configuration.query_service_level_objectives = original_config
        end
      end
    end
  end
end
