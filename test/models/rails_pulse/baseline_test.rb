require "test_helper"

module RailsPulse
  class BaselineTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_jobs, :rails_pulse_baselines

    def build_baseline(overrides = {})
      Baseline.new({
        subject: rails_pulse_routes(:api_posts),
        p50_ms: 100.0,
        p90_ms: 200.0,
        p95_ms: 250.0,
        sample_count: 50,
        periods: 24,
        computed_at: Time.current
      }.merge(overrides))
    end

    # Structure Tests

    test "route, query and job each reach their baseline" do
      assert_equal rails_pulse_baselines(:api_users_baseline), rails_pulse_routes(:api_users).baseline
      assert_equal rails_pulse_baselines(:simple_query_baseline), rails_pulse_queries(:simple_query).baseline
      assert_equal rails_pulse_baselines(:mailer_job_baseline), rails_pulse_jobs(:mailer_job).baseline
    end

    test "baseline reaches its subject" do
      assert_equal rails_pulse_routes(:api_users), rails_pulse_baselines(:api_users_baseline).subject
    end

    test "subject without a baseline returns nil" do
      assert_nil rails_pulse_routes(:api_posts).baseline
    end

    test "destroying the subject removes its baseline" do
      route = rails_pulse_routes(:api_cleanup)
      Baseline.create!(subject: route, sample_count: 1, periods: 1, computed_at: Time.current)

      assert_difference "RailsPulse::Baseline.count", -1 do
        route.destroy!
      end
    end

    test "stores percentiles with fractional milliseconds" do
      baseline = build_baseline(p50_ms: 1.234567)
      baseline.save!

      assert_in_delta 1.234567, baseline.reload.p50_ms.to_f, 1e-6
    end

    test "ransackable attributes and associations" do
      assert_includes Baseline.ransackable_attributes, "p90_ms"
      assert_includes Baseline.ransackable_attributes, "sample_count"
      assert_empty Baseline.ransackable_associations
    end

    # Validation Tests

    test "valid with all attributes" do
      assert_predicate build_baseline, :valid?
    end

    test "requires a subject" do
      assert_not build_baseline(subject: nil).valid?
    end

    test "rejects subjects other than route, query or job" do
      baseline = build_baseline(subject: nil, subject_type: "RailsPulse::Request", subject_id: 1)

      assert_not baseline.valid?
      assert_includes baseline.errors[:subject_type], "is not included in the list"
    end

    test "allows only one baseline per subject" do
      baseline = build_baseline(subject: rails_pulse_routes(:api_users))

      assert_not baseline.valid?
      assert_includes baseline.errors[:subject_id], "has already been taken"
    end

    test "unique index rejects a second baseline for the same subject" do
      assert_raises ActiveRecord::RecordNotUnique do
        build_baseline(subject: rails_pulse_routes(:api_users)).save!(validate: false)
      end
    end

    test "the same id under a different subject type is a different subject" do
      route = rails_pulse_routes(:api_posts)
      Baseline.create!(subject: route, sample_count: 1, periods: 1, computed_at: Time.current)
      baseline = build_baseline(subject: nil, subject_type: "RailsPulse::Job", subject_id: route.id)

      assert_not_includes baseline.tap(&:valid?).errors.attribute_names, :subject_id
    end

    test "requires computed_at" do
      assert_not build_baseline(computed_at: nil).valid?
    end

    # Edge Cases

    test "no history yet: zero samples and nil percentiles are valid" do
      baseline = build_baseline(p50_ms: nil, p90_ms: nil, p95_ms: nil, sample_count: 0, periods: 0)

      assert_predicate baseline, :valid?
    end

    test "defaults sample_count and periods to zero" do
      baseline = Baseline.new

      assert_equal 0, baseline.sample_count
      assert_equal 0, baseline.periods
    end

    test "rejects negative counts" do
      assert_not build_baseline(sample_count: -1).valid?
      assert_not build_baseline(periods: -1).valid?
    end

    test "rejects fractional counts" do
      assert_not build_baseline(sample_count: 1.5).valid?
    end

    test "rejects negative percentiles" do
      assert_not build_baseline(p90_ms: -0.1).valid?
    end

    test "zero percentiles are valid" do
      assert_predicate build_baseline(p50_ms: 0, p90_ms: 0, p95_ms: 0), :valid?
    end
  end
end
