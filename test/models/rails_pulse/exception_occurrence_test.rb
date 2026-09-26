require "test_helper"

module RailsPulse
  class ExceptionOccurrenceTest < ActiveSupport::TestCase
    fixtures :rails_pulse_exception_groups, :rails_pulse_exception_occurrences

    def setup
      ENV["TEST_TYPE"] = "functional"
      super
    end

    # Validations

    test "validates presence of exception_class" do
      group = rails_pulse_exception_groups(:record_not_found)
      occurrence = ExceptionOccurrence.new(exception_group: group, occurred_at: Time.current)

      refute_predicate occurrence, :valid?
      assert_includes occurrence.errors[:exception_class], "can't be blank"
    end

    test "validates presence of occurred_at" do
      group = rails_pulse_exception_groups(:record_not_found)
      occurrence = ExceptionOccurrence.new(exception_group: group, exception_class: "RuntimeError")

      refute_predicate occurrence, :valid?
      assert_includes occurrence.errors[:occurred_at], "can't be blank"
    end

    test "valid occurrence saves successfully" do
      group = rails_pulse_exception_groups(:record_not_found)

      assert_difference -> { ExceptionOccurrence.count }, 1 do
        ExceptionOccurrence.create!(
          exception_group: group,
          exception_class: "ActiveRecord::RecordNotFound",
          occurred_at: Time.current
        )
      end
    end

    # Backtrace serialization

    test "backtrace is serialized as array" do
      occurrence = rails_pulse_exception_occurrences(:occurrence_one)

      assert_kind_of Array, occurrence.backtrace
      assert_kind_of Hash, occurrence.backtrace.first
    end

    test "backtrace stores file, line, method keys" do
      occurrence = rails_pulse_exception_occurrences(:occurrence_one)
      frame = occurrence.backtrace.first

      assert_equal "app/controllers/posts_controller.rb", frame["file"]
      assert_equal 42, frame["line"]
      assert_equal "show", frame["method"]
    end

    test "backtrace defaults to empty array when nil" do
      group = rails_pulse_exception_groups(:record_not_found)
      occurrence = ExceptionOccurrence.create!(
        exception_group: group,
        exception_class: "RuntimeError",
        occurred_at: Time.current
      )

      assert_empty occurrence.reload.backtrace
    end

    # Scopes

    test "recent orders by occurred_at desc" do
      group = rails_pulse_exception_groups(:record_not_found)
      results = group.occurrences.recent

      results.each_cons(2) do |a, b|
        assert_operator a.occurred_at, :>=, b.occurred_at
      end
    end

    # Associations

    test "belongs to exception_group" do
      occurrence = rails_pulse_exception_occurrences(:occurrence_one)

      assert_equal "ActiveRecord::RecordNotFound", occurrence.exception_group.exception_class
    end

    # Ransack

    test "ransackable_attributes returns expected fields" do
      attrs = ExceptionOccurrence.ransackable_attributes

      assert_includes attrs, "exception_class"
      assert_includes attrs, "occurred_at"
      assert_includes attrs, "request_url"
      assert_includes attrs, "environment"
    end

    test "to_breadcrumb returns a formatted occurred_at" do
      occurrence = rails_pulse_exception_occurrences(:occurrence_one)

      assert_equal occurrence.occurred_at.strftime("%b %d, %Y %l:%M %p"), occurrence.to_breadcrumb
    end
  end
end
