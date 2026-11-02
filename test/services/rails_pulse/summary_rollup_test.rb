require "test_helper"

module RailsPulse
  # Days are rolled up from their hours, weeks and months from their days, so
  # a long period never re-reads its raw rows.
  class SummaryRollupTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_jobs, :rails_pulse_exception_groups

    def setup
      RailsPulse::Summary.delete_all
      RailsPulse::Operation.delete_all
      RailsPulse::Request.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::ExceptionOccurrence.delete_all

      @route = rails_pulse_routes(:api_users)
      # Wednesday; the day under test is the Monday before it.
      travel_to Time.zone.parse("2024-03-06 12:30:00")
      @day = Time.zone.parse("2024-03-04 00:00:00")
    end

    def teardown
      travel_back
    end

    # Calculation Tests

    test "a day's counts, totals, extremes and status counts are the sums of its hours" do
      request_at(@day + 1.hour, 100, status: 200)
      request_at(@day + 1.hour, 300, status: 500)
      request_at(@day + 5.hours, 50, status: 404)

      summarize("day", @day)
      day = summary("RailsPulse::Route", @route.id, "day", @day)

      assert_equal 3, day.count
      assert_in_delta 450.0, day.total_duration
      assert_in_delta 150.0, day.avg_duration
      assert_in_delta 50.0, day.min_duration
      assert_in_delta 300.0, day.max_duration
      assert_equal 1, day.error_count
      assert_equal 2, day.success_count
      assert_equal 1, day.status_2xx
      assert_equal 1, day.status_4xx
      assert_equal 1, day.status_5xx
    end

    test "a day's standard deviation is exact across hours" do
      durations = [ 10, 20, 30, 100, 400 ]
      durations.first(3).each { |d| request_at(@day + 2.hours, d) }
      durations.last(2).each { |d| request_at(@day + 9.hours, d) }

      summarize("day", @day)

      expected = Statistics.calculate_stddev(durations, durations.sum.to_f / durations.size)

      # MySQL stores the summaries' float columns in single precision.
      assert_in_delta expected, summary("RailsPulse::Request", 0, "day", @day).stddev_duration, 0.01
    end

    test "a day's percentiles are the traffic-weighted average of its hours'" do
      # Distinct durations in each hour, so every percentile differs from the
      # others and a column weighted from the wrong child column shows up.
      early = (1..10).map { |i| i * 10.0 }
      late = [ 200.0, 300.0, 500.0, 800.0, 1_300.0 ]
      early.each { |d| request_at(@day + 2.hours, d) }
      late.each { |d| request_at(@day + 9.hours, d) }

      summarize("day", @day)
      day = summary("RailsPulse::Request", 0, "day", @day)

      expected = SummaryService::PERCENTILES.to_h do |column, quantile|
        weighted = early.size * Statistics.calculate_percentile(early, quantile) +
          late.size * Statistics.calculate_percentile(late, quantile)
        [ column, weighted / (early.size + late.size) ]
      end

      assert_equal expected.size, expected.values.uniq.size, "percentiles under test should all differ"
      expected.each do |column, value|
        # MySQL stores the summaries' float columns in single precision.
        assert_in_delta value, day.public_send(column), 0.01, column
      end
    end

    test "a day's query and job rows are rolled up from their hours" do
      query = rails_pulse_queries(:simple_query)
      job = rails_pulse_jobs(:report_job)
      operation_at(@day + 1.hour, 10, query)
      operation_at(@day + 3.hours, 30, query)
      job_run_at(@day + 1.hour, 200, job, "success")
      job_run_at(@day + 4.hours, 400, job, "failed")

      summarize("day", @day)
      query_day = summary("RailsPulse::Query", query.id, "day", @day)
      job_day = summary("RailsPulse::Job", job.id, "day", @day)

      assert_equal 2, query_day.count
      assert_in_delta 20.0, query_day.avg_duration
      assert_equal 2, job_day.count
      assert_equal 1, job_day.success_count
      assert_equal 1, job_day.error_count
    end

    test "a day's job metrics ignore runs without a recorded duration, as the hours do" do
      job = rails_pulse_jobs(:report_job)
      job_run_at(@day + 1.hour, 100, job, "success")
      job_run_at(@day + 1.hour, nil, job, "discarded")

      summarize("day", @day)
      job_day = summary("RailsPulse::Job", job.id, "day", @day)

      assert_equal 2, job_day.count
      assert_equal 1, job_day.error_count
      assert_in_delta 100.0, job_day.avg_duration
      assert_in_delta 100.0, job_day.p95_duration
    end

    test "a day's exception counts are the sums of its hours'" do
      with_exception_tracking do
        group = rails_pulse_exception_groups(:record_not_found)
        occurrence_at(@day + 1.hour, group)
        occurrence_at(@day + 1.hour, group)
        occurrence_at(@day + 7.hours, group)

        summarize("day", @day)

        assert_equal 3, summary("RailsPulse::ExceptionGroup", group.id, "day", @day).count
        assert_equal 3, summary("RailsPulse::ExceptionGroup", 0, "day", @day).count
      end
    end

    test "a week is rolled up from its days, including its last day" do
      week = @day
      sunday = week + 6.days
      travel_to Time.zone.parse("2024-03-12 12:00:00")
      request_at(week + 1.hour, 100)
      request_at(sunday + 23.hours, 300)

      # SummaryJob passes a Date for week periods.
      summarize("week", week.to_date)
      week_summary = summary("RailsPulse::Request", 0, "week", week)

      assert_equal 2, week_summary.count
      assert_in_delta 300.0, week_summary.max_duration
      assert_equal 7, RailsPulse::Summary.where(period_type: "day", summarizable_type: "RailsPulse::Request", summarizable_id: 0).count
    end

    # Structure Tests

    test "a day whose hours are already summarized does not read raw rows" do
      request_at(@day + 1.hour, 100)
      24.times { |hour| summarize("hour", @day + hour.hours) }
      raw_reads = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        raw_reads += 1 if payload[:sql] =~ /FROM .rails_pulse_(requests|operations|job_runs)./
      end

      summarize("day", @day)

      assert_equal 0, raw_reads
      assert_equal 1, summary("RailsPulse::Request", 0, "day", @day).count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "a day combines its hours in a single query however many routes and hours it has" do
      other_route = rails_pulse_routes(:api_posts)
      [ 1, 5, 9 ].each do |hour|
        request_at(@day + hour.hours, 100)
        request_at(@day + hour.hours, 200, route: other_route)
      end
      24.times { |hour| summarize("hour", @day + hour.hours) }
      combining_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        combining_queries += 1 if payload[:sql] =~ /FROM .rails_pulse_summaries..*GROUP BY/m
      end

      summarize("day", @day)

      assert_equal 1, combining_queries
      assert_equal 3, summary("RailsPulse::Route", other_route.id, "day", @day).count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "an hour reads each kind of raw row with one query however many routes it has" do
      other_route = rails_pulse_routes(:api_posts)
      request_at(@day, 100)
      request_at(@day, 300, route: other_route)
      request_at(@day, 200, route: other_route)
      request_reads = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        request_reads += 1 if payload[:sql] =~ /FROM .rails_pulse_requests./
      end

      summarize("hour", @day)

      # One read serves the overall row and every route's.
      assert_equal 1, request_reads
      route_summary = summary("RailsPulse::Route", other_route.id, "hour", @day)

      assert_in_delta 200.0, route_summary.min_duration
      assert_in_delta 300.0, route_summary.max_duration
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "a day stays correct after its raw rows have been pruned" do
      request_at(@day + 1.hour, 100)
      request_at(@day + 2.hours, 200)
      24.times { |hour| summarize("hour", @day + hour.hours) }
      RailsPulse::Request.delete_all

      summarize("day", @day)

      assert_equal 2, summary("RailsPulse::Request", 0, "day", @day).count
    end

    test "a day summarizes its hours that were never summarized" do
      request_at(@day + 1.hour, 100)
      request_at(@day + 20.hours, 200)

      summarize("day", @day)

      assert_equal 24, RailsPulse::Summary.where(period_type: "hour", summarizable_type: "RailsPulse::Request", summarizable_id: 0).count
      assert_equal 2, summary("RailsPulse::Request", 0, "day", @day).count
    end

    test "hour rows that do not start on the day's hour boundaries are ignored" do
      request_at(@day + 1.hour, 100)
      RailsPulse::Summary.create!(
        summarizable_type: "RailsPulse::Request", summarizable_id: 0, period_type: "hour",
        period_start: @day + 90.minutes, period_end: @day + 150.minutes, count: 50
      )

      summarize("day", @day)

      assert_equal 1, summary("RailsPulse::Request", 0, "day", @day).count
    end

    # Edge Cases

    test "an empty day still writes its overall heartbeat row with count 0" do
      summarize("day", @day)
      day = summary("RailsPulse::Request", 0, "day", @day)

      assert_equal 0, day.count
      assert_nil day.p95_duration
      assert_nil day.stddev_duration
    end

    test "a day with a single request has no standard deviation" do
      request_at(@day + 1.hour, 100)

      summarize("day", @day)

      assert_nil summary("RailsPulse::Request", 0, "day", @day).stddev_duration
    end

    test "re-running a day overwrites rather than duplicates" do
      request_at(@day + 1.hour, 100)
      summarize("day", @day)

      assert_no_difference -> { RailsPulse::Summary.count } do
        summarize("day", @day)
      end
    end

    private

    def summarize(period_type, start)
      SummaryService.new(period_type, start).perform
    end

    def summary(type, id, period_type, period_start)
      RailsPulse::Summary.find_by!(
        summarizable_type: type, summarizable_id: id,
        period_type: period_type, period_start: period_start
      )
    end

    def request_at(time, duration, status: 200, route: @route)
      RailsPulse::Request.create!(
        route: route, duration: duration, status: status,
        request_uuid: SecureRandom.uuid, occurred_at: time + 1.minute
      )
    end

    def operation_at(time, duration, query)
      RailsPulse::Operation.create!(
        request: request_at(time, duration), query: query, operation_type: "sql", label: query.normalized_sql,
        duration: duration, occurred_at: time + 1.minute
      )
    end

    def job_run_at(time, duration, job, status)
      RailsPulse::JobRun.create!(
        job: job, run_id: SecureRandom.uuid, status: status,
        duration: duration, occurred_at: time + 1.minute
      )
    end

    def occurrence_at(time, group)
      RailsPulse::ExceptionOccurrence.create!(
        exception_group: group, exception_class: group.exception_class,
        message: "boom", occurred_at: time + 1.minute
      )
    end

    def with_exception_tracking
      original = RailsPulse.configuration.track_exceptions
      RailsPulse.configuration.track_exceptions = true
      yield
    ensure
      RailsPulse.configuration.track_exceptions = original
    end
  end
end
