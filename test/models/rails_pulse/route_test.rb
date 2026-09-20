require "test_helper"

class RailsPulse::RouteTest < ActiveSupport::TestCase
  include Shoulda::Matchers::ActiveModel
  include Shoulda::Matchers::ActiveRecord

  # Structure Tests

  test "should have correct associations" do
    assert have_many(:requests).dependent(:restrict_with_exception).matches?(RailsPulse::Route.new)
    assert have_many(:summaries).dependent(:destroy).matches?(RailsPulse::Route.new)
  end

  test "should have correct validations" do
    route = RailsPulse::Route.new

    assert validate_presence_of(:path).matches?(route)
    assert validate_presence_of(:http_methods).matches?(route)
  end

  test "should be valid with required attributes" do
    route = rails_pulse_routes(:api_users)

    assert_predicate route, :valid?
  end

  test "should include Taggable concern" do
    assert_includes RailsPulse::Route.included_modules, RailsPulse::Taggable
  end

  test "should include Taggable methods" do
    assert_respond_to RailsPulse::Route.new, :tag_list
  end

  test "should include ransackable attributes" do
    expected = %w[path average_response_time_ms max_response_time_ms request_count requests_per_minute occurred_at requests_occurred_at error_count error_rate_percentage status_indicator]

    assert_equal expected.sort, RailsPulse::Route.ransackable_attributes.sort
  end

  test "should include ransackable associations" do
    assert_equal %w[requests], RailsPulse::Route.ransackable_associations
  end

  test "requests association returns correct requests" do
    route1 = rails_pulse_routes(:api_users)
    route2 = rails_pulse_routes(:api_posts)

    assert_includes route1.requests, rails_pulse_requests(:users_request_1)
    assert_not_includes route1.requests, rails_pulse_requests(:posts_request)
    assert_includes route2.requests, rails_pulse_requests(:posts_request)
    assert_not_includes route2.requests, rails_pulse_requests(:users_request_1)
  end

  test "should have polymorphic summaries association" do
    route   = rails_pulse_routes(:api_users)
    summary = rails_pulse_summaries(:route_summary_1)

    assert_includes route.summaries, summary
    assert_equal route, summary.summarizable
  end

  test "uniqueness enforced at database level on path when controller_action is null" do
    path = "/health-uniq-#{SecureRandom.hex(4)}"
    RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: path,
      controller_action: nil,
      tags: "[]"
    )

    duplicate = RailsPulse::Route.new(
      http_methods: '["HEAD"]',
      path: path,
      controller_action: nil,
      tags: "[]"
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "uniqueness enforced at database level on [controller_action, path]" do
    existing = rails_pulse_routes(:api_users)
    duplicate = RailsPulse::Route.new(
      http_methods: '["GET"]',
      path: existing.path,
      controller_action: existing.controller_action
    )

    assert_predicate duplicate, :valid?
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  # http_methods_list Tests

  test "http_methods_list parses JSON array" do
    route = rails_pulse_routes(:api_users)

    assert_equal [ "GET" ], route.http_methods_list
  end

  test "http_methods_list returns empty array when http_methods is blank" do
    route = RailsPulse::Route.new

    assert_empty route.http_methods_list
  end

  test "http_methods_list returns empty array on malformed JSON" do
    route = RailsPulse::Route.new(http_methods: "not-json")

    assert_empty route.http_methods_list
  end

  # add_http_method Tests

  test "add_http_method appends a new method to the array" do
    route = rails_pulse_routes(:api_users)

    assert_equal [ "GET" ], route.http_methods_list

    route.add_http_method("POST")

    assert_equal [ "GET", "POST" ], route.reload.http_methods_list
  end

  test "add_http_method is a no-op when the method already exists" do
    route = rails_pulse_routes(:api_users)
    original = route.http_methods

    route.add_http_method("GET")

    assert_equal original, route.reload.http_methods
  end

  test "add_http_method is a no-op for blank input" do
    route = rails_pulse_routes(:api_users)
    original = route.http_methods

    route.add_http_method(nil)
    route.add_http_method("")

    assert_equal original, route.reload.http_methods
  end

  # find_or_create_for_request Tests

  test "find_or_create_for_request finds existing route by controller_action and path" do
    existing = rails_pulse_routes(:api_users)

    found = RailsPulse::Route.find_or_create_for_request("GET", "/api/users", controller_action: "api/users#index")

    assert_equal existing, found
  end

  test "find_or_create_for_request creates a new route when none exists" do
    assert_difference -> { RailsPulse::Route.count }, 1 do
      route = RailsPulse::Route.find_or_create_for_request("GET", "/api/new-endpoint", controller_action: "api/widgets#index")

      assert_equal '["GET"]', route.http_methods
      assert_equal "/api/new-endpoint", route.path
      assert_equal "api/widgets#index", route.controller_action
    end
  end

  test "find_or_create_for_request stores controller_action on new routes" do
    route = RailsPulse::Route.find_or_create_for_request("POST", "/api/ca-test-#{SecureRandom.hex(4)}", controller_action: "home#create")

    assert_equal "home#create", route.controller_action
  end

  test "find_or_create_for_request appends a new http method to an existing route" do
    existing = rails_pulse_routes(:api_users)

    assert_equal [ "GET" ], existing.http_methods_list

    RailsPulse::Route.find_or_create_for_request("POST", existing.path, controller_action: existing.controller_action)

    assert_equal [ "GET", "POST" ], existing.reload.http_methods_list
  end

  test "find_or_create_for_request does not create a duplicate for the same controller_action and path" do
    assert_no_difference -> { RailsPulse::Route.count } do
      RailsPulse::Route.find_or_create_for_request("GET", "/api/users", controller_action: "api/users#index")
      RailsPulse::Route.find_or_create_for_request("POST", "/api/users", controller_action: "api/users#index")
    end
  end

  test "find_or_create_for_request groups by path alone when controller_action is nil" do
    assert_difference -> { RailsPulse::Route.count }, 1 do
      r1 = RailsPulse::Route.find_or_create_for_request("GET", "/health", controller_action: nil)
      r2 = RailsPulse::Route.find_or_create_for_request("HEAD", "/health", controller_action: nil)

      assert_equal r1, r2
    end
  end

  test "find_or_create_for_request keeps different actions on the same path separate" do
    path = "/identity-#{SecureRandom.hex(4)}"

    get_route = RailsPulse::Route.find_or_create_for_request("GET", path, controller_action: "home#index")
    post_route = RailsPulse::Route.find_or_create_for_request("POST", path, controller_action: "home#create")

    assert_not_equal get_route.id, post_route.id
    assert_equal "home#index", get_route.controller_action
    assert_equal "home#create", post_route.controller_action
    assert_equal [ "GET" ], get_route.http_methods_list
    assert_equal [ "POST" ], post_route.http_methods_list
  end

  test "needs_action_backfill? is true when a live route has no controller_action" do
    RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: "/slow",
      controller_action: nil,
      tags: "[]"
    )

    assert_predicate RailsPulse::Route, :needs_action_backfill?
  end

  test "needs_action_backfill? runs a single query when every route has an action" do
    RailsPulse::Route.where(controller_action: [ nil, "" ]).delete_all
    statements = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
    end

    assert_not RailsPulse::Route.needs_action_backfill?
    assert_equal 1, statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "needs_action_backfill? is false when blank-action routes are unrecognized" do
    RailsPulse::Route.create!(
      http_methods: '["GET"]',
      path: "/ghost-backfill-#{SecureRandom.hex(4)}",
      controller_action: nil,
      tags: "[]"
    )

    assert_not RailsPulse::Route.needs_action_backfill?
  end

  # to_breadcrumb Tests

  test "to_breadcrumb returns method and path" do
    route = rails_pulse_routes(:api_users)

    assert_equal "GET /api/users", route.to_breadcrumb
  end

  test "to_breadcrumb joins multiple methods with pipe" do
    route = RailsPulse::Route.new(http_methods: '["GET","POST"]', path: "/sign_in")

    assert_equal "GET|POST /sign_in", route.to_breadcrumb
  end

  test "to_breadcrumb truncates long paths" do
    route = RailsPulse::Route.new(http_methods: '["GET"]', path: "/very/long/path/#{'x' * 100}")

    assert_operator route.to_breadcrumb.length, :<=, 60
  end

  # path_and_method Tests

  test "path_and_method returns path and method" do
    route = rails_pulse_routes(:api_posts)

    assert_equal "/api/posts POST", route.path_and_method
  end

  test "path_and_method joins multiple methods" do
    route = RailsPulse::Route.new(http_methods: '["PATCH","PUT"]', path: "/articles/:id")

    assert_equal "/articles/:id PATCH|PUT", route.path_and_method
  end

  # Ransacker Tests

  test "average_response_time_ms ransacker works with Ransack queries" do
    search = RailsPulse::Route.ransack(s: "average_response_time_ms desc")

    assert_kind_of ActiveRecord::Relation, search.result
    assert_operator search.result.count, :>, 0
  end

  test "request_count ransacker works with Ransack queries" do
    search = RailsPulse::Route.ransack(s: "request_count desc")

    assert_kind_of ActiveRecord::Relation, search.result
    assert_operator search.result.count, :>, 0
  end

  test "error_rate_percentage ransacker works with Ransack queries" do
    search = RailsPulse::Route.ransack(s: "error_rate_percentage desc")

    assert_kind_of ActiveRecord::Relation, search.result
  end

  # Class Method Tests

  test "average_response_time returns 0 when no routes exist" do
    RailsPulse::Operation.delete_all
    RailsPulse::Request.delete_all
    RailsPulse::Summary.delete_all
    RailsPulse::Route.delete_all

    assert_equal 0, RailsPulse::Route.average_response_time
  end

  test "average_response_time calculates correct average from fixtures" do
    requests     = RailsPulse::Request.all
    expected_avg = requests.sum(:duration) / requests.count.to_f

    assert_in_delta expected_avg, RailsPulse::Route.average_response_time, 0.1
  end

  test "should raise on dependent destroy when requests exist" do
    route = rails_pulse_routes(:api_users)

    assert_raises(ActiveRecord::DeleteRestrictionError) { route.destroy! }
  end
end
