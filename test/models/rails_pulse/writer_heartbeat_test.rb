require "test_helper"

module RailsPulse
  class WriterHeartbeatTest < ActiveSupport::TestCase
    fixtures :rails_pulse_events

    # Structure Tests

    test "record! stores a writer_heartbeat event with the sample in metadata" do
      RailsPulse::Event.delete_all
      WriterHeartbeat.record!(hostname: "web-9", pid: 9, queue_size: 500, queue_depth: 7, dropped: 2, dropped_total: 5)

      event = RailsPulse::Event.sole

      assert_equal WriterHeartbeat::KIND, event.kind
      assert_equal "web-9:9", event.subject
      assert_equal "sampled", event.outcome
      assert_in_delta 2, event.value
      assert_equal({ "hostname" => "web-9", "pid" => 9, "queue_size" => 500, "queue_depth" => 7, "dropped_total" => 5 }, event.metadata_hash)
    end

    test "live_processes returns the latest sample per process and skips stale writers" do
      processes = WriterHeartbeat.live_processes

      assert_equal %w[web-1:101 web-2:202], processes.map(&:process_label).sort
      assert_equal 12, processes.find { |p| p.hostname == "web-1" }.queue_depth, "expected the newest web-1 sample, not the earlier one"
      assert_equal 1000, processes.first.queue_size
    end

    test "summary adds up live writers and the hour's drops" do
      rails_pulse_events(:web_two_latest).update!(value: 7)
      summary = WriterHeartbeat.summary

      # web-1 (depth 12) and web-2 (depth 3) are live; web-3 stopped two hours ago.
      assert_equal 2, summary[:processes]
      assert_equal 15, summary[:queue_depth]
      assert_equal 1000, summary[:queue_size]
      # 0 + 0 from web-1, 7 from web-2; web-3's 50 are outside the hour.
      assert_equal 7, summary[:dropped]
      assert_in_delta rails_pulse_events(:web_one_latest).occurred_at, summary[:last_sampled_at], 1
    end

    test "summary honours a custom window" do
      # web-3's 50 drops are two hours old: outside the default hour, inside three.
      assert_equal 0, WriterHeartbeat.summary[:dropped]
      assert_equal 50, WriterHeartbeat.summary(window: 3.hours)[:dropped]
    end

    test "dropped_by_process keys drops by host:pid" do
      rails_pulse_events(:web_two_latest).update!(value: 7)

      assert_equal({ "web-1:101" => 0, "web-2:202" => 7 }, WriterHeartbeat.dropped_by_process)
    end

    # Edge Cases

    test "summary is all zeros with no heartbeats" do
      RailsPulse::Event.delete_all

      assert_equal({ processes: 0, queue_depth: 0, queue_size: 0, dropped: 0, last_sampled_at: nil }, WriterHeartbeat.summary)
    end

    test "prune! removes samples older than the retention window only, and only heartbeats" do
      WriterHeartbeat.record!(hostname: "web-9", pid: 9, queue_size: 10, queue_depth: 0, dropped: 0, dropped_total: 0, sampled_at: 25.hours.ago)
      other = RailsPulse::Event.create!(kind: "alert_rule", outcome: "triggered", occurred_at: 25.hours.ago)

      assert_difference -> { RailsPulse::Event.count }, -1 do
        WriterHeartbeat.prune!
      end
      assert RailsPulse::Event.exists?(other.id)
      assert RailsPulse::Event.exists?(rails_pulse_events(:web_three_stale).id)
    end
  end
end
