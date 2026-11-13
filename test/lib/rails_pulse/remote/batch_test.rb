require "test_helper"

module RailsPulse
  module Remote
    class BatchTest < ActiveSupport::TestCase
      # Structure Tests

      test "the body is gzipped JSON in the contract's envelope" do
        batch = Batch.new([ Item.new("writer_heartbeat", { hostname: "web-1", pid: 1 }) ], now: Time.utc(2026, 11, 12, 20, 0, 0))
        body = JSON.parse(Zlib.gunzip(batch.body))

        assert_equal Remote::CONTRACT, body["version"]
        assert_equal batch.batch_id, body["batch_id"]
        assert_equal "2026-11-12T20:00:00.000000Z", body["created_at"]
        assert_equal Process.pid, body["pid"]
        assert_equal RailsPulse::VERSION, body["gem_version"]
        assert_equal Rails.env.to_s, body["environment"]
        assert_equal [ { "type" => "writer_heartbeat", "hostname" => "web-1", "pid" => 1 } ], body["items"]
        assert_equal 1, batch.item_count
      end

      test "times are sent as UTC ISO 8601 with microseconds, whatever the JSON precision" do
        original = ActiveSupport::JSON::Encoding.time_precision
        ActiveSupport::JSON::Encoding.time_precision = 0
        at = Time.zone.parse("2026-11-12 17:30:15.123456")

        items = Batch.items_of(Batch.new([ Item.new("request", { occurred_at: at, operations: [ { occurred_at: at } ] }) ]).body)

        assert_equal at.utc.iso8601(6), items.first["occurred_at"]
        assert_equal at.utc.iso8601(6), items.first["operations"].first["occurred_at"]
      ensure
        ActiveSupport::JSON::Encoding.time_precision = original
      end

      test "an operation's local request and job run ids are not sent" do
        operation = { request_id: SecureRandom.uuid, job_run_id: nil, operation_type: "sql", actual_sql: "SELECT 1", duration: 1.0 }

        item = Batch.items_of(Batch.new([ Item.new("request", { path: "/x", operations: [ operation ] }) ]).body).first

        assert_equal [ { "operation_type" => "sql", "actual_sql" => "SELECT 1", "duration" => 1.0 } ], item["operations"]
      end

      test "symbols, decimals and objects with as_json become plain JSON values" do
        encoded = Batch.encode(status: :ok, amount: BigDecimal("1.5"), when: Date.new(2026, 11, 12), params: ActionController::Parameters.new(a: 1).permit!)

        assert_equal({ "status" => "ok", "amount" => 1.5, "when" => "2026-11-12", "params" => { "a" => 1 } }, encoded)
      end

      # Edge Cases

      test "a string that is not valid UTF-8 is sent with its bad bytes replaced" do
        binary = "SELECT x'\xFF\xFE'".b

        encoded = Batch.encode(actual_sql: binary)

        assert_predicate encoded["actual_sql"], :valid_encoding?
        assert_equal Encoding::UTF_8, encoded["actual_sql"].encoding
        assert_nothing_raised { Batch.new([ Item.new("request", { operations: [ { actual_sql: binary } ] }) ]) }
      end

      test "a duration that is not a finite number is sent as null" do
        assert_equal({ "duration" => nil }, Batch.encode(duration: Float::NAN))
      end

      test "already encoded items are sent as they are, so a split batch keeps its items" do
        original = Batch.new([ Item.new("request", { path: "/a" }), Item.new("request", { path: "/b" }) ])
        items = Batch.items_of(original.body)

        resplit = Batch.new(items.first(1))

        assert_equal [ { "type" => "request", "path" => "/a" } ], Batch.items_of(resplit.body)
        assert_not_equal original.batch_id, resplit.batch_id
      end

      test "an empty batch is still a valid envelope" do
        batch = Batch.new([])

        assert_equal [], Batch.items_of(batch.body)
        assert_operator batch.bytesize, :>, 0
      end
    end
  end
end
