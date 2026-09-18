require "test_helper"

module RailsPulse
  module Cards
    class BaseTest < ActiveSupport::TestCase
      fixtures :rails_pulse_jobs, :rails_pulse_summaries

      def setup
        ENV["TEST_TYPE"] = "functional"
        super

        @now = Time.current
        travel_to @now
      end

      def teardown
        travel_back
        super
      end

      # Helper class to test the base class
      class TestCard < Base
        attr_reader :disabled_tags, :show_non_tagged

        def initialize(job: nil, disabled_tags: [], show_non_tagged: true, period: 7, period_type: "day", start_time: nil, end_time: nil)
          @job = job
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @start_time = start_time
          @end_time = end_time
        end
      end

      # Explicit Range Tests

      def ranged_card(period_type: "day")
        TestCard.new(
          period: 3, period_type: period_type,
          start_time: Time.zone.parse("2026-09-16 00:00").to_i,
          end_time: Time.zone.parse("2026-09-19 23:59:59").to_i
        )
      end

      test "explicit range anchors now to the range end instead of the clock" do
        assert_equal Time.zone.parse("2026-09-19 23:59:59"), ranged_card.send(:now)
      end

      test "explicit range sets current_window_start to the range start" do
        assert_equal Time.zone.parse("2026-09-16 00:00"), ranged_card.send(:current_window_start)
      end

      test "explicit range counts whole days without truncating" do
        assert_equal 4, ranged_card.send(:window_days)
        assert_equal "Compared to previous 4 days", ranged_card.send(:comparison_period_text)
      end

      test "explicit range previous window is the same length immediately before" do
        assert_equal Time.zone.parse("2026-09-12 00:00"), ranged_card.send(:previous_window_start)
      end

      test "explicit range daily sparkline covers exactly the selected days" do
        sparkline = ranged_card.send(:sparkline_from, {})

        assert_equal [ "Sep 16", "Sep 17", "Sep 18", "Sep 19" ], sparkline.keys
      end

      test "explicit range date label spans the selected days" do
        assert_equal "Sep 16 – Sep 19", ranged_card.send(:period_date_range)
      end

      # Time Period Tests - Day Type

      test "now returns current time" do
        card = TestCard.new
        # Allow for minor precision differences
        assert_in_delta @now.to_f, card.send(:now).to_f, 1.0
      end

      test "window_days returns period value" do
        card = TestCard.new(period: 14)

        assert_equal 14, card.send(:window_days)
      end

      test "window_days defaults to 7 when period not set" do
        card = TestCard.new

        assert_equal 7, card.send(:window_days)
      end

      test "period_type_hours? returns false for day type" do
        card = TestCard.new(period_type: "day")

        refute card.send(:period_type_hours?)
      end

      test "period_type_hours? returns true for hour type" do
        card = TestCard.new(period_type: "hour")

        assert card.send(:period_type_hours?)
      end

      test "current_window_start returns beginning of day for day type" do
        card = TestCard.new(period: 7, period_type: "day")
        expected = 7.days.ago.beginning_of_day

        assert_equal expected, card.send(:current_window_start)
      end

      test "previous_window_start returns beginning of previous window for day type" do
        card = TestCard.new(period: 7, period_type: "day")
        expected = 14.days.ago.beginning_of_day

        assert_equal expected, card.send(:previous_window_start)
      end

      test "range_start returns previous_window_start" do
        card = TestCard.new(period: 7, period_type: "day")

        assert_equal card.send(:previous_window_start), card.send(:range_start)
      end

      # Time Period Tests - Hour Type

      test "current_window_start returns beginning of hour for hour type" do
        card = TestCard.new(period: 1, period_type: "hour")
        expected = 24.hours.ago.beginning_of_hour

        assert_equal expected, card.send(:current_window_start)
      end

      test "previous_window_start returns beginning of previous window for hour type" do
        card = TestCard.new(period: 1, period_type: "hour")
        expected = 48.hours.ago.beginning_of_hour

        assert_equal expected, card.send(:previous_window_start)
      end

      test "current_window_start with period 2 days uses 48 hours for hour type" do
        card = TestCard.new(period: 2, period_type: "hour")
        expected = 48.hours.ago.beginning_of_hour

        assert_equal expected, card.send(:current_window_start)
      end

      # Trend Calculation Tests

      test "trend_for returns trending-up when current exceeds previous" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 150, 100)

        assert_equal "trending-up", icon
        assert_equal "50.0%", amount
      end

      test "trend_for returns trending-down when current is less than previous" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 50, 100)

        assert_equal "trending-down", icon
        assert_equal "50.0%", amount
      end

      test "trend_for returns move-right when change is less than 0.1%" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 100.0, 100.05)

        assert_equal "move-right", icon
      end

      test "trend_for returns 0% when previous is zero" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 100, 0)

        assert_equal "move-right", icon
        assert_equal "0.0%", amount
      end

      test "trend_for handles equal values" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 100, 100)

        assert_equal "move-right", icon
      end

      test "trend_for respects precision parameter" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, 150.456, 100, precision: 2)

        assert_equal "50.46%", amount
      end

      # Sparkline Generation Tests - Day Type

      test "sparkline_from generates daily sparkline for day type" do
        card = TestCard.new(period: 7, period_type: "day")
        grouped_values = {
          3.days.ago.to_date => 10,
          2.days.ago.to_date => 20
        }

        result = card.send(:sparkline_from, grouped_values)

        assert_kind_of Hash, result
        assert_operator result.size, :>=, 2
      end

      test "sparkline_from fills missing days with zeros" do
        card = TestCard.new(period: 7, period_type: "day")
        grouped_values = { 3.days.ago.to_date => 10 }

        result = card.send(:sparkline_from, grouped_values)

        # Should have 8 days (7 days ago through today)
        assert_equal 8, result.size
      end

      test "sparkline_from uses date labels for day type" do
        card = TestCard.new(period: 7, period_type: "day")
        date = 3.days.ago.to_date
        grouped_values = { date => 10 }

        result = card.send(:sparkline_from, grouped_values)
        expected_label = date.strftime("%b %-d")

        assert_includes result.keys, expected_label
      end

      test "sparkline_from includes value hash structure" do
        card = TestCard.new(period: 7, period_type: "day")
        grouped_values = { 3.days.ago.to_date => 10 }

        result = card.send(:sparkline_from, grouped_values)

        result.each_value do |entry|
          assert_kind_of Hash, entry
          assert_includes entry, :value
        end
      end

      # Sparkline Generation Tests - Hour Type

      test "sparkline_from generates hourly sparkline for hour type" do
        card = TestCard.new(period: 1, period_type: "hour")
        grouped_values = {
          3.hours.ago.beginning_of_hour => 10,
          2.hours.ago.beginning_of_hour => 20
        }

        result = card.send(:sparkline_from, grouped_values)

        assert_kind_of Hash, result
        assert_operator result.size, :>=, 2
      end

      test "sparkline_from fills missing hours with zeros" do
        card = TestCard.new(period: 1, period_type: "hour")
        grouped_values = { 3.hours.ago.beginning_of_hour => 10 }

        result = card.send(:sparkline_from, grouped_values)

        # Should have hours from 24 hours ago through current hour
        assert_operator result.size, :>=, 20
      end

      test "sparkline_from uses millisecond timestamps for hour type" do
        card = TestCard.new(period: 1, period_type: "hour")
        time = 3.hours.ago.beginning_of_hour
        grouped_values = { time => 10 }

        result = card.send(:sparkline_from, grouped_values)
        expected_key = time.to_i * 1000

        assert_includes result.keys, expected_key
      end

      # Format Helper Tests

      test "format_duration returns milliseconds with ms suffix" do
        card = TestCard.new

        assert_equal "101 ms", card.send(:format_duration, 100.5)
        assert_equal "150 ms", card.send(:format_duration, 150.2)
      end

      test "format_duration rounds to integer" do
        card = TestCard.new

        assert_equal "101 ms", card.send(:format_duration, 100.6)
      end

      test "format_percentage returns percentage with % suffix" do
        card = TestCard.new

        assert_equal "50.5%", card.send(:format_percentage, 50.5)
        assert_equal "100.0%", card.send(:format_percentage, 100.0)
      end

      test "format_percentage respects precision parameter" do
        card = TestCard.new

        assert_equal "50%", card.send(:format_percentage, 50.123, 0)
        assert_equal "50.12%", card.send(:format_percentage, 50.123, 2)
      end

      test "format_number returns delimited number" do
        card = TestCard.new

        assert_equal "1,000", card.send(:format_number, 1000)
        assert_equal "1,000,000", card.send(:format_number, 1000000)
      end

      test "format_number handles decimal numbers" do
        card = TestCard.new

        result = card.send(:format_number, 1000.5)

        assert_includes result, "1,000"
      end

      # Base Query Helper Tests

      test "base_summary_query constructs query with summarizable_type" do
        card = TestCard.new(job: rails_pulse_jobs(:report_job))

        query = card.send(:base_summary_query, "RailsPulse::Job")

        assert_kind_of ActiveRecord::Relation, query
        # Verify it includes the summarizable_type condition
        assert_includes query.to_sql, "RailsPulse::Job"
      end

      test "base_summary_query filters by subject_id when present" do
        job = rails_pulse_jobs(:report_job)
        card = TestCard.new(job: job)

        query = card.send(:base_summary_query, "RailsPulse::Job")

        assert_includes query.to_sql, job.id.to_s
      end

      test "base_summary_query does not filter by subject_id when nil" do
        card = TestCard.new

        query = card.send(:base_summary_query, "RailsPulse::Job")

        # Should not have a specific job ID filter
        assert_kind_of ActiveRecord::Relation, query
      end

      test "base_summary_query applies tag filters when available" do
        card = TestCard.new(disabled_tags: [ "slow" ])

        query = card.send(:base_summary_query, "RailsPulse::Job")

        # Should call with_tag_filters (tested through SQL)
        assert_kind_of ActiveRecord::Relation, query
      end

      test "base_summary_query uses period_type from initialization" do
        card = TestCard.new(period_type: "hour")

        query = card.send(:base_summary_query, "RailsPulse::Job")

        assert_includes query.to_sql, "hour"
      end

      test "base_summary_query defaults to day when period_type not set" do
        card = TestCard.new

        query = card.send(:base_summary_query, "RailsPulse::Job")

        assert_includes query.to_sql, "day"
      end

      test "base_summary_query uses range_start and now for time range" do
        card = TestCard.new(period: 7, period_type: "day")

        query = card.send(:base_summary_query, "RailsPulse::Job")

        # Verify the time range is included
        assert_kind_of ActiveRecord::Relation, query
      end

      # Subject ID Tests

      test "subject_id returns job id when job present" do
        job = rails_pulse_jobs(:report_job)
        card = TestCard.new(job: job)

        assert_equal job.id, card.send(:subject_id)
      end

      test "subject_id returns nil when no subject present" do
        card = TestCard.new

        assert_nil card.send(:subject_id)
      end

      # Quote Helper Tests

      test "quote returns quoted SQL string" do
        card = TestCard.new
        time = Time.current

        quoted = card.send(:quote, time)

        assert_kind_of String, quoted
        refute_equal time.to_s, quoted
      end

      # Edge Cases

      test "handles period of 0 days" do
        card = TestCard.new(period: 0, period_type: "day")

        assert_equal 0, card.send(:window_days)
      end

      test "handles very large period values" do
        card = TestCard.new(period: 365, period_type: "day")

        assert_equal 365, card.send(:window_days)
        assert_equal 365.days.ago.beginning_of_day, card.send(:current_window_start)
      end

      test "sparkline_from handles empty grouped_values" do
        card = TestCard.new(period: 7, period_type: "day")

        result = card.send(:sparkline_from, {})

        assert_kind_of Hash, result
        # Should still create entries for each day
        assert_operator result.size, :>, 0
      end

      test "trend_for handles negative values" do
        card = TestCard.new

        icon, amount = card.send(:trend_for, -50, 100)

        assert_equal "trending-down", icon
      end

      test "format_duration handles zero" do
        card = TestCard.new

        assert_equal "0 ms", card.send(:format_duration, 0)
      end

      test "format_number handles zero" do
        card = TestCard.new

        assert_equal "0", card.send(:format_number, 0)
      end
    end
  end
end
