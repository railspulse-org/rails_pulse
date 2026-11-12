require_relative "central_test_helper"

module RailsPulse
  # One dashboard per application, chosen by the first path segment, and an
  # index of the applications.
  class CentralDashboardTest < CentralIntegrationTest
    setup do
      in_application(:alpha) { record_request("/alpha-page", hours_ago: 2) }
      in_application(:beta) { record_request("/beta-page", hours_ago: 2) }
    end

    # Structure Tests

    test "an application's pages read that application's database" do
      get "/alpha/requests"

      assert_response :success
      assert_includes response.body, "/alpha-page"
      assert_not_includes response.body, "/beta-page"

      get "/beta/requests"

      assert_response :success
      assert_includes response.body, "/beta-page"
      assert_not_includes response.body, "/alpha-page"
    end

    test "links on an application's dashboard stay under its path" do
      get "/alpha/requests"

      hrefs = response.body.scan(/href="([^"]+)"/).flatten.reject { |href| href.start_with?("/rails-pulse-assets", "http", "#") }

      assert_includes hrefs, "/alpha/"
      assert_includes hrefs, "/alpha/routes"
      assert hrefs.none? { |href| href.start_with?("/beta") }, "no link may lead to another application: #{hrefs.inspect}"
      assert_select "[data-rails-pulse--time-range-url-value='/alpha/settings/time_range']"
    end

    test "the header names the application" do
      get "/alpha/"

      assert_response :success
      assert_includes response.body, "Rails Pulse · alpha"
    end

    test "a setting saved from one application's dashboard redirects back under its path" do
      patch "/beta/settings/time_range", params: { preset: "last_7_days" }

      assert_redirected_to "/beta/"
    end

    test "a record is looked up in its own application's database only" do
      alpha_only = in_application(:alpha) { record_request("/alpha-second", hours_ago: 1) }

      get "/alpha/requests/#{alpha_only.id}"

      assert_response :success

      get "/beta/requests/#{alpha_only.id}"

      assert_response :not_found
    end

    test "the JSON API answers with the application's own data" do
      with_configuration(api_token: "central-api-token") do
        get "/beta/api/v1/requests", headers: { "X-Rails-Pulse-Token" => "central-api-token" }

        assert_response :success
        assert_includes response.body, "/beta-page"
        assert_not_includes response.body, "/alpha-page"

        get "/alpha/api/v1/capabilities", headers: { "X-Rails-Pulse-Token" => "central-api-token" }

        assert_equal "alpha", response.parsed_body["application"]
      end
    end

    test "the index lists every application with a link to its dashboard" do
      get "/rails_pulse"

      assert_response :success
      assert_select "a[href='/alpha/']", text: "alpha"
      assert_select "a[href='/beta/']", text: "beta"
    end

    test "the schema check is answered per application" do
      in_application(:beta) { RailsPulse::ApplicationRecord.connection.drop_table(:rails_pulse_rollups) }
      RailsPulse::SchemaCheck.reset!

      get "/beta/"

      assert_response :service_unavailable

      get "/alpha/"

      assert_response :success
    end

    # Edge Cases

    test "an application the central does not list is not routed to the engine" do
      get "/gamma/requests"

      assert_response :not_found
    end

    test "nothing reads or writes Rails Pulse tables outside an application" do
      assert_raises(ActiveRecord::ConnectionNotEstablished) { RailsPulse::Route.count }
      assert_not RailsPulse::SchemaCheck.tracking_allowed?, "a central never tracks itself"
    end

    private

    def record_request(path, hours_ago:)
      route = RailsPulse::Route.find_or_create_for_request("GET", path, controller_action: "pages#show")
      RailsPulse::Request.create!(route: route, method: "GET", duration: 80, status: 200, is_error: false,
                                  request_uuid: SecureRandom.uuid, controller_action: "pages#show",
                                  occurred_at: hours_ago.hours.ago)
      RailsPulse::SummaryService.new("hour", hours_ago.hours.ago.beginning_of_hour).perform
      RailsPulse::Request.find_by!(route: route)
    end
  end
end
