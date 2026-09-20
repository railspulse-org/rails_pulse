require "test_helper"

module RailsPulse
  module Tracker
    class WriterTest < ActiveSupport::TestCase
      def setup
        @writer = Writer.new(queue_size: 2, auto_start: false)
        @data = {
          method: "GET", path: "/writer-#{SecureRandom.hex(4)}", duration: 10.0, status: 200, is_error: false,
          request_uuid: SecureRandom.uuid, controller_action: "pages#show", occurred_at: Time.current,
          operations: [ { operation_type: "sql", duration: 1.0, label: "SELECT 1", occurred_at: Time.current } ]
        }
      end

      # Queue Bounds

      test "enqueue accepts work up to the queue size" do
        assert @writer.enqueue(@data)
        assert @writer.enqueue(@data)
        assert_equal 2, @writer.size
      end

      test "enqueue drops and counts when the queue is full" do
        2.times { @writer.enqueue(@data) }

        refute @writer.enqueue(@data)
        assert_equal 1, @writer.dropped
        assert_equal 2, @writer.size
      end

      test "a full queue is logged once per interval, with the count since the last notice" do
        log = StringIO.new
        RailsPulse.stubs(:logger).returns(Logger.new(log))
        2.times { @writer.enqueue(@data) }

        3.times { @writer.enqueue(@data) }

        assert_equal 1, log.string.scan("writer queue is full").size
        assert_equal 3, @writer.dropped
      ensure
        RailsPulse.unstub(:logger)
      end

      # Draining

      test "drain persists everything queued and empties the queue" do
        first = @data.merge(request_uuid: SecureRandom.uuid)
        second = @data.merge(request_uuid: SecureRandom.uuid)
        @writer.enqueue(first)
        @writer.enqueue(second)

        assert_equal 2, @writer.drain
        assert_equal 0, @writer.size
        assert_not_nil RailsPulse::Request.find_by(request_uuid: first[:request_uuid])
        assert_not_nil RailsPulse::Request.find_by(request_uuid: second[:request_uuid])
      end

      test "drain returns zero on an empty queue" do
        assert_equal 0, @writer.drain
      end

      test "shutdown drains without a running thread and can be called twice" do
        @writer.enqueue(@data)

        @writer.shutdown
        @writer.shutdown

        assert_not_nil RailsPulse::Request.find_by(request_uuid: @data[:request_uuid])
        assert_equal 0, @writer.size
      end

      test "a closed queue counts new work as dropped" do
        @writer.shutdown

        refute @writer.enqueue(@data)
        assert_equal 1, @writer.dropped
      end
    end
  end
end
