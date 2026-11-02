require "test_helper"

module RailsPulse
  class CleanupJobTest < ActiveJob::TestCase
    fixtures :rails_pulse_requests, :rails_pulse_routes, :rails_pulse_operations,
             :rails_pulse_jobs, :rails_pulse_job_runs

    def setup
      ENV["TEST_TYPE"] = "functional"
      super

      @original_archiving_enabled = RailsPulse.configuration.archiving_enabled
      @original_retention_period = RailsPulse.configuration.full_retention_period
      @original_max_records = RailsPulse.configuration.max_table_records&.dup

      # Disable archiving by default to avoid FK constraint issues with fixtures
      # Individual tests can enable it as needed
      RailsPulse.configuration.archiving_enabled = false
      RailsPulse.configuration.full_retention_period = 30.days
    end

    def teardown
      RailsPulse.configuration.archiving_enabled = @original_archiving_enabled
      RailsPulse.configuration.full_retention_period = @original_retention_period
      RailsPulse.configuration.max_table_records = @original_max_records if @original_max_records
      super
    end

    # ============================================================================
    # Configuration Tests
    # ============================================================================

    test "perform returns nil when archiving is disabled" do
      RailsPulse.configuration.archiving_enabled = false

      result = CleanupJob.new.perform

      assert_nil result
    end

    test "perform executes cleanup when archiving is enabled" do
      # Clean up all existing data to avoid FK constraints
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      result = CleanupJob.new.perform

      assert_not_nil result
      assert_kind_of Hash, result
    end

    test "perform respects custom retention period" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true
      # Set very long retention period
      RailsPulse.configuration.full_retention_period = 100.days

      # Create old request (within new retention period)
      old_request = RailsPulse::Request.create!(
        route_id: rails_pulse_routes(:api_users).id,
        duration: 100,
        status: 200,
        request_uuid: SecureRandom.uuid,
        occurred_at: 60.days.ago
      )

      old_id = old_request.id

      CleanupJob.new.perform

      # Should NOT be deleted (within 100-day retention)
      assert RailsPulse::Request.exists?(old_id)
    end

    # ============================================================================
    # Return Value Tests
    # ============================================================================

    test "perform returns stats hash from CleanupService" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      result = CleanupJob.new.perform

      assert_kind_of Hash, result
      assert_includes result.keys, :time_based
      assert_includes result.keys, :count_based
      assert_includes result.keys, :total_deleted
    end

    test "perform returns stats with total_deleted count" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      result = CleanupJob.new.perform

      assert_kind_of Integer, result[:total_deleted]
      assert_operator result[:total_deleted], :>=, 0
    end

    test "perform returns stats with nested time_based hash" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      result = CleanupJob.new.perform

      assert_kind_of Hash, result[:time_based]
      assert_includes result[:time_based].keys, :operations
      assert_includes result[:time_based].keys, :requests
    end

    # ============================================================================
    # Integration Tests (Real CleanupService Execution)
    # ============================================================================

    test "perform deletes old records based on retention period" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # Create old request (outside retention period)
      old_request = RailsPulse::Request.create!(
        route_id: rails_pulse_routes(:api_users).id,
        duration: 100,
        status: 200,
        request_uuid: SecureRandom.uuid,
        occurred_at: 60.days.ago
      )

      # Create recent request (inside retention period)
      recent_request = RailsPulse::Request.create!(
        route_id: rails_pulse_routes(:api_users).id,
        duration: 100,
        status: 200,
        request_uuid: SecureRandom.uuid,
        occurred_at: 1.day.ago
      )

      old_id = old_request.id
      recent_id = recent_request.id

      CleanupJob.new.perform

      # Old request should be deleted
      refute RailsPulse::Request.exists?(old_id)

      # Recent request should remain
      assert RailsPulse::Request.exists?(recent_id)
    end

    test "perform deletes operations before their parent requests" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # Create request with operations
      request = RailsPulse::Request.create!(
        route_id: rails_pulse_routes(:api_users).id,
        duration: 100,
        status: 200,
        request_uuid: SecureRandom.uuid,
        occurred_at: 60.days.ago
      )

      operation = RailsPulse::Operation.create!(
        request_id: request.id,
        operation_type: "sql",
        label: "SELECT * FROM users",
        duration: 50,
        occurred_at: 60.days.ago
      )

      request_id = request.id
      operation_id = operation.id

      # Should not raise foreign key constraint error
      assert_nothing_raised do
        CleanupJob.new.perform
      end

      # Both should be deleted
      refute RailsPulse::Request.exists?(request_id)
      refute RailsPulse::Operation.exists?(operation_id)
    end

    test "perform handles job runs cleanup" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      job = RailsPulse::Job.create!(
        name: "OldTestJob",
        queue_name: "default",
        runs_count: 1,
        failures_count: 0
      )

      old_run = RailsPulse::JobRun.create!(
        job: job,
        run_id: "old-123",
        status: "success",
        duration: 100,
        occurred_at: 60.days.ago
      )

      run_id = old_run.id

      CleanupJob.new.perform

      # Old run should be deleted
      refute RailsPulse::JobRun.exists?(run_id)
    end

    test "perform respects max_table_records configuration" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # Set very low limit for requests
      RailsPulse.configuration.max_table_records = {
        rails_pulse_requests: 5
      }

      # Create a summary covering up to 1 hour ago so older requests are eligible
      # for count-based cleanup (the summarization guard requires a summary to exist)
      RailsPulse::Summary.create!(
        summarizable_type: "RailsPulse::Request",
        summarizable_id:   0,
        period_type:       "hour",
        period_start:      10.hours.ago.beginning_of_hour,
        period_end:        1.hour.ago,
        count:             10,
        avg_duration:      100.0
      )

      # Create 10 requests (all recent, so time-based won't delete them)
      created_ids = []
      10.times do |i|
        req = RailsPulse::Request.create!(
          route_id: rails_pulse_routes(:api_users).id,
          duration: 100,
          status: 200,
          request_uuid: SecureRandom.uuid,
          occurred_at: (i + 2).hours.ago  # 2–11 hours ago, all before the summary cutoff
        )
        created_ids << req.id
      end

      initial_count = RailsPulse::Request.count

      result = CleanupJob.new.perform

      final_count = RailsPulse::Request.count

      # Should have deleted some records to reach max limit
      assert_operator final_count, :<=, initial_count
      assert_operator final_count, :<=, 5  # Should be at or below the limit
    end

    # ============================================================================
    # Edge Cases
    # ============================================================================

    test "perform handles empty database gracefully" do
      # Delete all records
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all
      RailsPulse::Query.delete_all
      RailsPulse::Route.delete_all
      RailsPulse::Job.delete_all
      RailsPulse::ExceptionOccurrence.delete_all
      RailsPulse::ExceptionGroup.delete_all
      RailsPulse::Baseline.delete_all

      RailsPulse.configuration.archiving_enabled = true

      result = CleanupJob.new.perform

      assert_not_nil result
      assert_equal 0, result[:total_deleted]
    end

    test "perform handles when no records need deletion" do
      # Clean up existing data first
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all
      RailsPulse::Query.delete_all
      RailsPulse::Route.delete_all
      RailsPulse::Job.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # All records are recent, nothing should be deleted
      result = CleanupJob.new.perform

      # Should return stats even if nothing deleted
      assert_not_nil result
      assert_kind_of Integer, result[:total_deleted]
      # May delete some records from summaries or other sources
      assert_operator result[:total_deleted], :>=, 0
    end

    test "perform handles nil max_table_records configuration" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true
      RailsPulse.configuration.max_table_records = nil

      # Should still work, just skip count-based cleanup
      result = CleanupJob.new.perform

      assert_not_nil result
      assert_kind_of Hash, result
    end

    # ============================================================================
    # Error Handling Tests
    # ============================================================================

    test "perform logs error and re-raises when CleanupService raises exception" do
      RailsPulse.configuration.archiving_enabled = true

      error = StandardError.new("Cleanup failed!")
      RailsPulse::CleanupService.stubs(:perform).raises(error)

      # Capture logged messages
      log_messages = []
      original_logger = RailsPulse.logger
      test_logger = Object.new
      test_logger.define_singleton_method(:info) { |msg| log_messages << [ :info, msg ] }
      test_logger.define_singleton_method(:error) { |msg| log_messages << [ :error, msg ] }

      RailsPulse.stubs(:logger).returns(test_logger)

      # Should re-raise the error
      exception_raised = assert_raises StandardError do
        CleanupJob.new.perform
      end

      assert_equal "Cleanup failed!", exception_raised.message

      # Verify logging occurred
      assert log_messages.any? { |level, msg| level == :info && msg == "[CleanupJob] Starting scheduled cleanup" }
      assert log_messages.any? { |level, msg| level == :error && msg == "[CleanupJob] Cleanup failed: Cleanup failed!" }
      assert log_messages.any? { |level, msg| level == :error && msg.is_a?(String) }

      RailsPulse::CleanupService.unstub(:perform)
      RailsPulse.unstub(:logger)
    end

    test "perform logs error backtrace when exception occurs" do
      RailsPulse.configuration.archiving_enabled = true

      error = StandardError.new("Test error")
      error.set_backtrace([ "line 1", "line 2", "line 3" ])

      RailsPulse::CleanupService.stubs(:perform).raises(error)

      # Capture logged messages
      log_messages = []
      test_logger = Object.new
      test_logger.define_singleton_method(:info) { |msg| log_messages << [ :info, msg ] }
      test_logger.define_singleton_method(:error) { |msg| log_messages << [ :error, msg ] }

      RailsPulse.stubs(:logger).returns(test_logger)

      assert_raises StandardError do
        CleanupJob.new.perform
      end

      # Verify error message logged
      assert log_messages.any? { |level, msg| level == :error && msg == "[CleanupJob] Cleanup failed: Test error" }

      # Verify backtrace logged
      backtrace_message = log_messages.find { |level, msg| level == :error && msg.include?("line 1") }

      assert_not_nil backtrace_message, "Expected backtrace to be logged"
      assert_includes backtrace_message[1], "line 2", "Expected full backtrace to be logged"

      RailsPulse::CleanupService.unstub(:perform)
      RailsPulse.unstub(:logger)
    end

    # ============================================================================
    # Logging Tests
    # ============================================================================

    test "perform logs start message before cleanup" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # Capture logged messages
      log_messages = []
      test_logger = Object.new
      test_logger.define_singleton_method(:info) { |msg| log_messages << [ :info, msg ] }

      RailsPulse.stubs(:logger).returns(test_logger)

      CleanupJob.new.perform

      # Verify start message logged
      assert log_messages.any? { |level, msg| level == :info && msg == "[CleanupJob] Starting scheduled cleanup" }

      RailsPulse.unstub(:logger)
    end

    test "perform logs completion message with stats" do
      # Clean up existing data
      RailsPulse::Operation.delete_all
      RailsPulse::JobRun.delete_all
      RailsPulse::Request.delete_all

      RailsPulse.configuration.archiving_enabled = true

      # Capture logged messages
      log_messages = []
      test_logger = Object.new
      test_logger.define_singleton_method(:info) { |msg| log_messages << [ :info, msg ] }

      RailsPulse.stubs(:logger).returns(test_logger)

      CleanupJob.new.perform

      # Verify completion message logged with record count
      completion_msg = log_messages.find { |level, msg| level == :info && msg.start_with?("[CleanupJob] Cleanup completed - ") }

      assert_not_nil completion_msg, "Expected completion message to be logged"
      assert_match(/\d+ records deleted/, completion_msg[1], "Expected completion message to include record count")

      RailsPulse.unstub(:logger)
    end
  end
end
