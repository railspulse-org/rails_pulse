require "test_helper"

class RailsPulse::TrackerTest < ActiveSupport::TestCase
  setup do
    # Clear RequestStore to avoid state leakage between tests
    RequestStore.store[:skip_recording_rails_pulse_activity] = false
    RailsPulse::Tracker.reset_writer!

    @tracking_data = {
      method: "GET",
      path: "/test-#{SecureRandom.hex(4)}",  # Unique path for each test
      duration: 150.0,
      status: 200,
      is_error: false,
      request_uuid: SecureRandom.uuid,
      controller_action: "UsersController#index",
      occurred_at: Time.current,
      operations: [
        {
          operation_type: "sql",
          duration: 50.0,
          label: "SELECT * FROM users",
          codebase_location: "app/models/user.rb:10",
          occurred_at: Time.current
        }
      ]
    }
  end

  test "creates request records" do
    RailsPulse::Tracker.track_request(@tracking_data)

    route = RailsPulse::Route.find_by(path: @tracking_data[:path])

    assert_not_nil route, "Route should be created"

    request = RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])

    assert_not_nil request, "Request should be created"
    assert_in_delta(150.0, request.duration)
    assert_equal 1, request.operations.count
  end

  test "handles errors gracefully" do
    RailsPulse::Route.stubs(:find_by).raises(StandardError, "DB Error")

    assert_nothing_raised do
      RailsPulse::Tracker.track_request(@tracking_data)
    end
  end

  test "healthy? returns true when database is connected" do
    assert_predicate RailsPulse::Tracker, :healthy?, "Tracker should be healthy when DB is connected"
  end

  test "healthy? returns false when database is disconnected" do
    RailsPulse::ApplicationRecord.connection.stubs(:execute).raises(ActiveRecord::ConnectionNotEstablished)

    refute_predicate RailsPulse::Tracker, :healthy?, "Tracker should be unhealthy when DB is disconnected"
    RailsPulse::ApplicationRecord.connection.unstub(:execute)
  end

  test "sets recursion prevention flag during tracking" do
    # Flag should be false before tracking
    refute RequestStore.store[:skip_recording_rails_pulse_activity]

    # Track a request
    RailsPulse::Tracker.track_request(@tracking_data)

    # Flag should be reset after tracking
    refute RequestStore.store[:skip_recording_rails_pulse_activity], "Flag should be reset after tracking"
  end

  test "handles concurrent requests with connection pooling" do
    base_path = "/concurrent-test-#{SecureRandom.hex(4)}"
    initial_count = RailsPulse::Request.count

    threads = 10.times.map do |i|
      Thread.new do
        data = @tracking_data.merge(
          request_uuid: "uuid-#{SecureRandom.hex(8)}-#{i}",
          path: "#{base_path}-#{i}"
        )
        RailsPulse::Tracker.track_request(data)
      end
    end

    threads.each(&:join)

    assert_equal initial_count + 10, RailsPulse::Request.count, "Should create 10 requests"
  end

  test "skips tracking when recursion flag is set" do
    RequestStore.store[:skip_recording_rails_pulse_activity] = true

    RailsPulse::Tracker.track_request(@tracking_data)

    # Should not create any records
    assert_nil RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])
  end

  test "async mode under a shared test connection still persists every request" do
    original_async = RailsPulse.configuration.async
    RailsPulse.configuration.async = true

    begin
      base_path = "/async-test-#{SecureRandom.hex(4)}"
      initial_count = RailsPulse::Request.count

      5.times do |i|
        data = @tracking_data.merge(
          request_uuid: "async-uuid-#{SecureRandom.hex(8)}-#{i}",
          path: "#{base_path}-#{i}"
        )
        RailsPulse::Tracker.track_request(data)
      end

      assert_equal initial_count + 5, RailsPulse::Request.count, "Should create 5 requests"
    ensure
      RailsPulse.configuration.async = original_async
    end
  end

  # use_transactional_tests pins this pool's connection and shares it with every
  # thread, so a background writer would race the test on the same socket.
  test "writes inline under a shared test connection even when async is enabled" do
    original_async = RailsPulse.configuration.async
    RailsPulse.configuration.async = true
    Thread.expects(:new).never

    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_kind_of RailsPulse::Request, result
    assert_not_nil RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])
  ensure
    RailsPulse.configuration.async = original_async
  end

  test "enqueues on the background writer when async is enabled and the connection is not shared" do
    original_async = RailsPulse.configuration.async
    RailsPulse.configuration.async = true
    RailsPulse::Tracker.stubs(:connection_shared_across_threads?).returns(false)
    Thread.expects(:new).once

    assert_nil RailsPulse::Tracker.track_request(@tracking_data)
    assert_equal 1, RailsPulse::Tracker.stats[:queue_size]
    assert_nil RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])
  ensure
    RailsPulse.configuration.async = original_async
    RailsPulse::Tracker.unstub(:connection_shared_across_threads?)
  end

  test "background writer drains the queue on its own thread" do
    original_async = RailsPulse.configuration.async
    RailsPulse.configuration.async = true
    RailsPulse::Tracker.stubs(:connection_shared_across_threads?).returns(false)

    3.times do |i|
      RailsPulse::Tracker.track_request(@tracking_data.merge(request_uuid: "writer-#{i}-#{SecureRandom.hex(4)}"))
    end
    RailsPulse::Tracker.flush!

    assert_equal 3, RailsPulse::Request.where("request_uuid LIKE 'writer-%'").count
    assert_equal 0, RailsPulse::Tracker.stats[:queue_size]
    assert_equal 0, RailsPulse::Tracker.stats[:dropped]
  ensure
    RailsPulse.configuration.async = original_async
    RailsPulse::Tracker.unstub(:connection_shared_across_threads?)
  end

  test "stats report zeros before the writer has been used" do
    assert_equal({ queue_size: 0, dropped: 0, running: false }, RailsPulse::Tracker.stats)
  end

  test "persists response_size_bytes to request record" do
    data = @tracking_data.merge(response_size_bytes: 4096)
    RailsPulse::Tracker.track_request(data)

    request = RailsPulse::Request.find_by(request_uuid: data[:request_uuid])

    assert_not_nil request
    assert_equal 4096, request.response_size_bytes
  end

  test "persists nil response_size_bytes when not provided" do
    RailsPulse::Tracker.track_request(@tracking_data)

    request = RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])

    assert_not_nil request
    assert_nil request.response_size_bytes
  end

  test "persists operation diagnostic fields" do
    data = @tracking_data.merge(
      operations: [
        {
          operation_type: "sql",
          duration: 50.0,
          label: "SELECT * FROM users WHERE id = 1",
          occurred_at: Time.current,
          row_count: 1,
          repeated_query_group: "SELECT * FROM users WHERE id = ?",
          repetition_count: 5
        }
      ]
    )

    RailsPulse::Tracker.track_request(data)

    request = RailsPulse::Request.find_by(request_uuid: data[:request_uuid])
    operation = request.operations.first

    assert_equal 1, operation.row_count
    assert_equal 5, operation.repetition_count
    assert_not_nil operation.repeated_query_group
  end

  test "persists operations in async mode" do
    # Temporarily enable async mode
    original_async = RailsPulse.configuration.async
    RailsPulse.configuration.async = true

    begin
      RailsPulse::Tracker.track_request(@tracking_data)

      request = RailsPulse::Request.find_by(request_uuid: @tracking_data[:request_uuid])

      assert_not_nil request, "Request should be created"
      assert_equal 1, request.operations.count, "Operation should be persisted"
      assert_equal "SELECT * FROM users", request.operations.first.label
    ensure
      RailsPulse.configuration.async = original_async
    end
  end

  # Operations Edge Cases

  test "handles nil operations key without raising" do
    data = @tracking_data.merge(operations: nil)

    RailsPulse::Tracker.track_request(data)

    request = RailsPulse::Request.find_by(request_uuid: data[:request_uuid])

    assert_not_nil request
    assert_equal 0, request.operations.count
  end

  test "handles missing operations key without raising" do
    data = @tracking_data.except(:operations)

    RailsPulse::Tracker.track_request(data)

    request = RailsPulse::Request.find_by(request_uuid: data[:request_uuid])

    assert_not_nil request
    assert_equal 0, request.operations.count
  end

  test "handles empty operations array without raising" do
    data = @tracking_data.merge(operations: [])

    RailsPulse::Tracker.track_request(data)

    request = RailsPulse::Request.find_by(request_uuid: data[:request_uuid])

    assert_not_nil request
    assert_equal 0, request.operations.count
  end

  # Route Management

  test "reuses existing route when same method and path are tracked again" do
    path = "/route-reuse-#{SecureRandom.hex(4)}"
    data1 = @tracking_data.merge(path: path, request_uuid: SecureRandom.uuid)
    data2 = @tracking_data.merge(path: path, request_uuid: SecureRandom.uuid)

    RailsPulse::Tracker.track_request(data1)

    assert_difference -> { RailsPulse::Route.count }, 0 do
      RailsPulse::Tracker.track_request(data2)
    end

    route = RailsPulse::Route.find_by(path: path)

    assert_equal 2, RailsPulse::Request.where(route: route).count
  end

  # Return Values

  test "returns created request record in sync mode" do
    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_kind_of RailsPulse::Request, result
    assert_equal @tracking_data[:request_uuid], result.request_uuid
  end

  # Error Handling and Retry Logic

  test "returns nil when an unrecoverable error occurs" do
    RailsPulse::Request.stubs(:create!).raises(StandardError, "unexpected failure")

    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_nil result
  ensure
    RailsPulse::Request.unstub(:create!)
  end

  test "logs error message when tracking fails" do
    log_output = StringIO.new
    RailsPulse.stubs(:logger).returns(Logger.new(log_output))
    RailsPulse::Request.stubs(:create!).raises(StandardError, "db failure")

    RailsPulse::Tracker.track_request(@tracking_data)

    assert_includes log_output.string, "Failed to persist tracking data"
    assert_includes log_output.string, "db failure"
  ensure
    RailsPulse.unstub(:logger)
    RailsPulse::Request.unstub(:create!)
  end

  test "returns nil on connection not established error" do
    RailsPulse::Request.stubs(:create!).raises(ActiveRecord::ConnectionNotEstablished, "connection lost")

    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_nil result
  ensure
    RailsPulse::Request.unstub(:create!)
  end

  test "returns nil on statement invalid error" do
    RailsPulse::Request.stubs(:create!).raises(ActiveRecord::StatementInvalid, "statement error")

    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_nil result
  ensure
    RailsPulse::Request.unstub(:create!)
  end

  # Batch Persistence

  test "perform_tracking_batch skips a request that fails and keeps the rest" do
    good = @tracking_data.merge(request_uuid: "batch-good-#{SecureRandom.hex(4)}")
    bad = @tracking_data.merge(request_uuid: "batch-bad-#{SecureRandom.hex(4)}", status: nil)

    RailsPulse::Tracker.perform_tracking_batch([ bad, good ])

    assert_nil RailsPulse::Request.find_by(request_uuid: bad[:request_uuid])
    request = RailsPulse::Request.find_by(request_uuid: good[:request_uuid])

    assert_not_nil request
    assert_equal 1, request.operations.count
  end

  test "perform_tracking_batch inserts operations for every request in one batch" do
    batch = 3.times.map { |i| @tracking_data.merge(request_uuid: "batch-#{i}-#{SecureRandom.hex(4)}") }
    inserts = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      inserts += 1 if payload[:sql].start_with?("INSERT INTO \"rails_pulse_operations\"", "INSERT INTO `rails_pulse_operations`")
    end

    RailsPulse::Tracker.perform_tracking_batch(batch)

    assert_equal 1, inserts
    assert_equal 3, RailsPulse::Operation.where(request_id: RailsPulse::Request.where(request_uuid: batch.map { |d| d[:request_uuid] }).select(:id)).count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "detect_n_plus_one runs on the writer side" do
    ops = 3.times.map { |i| { operation_type: "sql", duration: 1.0, label: "q", actual_sql: "SELECT * FROM users WHERE id = #{i}", occurred_at: Time.current } }
    data = @tracking_data.merge(operations: ops)

    request = RailsPulse::Tracker.track_request(data)

    assert_equal [ 3, 3, 3 ], request.operations.pluck(:repetition_count)
  end

  # Aborted Transaction Recovery

  test "clears aborted postgresql transaction state before tracking" do
    # Simulate a raw PostgreSQL connection reporting PQTRANS_INERROR (value 2).
    # We stub raw_connection only — query execution uses @raw_connection directly
    # via with_raw_connection, so actual DB operations are unaffected by this stub.
    mock_raw_conn = Struct.new(:transaction_status).new(3) # PQTRANS_INERROR

    conn = RailsPulse::ApplicationRecord.connection
    conn.stubs(:raw_connection).returns(mock_raw_conn)
    conn.expects(:rollback_db_transaction).once

    result = RailsPulse::Tracker.track_request(@tracking_data)

    assert_kind_of RailsPulse::Request, result
    assert_equal @tracking_data[:request_uuid], result.request_uuid
  ensure
    conn.unstub(:raw_connection)
  end
end
