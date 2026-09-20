require "test_helper"

class RailsPulse::Middleware::RequestCollectorTest < ActiveSupport::TestCase
  def setup
    @collector = RailsPulse::Middleware::RequestCollector.new(->(_env) { [ 200, {}, [] ] })
  end

  # detect_n_plus_one Tests

  test "flags repeated SQL operations with repetition_count and group" do
    ops = [
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 2" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 3" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    ops.each do |op|
      assert_equal 3, op[:repetition_count]
      assert_not_nil op[:repeated_query_group]
    end
  end

  test "repeated_query_group contains normalized SQL" do
    ops = [
      { operation_type: "sql", actual_sql: "SELECT * FROM posts WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM posts WHERE id = 2" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    group = ops.first[:repeated_query_group]

    assert_not_nil group
    assert_includes group, "posts"
    assert_equal ops.first[:repeated_query_group], ops.last[:repeated_query_group]
  end

  test "does not flag unique SQL operations" do
    ops = [
      { operation_type: "sql", actual_sql: "SELECT * FROM users" },
      { operation_type: "sql", actual_sql: "SELECT * FROM posts" },
      { operation_type: "sql", actual_sql: "SELECT COUNT(*) FROM comments" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    ops.each do |op|
      assert_nil op[:repetition_count]
      assert_nil op[:repeated_query_group]
    end
  end

  test "does not flag operations when fewer than 2 SQL ops total" do
    ops = [ { operation_type: "sql", actual_sql: "SELECT * FROM users" } ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    assert_nil ops.first[:repetition_count]
  end

  test "does not modify non-SQL operations" do
    ops = [
      { operation_type: "template", label: "app/views/users/index.html.erb" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 2" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    template_op = ops.first

    assert_nil template_op[:repetition_count]
    assert_nil template_op[:repeated_query_group]
  end

  test "handles mixed repeated and unique SQL operations" do
    ops = [
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 2" },
      { operation_type: "sql", actual_sql: "SELECT COUNT(*) FROM posts" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    assert_equal 2, ops[0][:repetition_count]
    assert_equal 2, ops[1][:repetition_count]
    assert_nil ops[2][:repetition_count]
  end

  test "handles empty operations array" do
    assert_nothing_raised { RailsPulse::Tracker.detect_n_plus_one([]) }
  end

  test "handles operations with nil actual_sql" do
    ops = [
      { operation_type: "sql", actual_sql: nil },
      { operation_type: "sql", actual_sql: nil }
    ]

    assert_nothing_raised { RailsPulse::Tracker.detect_n_plus_one(ops) }

    assert_equal 2, ops.first[:repetition_count]
  end

  test "groups queries from different tables separately" do
    ops = [
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM users WHERE id = 2" },
      { operation_type: "sql", actual_sql: "SELECT * FROM posts WHERE id = 1" },
      { operation_type: "sql", actual_sql: "SELECT * FROM posts WHERE id = 2" }
    ]

    RailsPulse::Tracker.detect_n_plus_one(ops)

    assert_equal 2, ops[0][:repetition_count]
    assert_equal 2, ops[2][:repetition_count]
    refute_equal ops[0][:repeated_query_group], ops[2][:repeated_query_group]
  end

  # response_size_bytes Tests

  test "returns Content-Length header as integer when present" do
    headers = { "Content-Length" => "1234" }
    response = Object.new

    result = @collector.send(:response_size_bytes, headers, response)

    assert_equal 1234, result
  end

  test "falls back to body bytesize when Content-Length absent" do
    headers = {}
    response = double_response("hello world")

    result = @collector.send(:response_size_bytes, headers, response)

    assert_equal 11, result
  end

  test "returns nil when neither Content-Length nor string body available" do
    headers = {}
    response = Object.new

    result = @collector.send(:response_size_bytes, headers, response)

    assert_nil result
  end

  test "returns nil when response body is not a string" do
    headers = {}
    response = double_response([ "chunk1", "chunk2" ])

    result = @collector.send(:response_size_bytes, headers, response)

    assert_nil result
  end

  test "prefers Content-Length over body bytesize" do
    headers = { "Content-Length" => "999" }
    response = double_response("hello")

    result = @collector.send(:response_size_bytes, headers, response)

    assert_equal 999, result
  end

  test "returns nil on error" do
    headers = {}
    response = Object.new
    response.define_singleton_method(:body) { raise "unexpected error" }

    result = @collector.send(:response_size_bytes, headers, response)

    assert_nil result
  end

  test "handles multibyte body correctly" do
    headers = {}
    body = "héllo"
    response = double_response(body)

    result = @collector.send(:response_size_bytes, headers, response)

    assert_equal body.bytesize, result
  end

  private

  def double_response(body)
    obj = Object.new
    obj.define_singleton_method(:body) { body }
    obj
  end
end
