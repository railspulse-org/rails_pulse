require "test_helper"

module RailsPulse
  class RouteMergerTest < ActiveSupport::TestCase
    fixtures :rails_pulse_routes, :rails_pulse_requests

    test "moves requests from source to target and destroys source" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      request = create_request(source)

      RailsPulse::RouteMerger.call(target: target, source: source)

      assert_not RailsPulse::Route.exists?(id: source.id)
      assert_equal target.id, request.reload.route_id
      assert_equal [ "GET", "POST" ], target.reload.http_methods_list.sort
    end

    test "is a no-op when target and source are the same record" do
      route = create_route("GET", "/posts/1")

      assert_nothing_raised do
        RailsPulse::RouteMerger.call(target: route, source: route)
      end

      assert RailsPulse::Route.exists?(id: route.id)
    end

    test "reassigns source summaries to target instead of destroying them" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      summary = create_summary(source, count: 42)

      RailsPulse::RouteMerger.call(target: target, source: source)

      assert_not RailsPulse::Route.exists?(id: source.id)
      assert RailsPulse::Summary.exists?(id: summary.id),
        "expected source summary to survive merge, but dependent: :destroy deleted it"
      assert_equal target.id, summary.reload.summarizable_id
      assert_equal 42, summary.count
    end

    test "combines overlapping period summaries onto the target" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      period_start = 1.hour.ago.beginning_of_hour

      target_summary = create_summary(target, count: 10, period_start: period_start, avg_duration: 100.0, p90_duration: 400.0)
      source_summary = create_summary(source, count: 30, period_start: period_start, avg_duration: 200.0, p90_duration: 800.0)

      RailsPulse::RouteMerger.call(target: target, source: source)

      assert_not RailsPulse::Summary.exists?(id: source_summary.id)
      target_summary.reload

      assert_equal target.id, target_summary.summarizable_id
      assert_equal 40, target_summary.count
      assert_in_delta 175.0, target_summary.avg_duration, 0.01
      assert_in_delta 700.0, target_summary.p90_duration, 0.01
    end

    test "reassigns source rollups to the target under a retired writer id" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      rollup = create_rollup(source, writer_id: "host:1:abc", count: 7)

      RailsPulse::RouteMerger.call(target: target, source: source)

      rollup.reload

      assert_equal target.id, rollup.rollupable_id
      assert_equal 7, rollup.count
      assert_not_equal "host:1:abc", rollup.writer_id,
        "a moved rollup must not keep its writer id, or the live writer's next upsert overwrites it"
    end

    test "moves two same-hour rollups from different writers without colliding" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      period_start = 3.hours.ago.beginning_of_hour

      create_rollup(source, writer_id: "host:1:abc", count: 1, period_start: period_start)
      create_rollup(source, writer_id: "host:2:def", count: 2, period_start: period_start)

      RailsPulse::RouteMerger.call(target: target, source: source)

      moved = RailsPulse::Rollup.where(rollupable_type: "RailsPulse::Route", rollupable_id: target.id)

      assert_equal 2, moved.count
      assert_equal 3, moved.sum(:count)
      assert_equal 2, moved.distinct.count(:writer_id)
    end

    test "leaves a rollup a live writer may still flush keyed to the source" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      rollup = create_rollup(source, writer_id: "host:1:abc", count: 7,
        period_start: Time.current.beginning_of_hour)

      RailsPulse::RouteMerger.call(target: target, source: source)

      rollup.reload

      assert_not RailsPulse::Route.exists?(id: source.id)
      assert_equal source.id, rollup.rollupable_id
      assert_equal "host:1:abc", rollup.writer_id,
        "a rollup its writer may still replace-upsert must keep its key, or the next flush re-inserts the totals and double-counts them"
    end

    test "a moved rollup coexists with the target's rollup from the same writer and hour" do
      target = create_route("GET", "/posts/1", controller_action: "home#index")
      source = create_route("POST", "/posts/1")
      period_start = 3.hours.ago.beginning_of_hour

      create_rollup(target, writer_id: "host:1:abc", count: 10, period_start: period_start)
      create_rollup(source, writer_id: "host:1:abc", count: 30, period_start: period_start)

      RailsPulse::RouteMerger.call(target: target, source: source)

      target_rollups = RailsPulse::Rollup.where(rollupable_type: "RailsPulse::Route", rollupable_id: target.id)

      assert_equal 2, target_rollups.count
      assert_equal 40, target_rollups.sum(:count)
    end

    private

    def create_route(http_method, path, controller_action: nil)
      RailsPulse::Route.create!(
        http_methods: [ http_method ].to_json,
        path: path,
        tags: "[]",
        controller_action: controller_action
      )
    end

    def create_request(route)
      RailsPulse::Request.create!(
        route: route,
        method: route.http_methods_list.first,
        duration: 100.0,
        status: 200,
        is_error: false,
        request_uuid: SecureRandom.uuid,
        controller_action: "PostsController#show",
        occurred_at: Time.current
      )
    end

    # Defaults to an hour old enough that no live writer bucket could still
    # flush it, so the merger is free to move the row.
    def create_rollup(route, writer_id:, count:, period_start: 3.hours.ago.beginning_of_hour)
      RailsPulse::Rollup.create!(
        rollupable: route,
        period_start: period_start,
        writer_id: writer_id,
        count: count,
        sum_duration: count * 10.0,
        histogram: RailsPulse::DurationHistogram.new.dump
      )
    end

    def create_summary(route, count:, period_start: 1.hour.ago.beginning_of_hour, avg_duration: 100.0, p90_duration: nil)
      RailsPulse::Summary.create!(
        summarizable: route,
        period_type: "hour",
        period_start: period_start,
        period_end: period_start.end_of_hour,
        count: count,
        avg_duration: avg_duration,
        p90_duration: p90_duration
      )
    end
  end
end
