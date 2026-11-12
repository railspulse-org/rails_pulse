require_relative "central_test_helper"

module RailsPulse
  # Rails Pulse's jobs run once per application on a central, each in its
  # own database.
  class CentralJobsTest < CentralTestCase
    setup do
      @hour = 2.hours.ago.beginning_of_hour
      in_application(:alpha) { 3.times { record_request("/alpha", at: @hour + 5.minutes) } }
      in_application(:beta) { record_request("/beta", at: @hour + 5.minutes) }
    end

    # Structure Tests

    test "SummaryJob summarizes every application in its own database" do
      RailsPulse::SummaryJob.perform_now(@hour)

      in_application(:alpha) { assert_equal 3, RailsPulse::Summary.overall_requests.for_period_type("hour").find_by!(period_start: @hour).count }
      in_application(:beta) { assert_equal 1, RailsPulse::Summary.overall_requests.for_period_type("hour").find_by!(period_start: @hour).count }
    end

    test "CleanupJob cleans every application's database by the central's retention" do
      in_application(:alpha) { record_request("/alpha-old", at: 60.days.ago) }
      in_application(:beta) { record_request("/beta-old", at: 60.days.ago) }

      RailsPulse::CleanupJob.perform_now

      in_application(:alpha) do
        assert_equal 3, RailsPulse::Request.count
        assert RailsPulse::CleanupRun.events.exists?, "each database records its own cleanup run"
      end
      in_application(:beta) { assert_equal 1, RailsPulse::Request.count }
    end

    test "a job run inside an application runs for that application only" do
      in_application(:beta) { RailsPulse::SummaryJob.perform_now(@hour) }

      in_application(:alpha) { assert_not RailsPulse::Summary.exists? }
      in_application(:beta) { assert RailsPulse::Summary.exists? }
    end

    # Edge Cases

    test "one application's failure does not stop the others and is raised once they have run" do
      original = RailsPulse::SummaryService.instance_method(:perform)
      RailsPulse::SummaryService.define_method(:perform) do
        raise "alpha is broken" if RailsPulse::Central.current_application == :alpha

        original.bind_call(self)
      end

      error = assert_raises(RuntimeError) { RailsPulse::SummaryJob.perform_now(@hour) }

      assert_equal "alpha is broken", error.message
      in_application(:beta) { assert RailsPulse::Summary.exists? }
    ensure
      RailsPulse::SummaryService.define_method(:perform, original)
    end

    private

    def record_request(path, at:)
      route = RailsPulse::Route.find_or_create_for_request("GET", path, controller_action: "pages#show")
      RailsPulse::Request.create!(route: route, method: "GET", duration: 80, status: 200, is_error: false,
                                  request_uuid: SecureRandom.uuid, controller_action: "pages#show", occurred_at: at)
    end
  end
end
