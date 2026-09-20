require "test_helper"

class RailsPulse::SummaryTest < ActiveSupport::TestCase
  include Shoulda::Matchers::ActiveModel
  include Shoulda::Matchers::ActiveRecord

  # Test associations
  test "should have correct associations" do
    assert belong_to(:summarizable).optional.matches?(RailsPulse::Summary.new)
    assert belong_to(:route).optional.matches?(RailsPulse::Summary.new)
    assert belong_to(:query).optional.matches?(RailsPulse::Summary.new)
    assert belong_to(:job).optional.matches?(RailsPulse::Summary.new)
  end

  # Test validations
  test "should have correct validations" do
    summary = RailsPulse::Summary.new

    # Inclusion validation
    assert validate_inclusion_of(:period_type).in_array(RailsPulse::Summary::PERIOD_TYPES).matches?(summary)

    # Presence validations
    assert validate_presence_of(:period_start).matches?(summary)
    assert validate_presence_of(:period_end).matches?(summary)
  end

  test "should be valid with required attributes" do
    summary = rails_pulse_summaries(:route_summary_1)

    assert_predicate summary, :valid?
  end

  test "should have correct period types constant" do
    expected_types = %w[hour day week month]

    assert_equal expected_types, RailsPulse::Summary::PERIOD_TYPES
  end

  test "should include ransackable attributes" do
    expected_attributes = %w[
      period_start period_end avg_duration min_duration max_duration p95_duration p99_duration
      count error_count requests_per_minute error_rate_percentage
      route_path route_controller_action route_methods_sort
      execution_count total_time_consumed normalized_sql
      summarizable_id summarizable_type
    ]

    assert_equal expected_attributes.sort, RailsPulse::Summary.ransackable_attributes.sort
  end

  test "should include ransackable associations" do
    expected_associations = %w[job query route]

    assert_equal expected_associations.sort, RailsPulse::Summary.ransackable_associations.sort
  end

  test "should have scopes" do
    # Test for_period_type scope with fixture data
    hour_summary = rails_pulse_summaries(:route_summary_1)  # hour type
    query_summary = rails_pulse_summaries(:query_summary_1)  # day type

    hour_summaries = RailsPulse::Summary.for_period_type("hour")

    assert_includes hour_summaries, hour_summary
    assert_not_includes hour_summaries, query_summary

    # Test for_routes scope
    route_summaries = RailsPulse::Summary.for_routes

    assert_includes route_summaries, hour_summary
    assert_not_includes route_summaries, query_summary

    # Test for_queries scope
    query_summaries = RailsPulse::Summary.for_queries

    assert_includes query_summaries, query_summary
    assert_not_includes query_summaries, hour_summary

    # Test recent scope works (ordering)
    assert_respond_to RailsPulse::Summary, :recent
  end

  test "should work with polymorphic associations" do
    route_summary = rails_pulse_summaries(:route_summary_1)
    query_summary = rails_pulse_summaries(:query_summary_1)

    assert_equal rails_pulse_routes(:api_users), route_summary.summarizable
    assert_equal rails_pulse_queries(:complex_query), query_summary.summarizable
    assert_equal "RailsPulse::Route", route_summary.summarizable_type
    assert_equal "RailsPulse::Query", query_summary.summarizable_type
  end

  test "should calculate period end correctly" do
    time = Time.parse("2024-01-15 14:30:00 UTC")

    assert_equal time.end_of_hour, RailsPulse::Summary.calculate_period_end("hour", time)
    assert_equal time.end_of_day, RailsPulse::Summary.calculate_period_end("day", time)
    assert_equal time.end_of_week, RailsPulse::Summary.calculate_period_end("week", time)
    assert_equal time.end_of_month, RailsPulse::Summary.calculate_period_end("month", time)
  end

  test "should normalize period start correctly" do
    time = Time.parse("2024-01-15 14:30:00 UTC")

    assert_equal time.beginning_of_hour, RailsPulse::Summary.normalize_period_start("hour", time)
    assert_equal time.beginning_of_day, RailsPulse::Summary.normalize_period_start("day", time)
    assert_equal time.beginning_of_week, RailsPulse::Summary.normalize_period_start("week", time)
    assert_equal time.beginning_of_month, RailsPulse::Summary.normalize_period_start("month", time)
  end

  test "should order by recent scope" do
    recent_summaries = RailsPulse::Summary.recent

    # Should return summaries ordered by period_start DESC
    assert_operator recent_summaries.count, :>, 0

    # Verify scope exists and is callable
    assert_respond_to RailsPulse::Summary, :recent
  end

  # Tag filtering tests
  test "with_tag_filters should return all summaries when no filters applied" do
    all_count = RailsPulse::Summary.count
    filtered_count = RailsPulse::Summary.with_tag_filters([], true).count

    assert_equal all_count, filtered_count
  end

  test "with_tag_filters applies the tag filter inside the summary query rather than plucking ids first" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end

    RailsPulse::Summary.with_tag_filters([ "api" ], false).count

    assert_equal 1, statements.size, statements.join("\n")
    assert_match(/IN \(SELECT/, statements.first)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "with_tag_filters should exclude routes with disabled tags" do
    # api_users has ["api", "users"], api_posts has ["api", "posts"]
    route_summary = rails_pulse_summaries(:route_summary_1)  # links to api_users route

    # When "api" tag is disabled, should exclude summaries for routes with "api" tag
    filtered = RailsPulse::Summary.with_tag_filters([ "api" ], true)
      .where(summarizable_type: "RailsPulse::Route")

    assert_not_includes filtered, route_summary
  end

  test "with_tag_filters should exclude queries with disabled tags" do
    # simple_query has ["database", "users"]
    query_summary = rails_pulse_summaries(:query_summary_1)  # links to complex_query

    # When "database" tag is disabled, should exclude summaries for queries with "database" tag
    filtered = RailsPulse::Summary.with_tag_filters([ "database" ], true)
      .where(summarizable_type: "RailsPulse::Query")

    assert_not_includes filtered, query_summary
  end

  test "with_tag_filters should exclude non-tagged items when show_non_tagged is false" do
    # api_other has tags: '[]'
    # Create a summary for a non-tagged route
    non_tagged_route = rails_pulse_routes(:api_other)
    non_tagged_summary = RailsPulse::Summary.create!(
      summarizable: non_tagged_route,
      summarizable_type: "RailsPulse::Route",
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    # When show_non_tagged is false, should exclude non-tagged items
    filtered = RailsPulse::Summary.with_tag_filters([], false)
      .where(summarizable_type: "RailsPulse::Route")

    assert_not_includes filtered, non_tagged_summary
  end

  test "with_tag_filters should include non-tagged items when show_non_tagged is true" do
    # api_other has tags: '[]'
    non_tagged_route = rails_pulse_routes(:api_other)
    non_tagged_summary = RailsPulse::Summary.create!(
      summarizable: non_tagged_route,
      summarizable_type: "RailsPulse::Route",
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    # When show_non_tagged is true, should include non-tagged items
    filtered = RailsPulse::Summary.with_tag_filters([], true)
      .where(summarizable_type: "RailsPulse::Route")

    assert_includes filtered, non_tagged_summary
  end

  test "with_tag_filters should always include Request summaries" do
    # Create a Request summary
    request_summary = RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Request",
      summarizable_id: 0,
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    # Request summaries should always be included regardless of tag filters
    filtered = RailsPulse::Summary.with_tag_filters([ "api" ], false)

    assert_includes filtered, request_summary
  end

  test "with_tag_filters should handle non_tagged virtual tag correctly" do
    # "non_tagged" is a virtual tag that doesn't exist in the database
    # It should be filtered out and handled specially
    filtered = RailsPulse::Summary.with_tag_filters([ "non_tagged" ], false)

    # Should not error and should filter based on show_non_tagged parameter
    assert_kind_of ActiveRecord::Relation, filtered
  end

  test "with_tag_filters should handle multiple disabled tags" do
    # When multiple tags are disabled, should exclude all summaries with any of those tags
    route_summary = rails_pulse_summaries(:route_summary_1)  # links to api_users with tags ["api", "users"]

    # Disable both "api" and "users"
    filtered = RailsPulse::Summary.with_tag_filters([ "api", "users" ], true)
      .where(summarizable_type: "RailsPulse::Route")

    assert_not_includes filtered, route_summary
  end

  test "with_tag_filters should handle empty result arrays from tag filtering" do
    # When all items are filtered out, should still work (using -1 as impossible ID)
    filtered = RailsPulse::Summary.with_tag_filters([ "nonexistent_tag_that_filters_everything" ], false)

    # Should return a valid relation (may be empty)
    assert_kind_of ActiveRecord::Relation, filtered
  end

  test "with_tag_filters should handle non_tagged in disabled_tags list" do
    # When "non_tagged" is in disabled_tags, it should be filtered out and not cause errors
    filtered = RailsPulse::Summary.with_tag_filters([ "non_tagged", "api" ], true)

    # Should work without errors
    assert_kind_of ActiveRecord::Relation, filtered
  end

  # Scope Tests

  test "by_job_name scope should filter summaries by job name" do
    # Create a job and job summary
    job = RailsPulse::Job.create!(
      name: "TestJob",
      queue_name: "default",
      runs_count: 1,
      failures_count: 0
    )

    job_summary = RailsPulse::Summary.create!(
      summarizable: job,
      summarizable_type: "RailsPulse::Job",
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    # Filter by job name
    filtered = RailsPulse::Summary.by_job_name("TestJob")

    assert_includes filtered, job_summary
  end

  test "by_job_name scope should not include summaries for other jobs" do
    # Create two jobs
    job1 = RailsPulse::Job.create!(
      name: "Job1",
      queue_name: "default",
      runs_count: 1,
      failures_count: 0
    )

    job2 = RailsPulse::Job.create!(
      name: "Job2",
      queue_name: "default",
      runs_count: 1,
      failures_count: 0
    )

    job1_summary = RailsPulse::Summary.create!(
      summarizable: job1,
      summarizable_type: "RailsPulse::Job",
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    job2_summary = RailsPulse::Summary.create!(
      summarizable: job2,
      summarizable_type: "RailsPulse::Job",
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 200,
      min_duration: 100,
      max_duration: 300,
      count: 5,
      error_count: 0,
      success_count: 5
    )

    # Filter by Job1 name
    filtered = RailsPulse::Summary.by_job_name("Job1")

    assert_includes filtered, job1_summary
    assert_not_includes filtered, job2_summary
  end

  test "overall_requests scope should return only Request summaries with ID 0" do
    # Create an overall request summary (summarizable_id = 0)
    overall_summary = RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Request",
      summarizable_id: 0,
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    # Create a regular request summary (not ID 0)
    regular_summary = RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Request",
      summarizable_id: 1,
      period_type: "hour",
      period_start: 1.hour.ago,
      period_end: Time.current,
      avg_duration: 200,
      min_duration: 100,
      max_duration: 300,
      count: 5,
      error_count: 0,
      success_count: 5
    )

    filtered = RailsPulse::Summary.overall_requests

    assert_includes filtered, overall_summary
    assert_not_includes filtered, regular_summary
  end

  test "overall_requests scope should not include non-Request summaries" do
    # Create a route summary
    route_summary = rails_pulse_summaries(:route_summary_1)

    filtered = RailsPulse::Summary.overall_requests

    assert_not_includes filtered, route_summary
  end

  test "for_date_range scope should filter by date range" do
    start_date = 2.days.ago
    end_date = 1.day.ago

    # Create summaries within and outside the range
    within_range = RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Request",
      summarizable_id: 0,
      period_type: "hour",
      period_start: 1.5.days.ago,
      period_end: 1.day.ago,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    outside_range = RailsPulse::Summary.create!(
      summarizable_type: "RailsPulse::Request",
      summarizable_id: 0,
      period_type: "hour",
      period_start: 5.days.ago,
      period_end: 4.days.ago,
      avg_duration: 100,
      min_duration: 50,
      max_duration: 150,
      count: 10,
      error_count: 0,
      success_count: 10
    )

    filtered = RailsPulse::Summary.for_date_range(start_date, end_date)

    assert_includes filtered, within_range
    assert_not_includes filtered, outside_range
  end
end
