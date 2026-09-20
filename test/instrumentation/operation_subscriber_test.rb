require "test_helper"

class OperationSubscriberTest < ActiveSupport::TestCase
  def setup
    # Use existing fixture data
    @request = rails_pulse_requests(:users_request_1)

    # Setup request context for operation tracking
    RequestStore.store[:rails_pulse_request_id] = @request.id
    RequestStore.store[:rails_pulse_job_run_id] = nil
    RequestStore.store[:rails_pulse_operations] = []

    @original_capture_actual_sql = RailsPulse.configuration.capture_actual_sql
    RailsPulse.configuration.capture_actual_sql = true

    super
  end

  def teardown
    RailsPulse.configuration.capture_actual_sql = @original_capture_actual_sql
    RequestStore.clear!
    super
  end


  test "subscriber module should exist" do
    assert defined?(RailsPulse::Subscribers::OperationSubscriber)
    assert_respond_to RailsPulse::Subscribers::OperationSubscriber, :subscribe!
  end

  test "should capture SQL operations" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load"
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.01) # Ensure measurable duration
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users WHERE id = ?", operation[:actual_sql]
    assert_nil operation[:label]
    assert_operator operation[:duration], :>=, 0, "Duration should be non-negative, got: #{operation[:duration]}"
    assert_equal @request.id, operation[:request_id]
  end

  test "should filter out schema SQL queries" do
    schema_queries = [
      { sql: "SHOW FULL FIELDS FROM `users`", name: "SCHEMA" },
      { sql: "SELECT sql FROM sqlite_master", name: "SCHEMA" },
      { sql: "PRAGMA table_info(`users`)", name: "SCHEMA" }
    ]

    schema_queries.each do |payload|
      ActiveSupport::Notifications.instrument("sql.active_record", payload) do
        sleep(0.001)
      end
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size, "Schema queries should be filtered out"
  end

  test "should filter out RailsPulse SQL queries" do
    payload = {
      sql: "SELECT * FROM rails_pulse_requests WHERE id = ?",
      name: "RailsPulse::Request Load"
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size, "RailsPulse queries should be filtered out"
  end

  test "should filter out cached SQL queries" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load",
      cached: true
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size, "Cached queries should be filtered out"
  end

  test "should capture uncached SQL queries with cached false" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load",
      cached: false
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size
  end

  test "should filter out queries matching a string ignored_queries pattern" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ "SELECT 1" ]

    payload = { sql: "SELECT 1", name: "SQL" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size, "Queries matching an ignored_queries string should be filtered out"
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should filter out queries matching a regexp ignored_queries pattern" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ %r{FROM \"?schema_migrations\"?} ]

    payload = { sql: "SELECT * FROM \"schema_migrations\"", name: "SQL" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size, "Queries matching an ignored_queries regexp should be filtered out"
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should not filter queries that do not match ignored_queries patterns" do
    original = RailsPulse.configuration.ignored_queries
    RailsPulse.configuration.ignored_queries = [ "SELECT 1" ]

    payload = { sql: "SELECT * FROM users", name: "User Load" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size
  ensure
    RailsPulse.configuration.ignored_queries = original
  end

  test "should capture template rendering operations" do
    payload = {
      identifier: "/app/views/users/show.html.erb"
    }

    ActiveSupport::Notifications.instrument("render_template.action_view", payload) do
      sleep(0.01)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "template", operation[:operation_type]
    assert_equal "/app/views/users/show.html.erb", operation[:label]
    assert_operator operation[:duration], :>=, 0
  end

  test "should capture controller action operations" do
    payload = {
      controller: "UsersController",
      action: "show"
    }

    ActiveSupport::Notifications.instrument("process_action.action_controller", payload) do
      sleep(0.01)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "controller", operation[:operation_type]
    assert_equal "UsersController#show", operation[:label]
    assert_operator operation[:duration], :>=, 0
  end

  test "duration is clamped to zero when finish precedes start due to time travel mid-request" do
    # A host-app test that calls Timecop.freeze or travel_to after a page visit
    # but while an in-flight AJAX request is still being handled can cause the
    # process_action.action_controller notification to capture start at real
    # wall-clock time and finish at the frozen (past) time. With finish < start,
    # (finish - start) * 1000 produces a value like -99,732,412,858 ms (~3 years),
    # which overflows the duration column's numeric(15, 6) constraint (max ~10^9).
    real_time = Time.current
    past_time = real_time - 3.years

    payload = { controller: "UsersController", action: "index" }

    RailsPulse::Subscribers::OperationSubscriber.send(
      :capture_operation,
      "process_action.action_controller",
      real_time,
      past_time,
      payload,
      "controller",
      :controller
    )

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_not_nil operation
    assert_operator operation[:duration], :>=, 0,
      "Duration was #{operation[:duration]}ms — must be clamped to zero when " \
      "finish precedes start (clock moved backward via time travel mid-request)"
  end

  test "should capture partial rendering operations" do
    payload = {
      identifier: "/app/views/users/_user.html.erb"
    }

    ActiveSupport::Notifications.instrument("render_partial.action_view", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "partial", operation[:operation_type]
    assert_equal "/app/views/users/_user.html.erb", operation[:label]
  end

  test "should capture cache operations" do
    payload = {
      key: "user/123/profile"
    }

    ActiveSupport::Notifications.instrument("cache_read.active_support", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "cache_read", operation[:operation_type]
    assert_equal "user/123/profile", operation[:label]
  end

  test "should capture operations with proper metadata" do
    payload = {
      sql: "SELECT * FROM users WHERE id = ?",
      name: "User Load"
    }

    start_time = Time.current
    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.01)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users WHERE id = ?", operation[:actual_sql]
    assert_nil operation[:label]
    assert_operator operation[:duration], :>=, 0
    assert_equal @request.id, operation[:request_id]
    assert_kind_of Float, operation[:start_time]
    assert_operator operation[:occurred_at], :>=, start_time
    assert_kind_of Time, operation[:occurred_at]
  end

  test "should not capture operations without request context" do
    RequestStore.store[:rails_pulse_request_id] = nil
    RequestStore.store[:rails_pulse_job_run_id] = nil

    payload = {
      sql: "SELECT * FROM users",
      name: "User Load"
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 0, operations.size
  end

  test "should capture operations for background job context" do
    job_run = rails_pulse_job_runs(:mailer_run_success)

    RequestStore.store[:rails_pulse_request_id] = nil
    RequestStore.store[:rails_pulse_job_run_id] = job_run.id
    RequestStore.store[:rails_pulse_operations] = []

    payload = { sql: "SELECT 1", name: "Job SQL" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size
    assert_nil operations.first[:request_id]
    assert_equal job_run.id, operations.first[:job_run_id]
  end

  test "should clean SQL labels by removing Rails comments" do
    payload = {
      sql: "/*action='search',application='Dummy',controller='home'*/ SELECT * FROM users",
      name: "User Load"
    }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_not_empty operations, "Expected SQL operation to be captured"
    assert_equal "SELECT * FROM users", operations.first[:actual_sql]
    assert_nil operations.first[:label]
  end

  test "should handle HTTP client operations" do
    payload = {
      method: "GET",
      uri: "https://api.example.com/users"
    }

    ActiveSupport::Notifications.instrument("request.net_http", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "http", operation[:operation_type]
    assert_equal "GET https://api.example.com/users", operation[:label]
  end

  test "does not record HTTP operations while Rails Pulse activity is suppressed" do
    RequestStore.store[:skip_recording_rails_pulse_activity] = true

    ActiveSupport::Notifications.instrument("request.net_http", method: "GET", uri: "https://api.example.com/users") { }

    assert_empty RequestStore.store[:rails_pulse_operations]
  ensure
    RequestStore.store[:skip_recording_rails_pulse_activity] = false
  end

  test "should handle Active Job operations" do
    job_class = Class.new do
      def self.name
        "TestJob"
      end
    end

    payload = {
      job: job_class.new
    }

    ActiveSupport::Notifications.instrument("perform.active_job", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size

    operation = operations.first

    assert_equal "job", operation[:operation_type]
    assert_equal "TestJob", operation[:label]
  end

  test "should handle exceptions gracefully" do
    # The subscriber should handle nil SQL gracefully and still capture it
    payload = { sql: nil, name: "User Load" }

    assert_nothing_raised do
      ActiveSupport::Notifications.instrument("sql.active_record", payload) do
        sleep(0.001)
      end
    end

    # Should have captured the operation even with nil SQL
    operations = RequestStore.store[:rails_pulse_operations]

    assert_equal 1, operations.size
    operation = operations.first

    assert_nil operation[:actual_sql]
    assert_nil operation[:label]
  end

  test "should capture start time and occurred_at" do
    payload = {
      sql: "SELECT * FROM users",
      name: "User Load"
    }

    start_time = Time.current
    ActiveSupport::Notifications.instrument("sql.active_record", payload) do
      sleep(0.001)
    end

    operations = RequestStore.store[:rails_pulse_operations]
    operation = operations.first

    assert_kind_of Float, operation[:start_time]
    assert_kind_of Time, operation[:occurred_at]
    assert_operator operation[:occurred_at], :>=, start_time
  end

  # row_count Tests

  test "captures row_count from SQL payload" do
    payload = { sql: "SELECT * FROM users", name: "User Load", row_count: 42 }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal 42, operation[:row_count]
  end

  test "row_count is nil when not present in SQL payload" do
    payload = { sql: "SELECT * FROM users", name: "User Load" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_nil operation[:row_count]
  end

  test "row_count zero is captured correctly" do
    payload = { sql: "SELECT * FROM users WHERE id = 99999", name: "User Load", row_count: 0 }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal 0, operation[:row_count]
  end

  test "non-SQL operations do not have row_count" do
    payload = { identifier: "/app/views/users/index.html.erb" }

    ActiveSupport::Notifications.instrument("render_template.action_view", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal "template", operation[:operation_type]
    assert_nil operation[:row_count]
  end

  # cache_hit Tests

  test "captures cache_hit true when cache read hits" do
    payload = { key: "users/count", hit: true }

    ActiveSupport::Notifications.instrument("cache_read.active_support", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal "cache_read", operation[:operation_type]
    assert operation[:cache_hit]
  end

  test "captures cache_hit false when cache read misses" do
    payload = { key: "users/count", hit: false }

    ActiveSupport::Notifications.instrument("cache_read.active_support", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    refute operation[:cache_hit]
  end

  test "cache_hit is nil when not present in cache_read payload" do
    payload = { key: "users/count" }

    ActiveSupport::Notifications.instrument("cache_read.active_support", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_nil operation[:cache_hit]
  end

  test "cache_write operations do not have cache_hit" do
    payload = { key: "users/count" }

    ActiveSupport::Notifications.instrument("cache_write.active_support", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal "cache_write", operation[:operation_type]
    assert_nil operation[:cache_hit]
  end

  # extra: merge Tests

  test "extra data is merged into operation for SQL" do
    payload = { sql: "SELECT 1", name: "Test", row_count: 5 }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal 5, operation[:row_count]
    assert_equal "sql", operation[:operation_type]
    assert_operator operation[:duration], :>=, 0
  end

  test "extra data does not overwrite core operation fields" do
    original = RailsPulse.configuration.capture_actual_sql
    RailsPulse.configuration.capture_actual_sql = true

    payload = { sql: "SELECT * FROM users", name: "User Load", row_count: 10 }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal "sql", operation[:operation_type]
    assert_equal "SELECT * FROM users", operation[:actual_sql]
    assert_nil operation[:label]
    assert_equal @request.id, operation[:request_id]
  ensure
    RailsPulse.configuration.capture_actual_sql = original
  end

  test "actual_sql is captured in memory even when capture_actual_sql is disabled" do
    original = RailsPulse.configuration.capture_actual_sql
    RailsPulse.configuration.capture_actual_sql = false

    payload = { sql: "SELECT * FROM users", name: "User Load" }

    ActiveSupport::Notifications.instrument("sql.active_record", payload) { sleep(0.001) }

    operation = RequestStore.store[:rails_pulse_operations].first

    assert_equal "sql", operation[:operation_type]
    # actual_sql is always captured in memory (needed for query normalization
    # in Operation.persist_bulk). It is cleared at persistence time when
    # capture_actual_sql is false.
    assert_equal "SELECT * FROM users", operation[:actual_sql]
  ensure
    RailsPulse.configuration.capture_actual_sql = original
  end
end
