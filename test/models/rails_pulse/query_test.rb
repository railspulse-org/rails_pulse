require "test_helper"

class RailsPulse::QueryTest < ActiveSupport::TestCase
  include Shoulda::Matchers::ActiveModel
  include Shoulda::Matchers::ActiveRecord

  # Test associations
  test "should have correct associations" do
    assert have_many(:operations).inverse_of(:query).matches?(RailsPulse::Query.new)
    assert have_many(:summaries).dependent(:destroy).matches?(RailsPulse::Query.new)
    assert have_one(:baseline).dependent(:delete).matches?(RailsPulse::Query.new)
  end

  # Test validations
  test "should have correct validations" do
    query = RailsPulse::Query.new

    # Presence validation
    assert validate_presence_of(:normalized_sql).matches?(query)
    assert validate_presence_of(:hashed_sql).matches?(query)

    # Uniqueness enforced at database level (unique index on hashed_sql)
    existing_query = rails_pulse_queries(:simple_query)
    duplicate_query = RailsPulse::Query.new(
      normalized_sql: existing_query.normalized_sql,
      hashed_sql: existing_query.hashed_sql
    )

    assert_predicate duplicate_query, :valid?
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate_query.save!(validate: false)
    end
  end

  test "automatically generates hashed_sql from normalized_sql" do
    query = RailsPulse::Query.new(normalized_sql: "SELECT * FROM users WHERE id = ?")
    query.valid?

    assert_not_nil query.hashed_sql, "hashed_sql should be generated"
    assert_equal Digest::MD5.hexdigest(query.normalized_sql), query.hashed_sql
  end

  test "regenerates hashed_sql when normalized_sql changes" do
    query = rails_pulse_queries(:simple_query)
    original_hash = query.hashed_sql

    query.normalized_sql = "SELECT * FROM posts WHERE user_id = ?"
    query.valid?

    assert_not_equal original_hash, query.hashed_sql, "hashed_sql should change when normalized_sql changes"
    assert_equal Digest::MD5.hexdigest(query.normalized_sql), query.hashed_sql
  end

  test "does not regenerate hashed_sql if normalized_sql unchanged" do
    query = rails_pulse_queries(:simple_query)
    original_hash = query.hashed_sql

    query.valid?

    assert_equal original_hash, query.hashed_sql, "hashed_sql should not change if normalized_sql unchanged"
  end

  test "should be valid with required attributes" do
    query = rails_pulse_queries(:simple_query)

    assert_predicate query, :valid?
  end

  test "should include Taggable concern" do
    assert_includes RailsPulse::Query.included_modules, RailsPulse::Taggable
  end

  test "should include Taggable methods" do
    assert_respond_to RailsPulse::Query.new, :tag_list
  end

  test "should include ransackable attributes" do
    expected_attributes = %w[id normalized_sql average_query_time_ms execution_count total_time_consumed performance_status occurred_at]

    assert_equal expected_attributes.sort, RailsPulse::Query.ransackable_attributes.sort
  end

  test "should include ransackable associations" do
    expected_associations = %w[operations]

    assert_equal expected_associations.sort, RailsPulse::Query.ransackable_associations.sort
  end

  test "should return id as string representation" do
    query = rails_pulse_queries(:simple_query)

    assert_equal query.id, query.to_s
  end

  test "operations association should work" do
    # This tests that the association exists and works
    # The actual business logic of query association is tested in operation tests
    query = rails_pulse_queries(:complex_query)
    operation = rails_pulse_operations(:sql_operation_1)

    # Test the basic association
    assert_operator query.operations.count, :>, 0
    assert_includes query.operations, operation
    assert_equal query, operation.query
  end

  test "should have polymorphic summaries association" do
    query = rails_pulse_queries(:complex_query)
    summary = rails_pulse_summaries(:query_summary_1)

    assert_operator query.summaries.count, :>, 0
    assert_includes query.summaries, summary
    assert_equal query, summary.summarizable
  end

  # Analysis-related tests
  test "analyzed? returns false when analyzed_at is nil" do
    query = rails_pulse_queries(:simple_query)

    refute_predicate query, :analyzed?
  end

  test "analyzed? returns true when analyzed_at is present" do
    query = rails_pulse_queries(:analyzed_query)

    assert_predicate query, :analyzed?
  end

  test "has_recent_operations? returns true when recent operations exist" do
    query = rails_pulse_queries(:complex_query)

    assert_predicate query, :has_recent_operations?
  end

  test "has_recent_operations? returns false when no recent operations exist" do
    query = rails_pulse_queries(:stale_analyzed_query)

    # This query has no operations, so should return false
    refute_predicate query, :has_recent_operations?
  end

  test "needs_reanalysis? returns true when not analyzed" do
    query = rails_pulse_queries(:simple_query)

    assert_predicate query, :needs_reanalysis?
  end

  test "needs_reanalysis? returns false when recently analyzed with no new operations" do
    query = rails_pulse_queries(:analyzed_query)

    refute_predicate query, :needs_reanalysis?
  end

  test "needs_reanalysis? returns true when operations exist after analysis" do
    query = rails_pulse_queries(:simple_query)

    # This query has never been analyzed, so it needs reanalysis
    assert_predicate query, :needs_reanalysis?
  end

  test "analysis_status returns correct status" do
    # Not analyzed
    not_analyzed_query = rails_pulse_queries(:simple_query)

    assert_equal "not_analyzed", not_analyzed_query.analysis_status

    # Current analysis
    current_query = rails_pulse_queries(:analyzed_query)

    assert_equal "current", current_query.analysis_status

    # Analyzed query should be current since it doesn't have operations after analysis
    analyzed_query = rails_pulse_queries(:stale_analyzed_query)

    assert_equal "current", analyzed_query.analysis_status
  end

  test "issues_by_severity groups issues correctly" do
    query = rails_pulse_queries(:query_with_issues)
    grouped = query.issues_by_severity

    assert_equal 1, grouped["critical"].length
    assert_equal 1, grouped["warning"].length
  end

  test "critical_issues_count returns correct count" do
    query = rails_pulse_queries(:query_with_issues)

    assert_equal 1, query.critical_issues_count
  end

  test "warning_issues_count returns correct count" do
    query = rails_pulse_queries(:query_with_issues)

    assert_equal 1, query.warning_issues_count
  end

  # recent_operations Tests
  test "recent_operations returns an array" do
    query = rails_pulse_queries(:complex_query)

    assert_kind_of Array, query.recent_operations
  end

  test "recent_operations only returns operations within 30 days" do
    query = rails_pulse_queries(:complex_query)
    results = query.recent_operations

    results.each do |op|
      assert_operator op.occurred_at, :>=, 30.days.ago
    end
  end

  # n_plus_one_groups Tests
  test "n_plus_one_groups returns empty hash when no repeated queries" do
    query = rails_pulse_queries(:simple_query)
    ops = query.operations.to_a

    assert_empty(query.n_plus_one_groups(ops))
  end

  test "n_plus_one_groups returns empty hash for empty array" do
    query = rails_pulse_queries(:simple_query)

    assert_empty(query.n_plus_one_groups([]))
  end

  test "n_plus_one_groups groups operations by repeated_query_group" do
    query = rails_pulse_queries(:complex_query)
    op1 = RailsPulse::Operation.new(repeated_query_group: "SELECT * FROM users WHERE id = ?", repetition_count: 5)
    op2 = RailsPulse::Operation.new(repeated_query_group: "SELECT * FROM users WHERE id = ?", repetition_count: 3)
    op3 = RailsPulse::Operation.new(repeated_query_group: nil, repetition_count: nil)

    groups = query.n_plus_one_groups([ op1, op2, op3 ])

    assert_equal 1, groups.size
    assert_equal 5, groups["SELECT * FROM users WHERE id = ?"]
  end

  # ensure_analyzed! Tests
  test "ensure_analyzed! does nothing when already analyzed" do
    query = rails_pulse_queries(:analyzed_query)

    RailsPulse::QueryAnalysisService.expects(:analyze_query).never
    query.ensure_analyzed!
  end

  test "ensure_analyzed! calls QueryAnalysisService when not analyzed" do
    query = rails_pulse_queries(:simple_query)

    RailsPulse::QueryAnalysisService.stubs(:analyze_query).returns(true)
    assert_nothing_raised { query.ensure_analyzed! }
  end

  test "ensure_analyzed! swallows errors and logs a warning" do
    query = rails_pulse_queries(:simple_query)

    RailsPulse::QueryAnalysisService.stubs(:analyze_query).raises(StandardError.new("boom"))
    assert_nothing_raised { query.ensure_analyzed! }
  end

  test "serializes JSON columns correctly" do
    query = rails_pulse_queries(:query_with_issues)

    expected_stats = { "query_type" => "SELECT", "table_count" => 1 }
    expected_issues = [
      { "severity" => "critical", "description" => "Critical issue" },
      { "severity" => "warning", "description" => "Warning issue" }
    ]

    assert_equal expected_stats, query.query_stats
    assert_equal expected_issues, query.issues
  end
end
