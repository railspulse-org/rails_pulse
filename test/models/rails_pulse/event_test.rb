require "test_helper"

module RailsPulse
  class EventTest < ActiveSupport::TestCase
    fixtures :rails_pulse_events

    # Validation Tests

    test "requires kind, outcome and occurred_at" do
      event = Event.new

      assert_not event.valid?
      assert_includes event.errors[:kind], "can't be blank"
      assert_includes event.errors[:outcome], "can't be blank"
      assert_includes event.errors[:occurred_at], "can't be blank"
    end

    test "any kind is accepted so rails_pulse_pro can add its own" do
      event = Event.new(kind: "exception_alert", outcome: "triggered", occurred_at: Time.current, subject: "Boom", value: 3)

      assert_predicate event, :valid?
    end

    # Scope Tests

    test "of_kind, for_subject and since narrow the table" do
      assert_equal 4, Event.of_kind("writer_heartbeat").count
      assert_equal 0, Event.of_kind(:alert_rule).count
      assert_equal 2, Event.for_subject("web-1:101").count
      assert_equal 3, Event.since(1.hour.ago).count
    end

    test "recent orders newest first" do
      assert_equal rails_pulse_events(:web_one_latest), Event.recent.first
    end

    # Edge Cases

    test "metadata_hash is empty for nil, blank and unparsable metadata" do
      assert_empty(Event.new.metadata_hash)
      assert_empty(Event.new(metadata: "").metadata_hash)
      assert_empty(Event.new(metadata: "{nope").metadata_hash)
      assert_equal 12, rails_pulse_events(:web_one_latest).metadata_hash["queue_depth"]
    end

    test "ransack is opted in explicitly" do
      assert_equal %w[kind subject outcome value occurred_at message created_at updated_at], Event.ransackable_attributes
      assert_empty Event.ransackable_associations
    end
  end
end
