require "test_helper"

module RailsPulse
  module Api
    module V1
      class QueriesControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        test "returns 401 without token" do
          get rails_pulse.api_v1_queries_path

          assert_response :unauthorized
        end

        test "returns 401 with wrong token" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => "wrong" }

          assert_response :unauthorized
        end

        test "returns 200 with correct token" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }

          assert_response :success
        end

        test "returns expected JSON shape" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert body.key?("data")
          assert body.key?("meta")
          assert_equal %w[total limit offset], body["meta"].keys
        end

        test "serializes query fields" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)
          query = body["data"].first

          %w[id normalized_sql hashed_sql analyzed_at issues suggestions].each { |k| assert_includes query.keys, k }
        end

        test "meta total reflects all query records" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert_equal RailsPulse::Query.count, body["meta"]["total"]
        end

        test "respects limit parameter" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { limit: 1 }
          body = JSON.parse(response.body)

          assert_equal 1, body["data"].length
        end

        test "respects offset parameter" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { offset: 1000 }
          body = JSON.parse(response.body)

          assert_empty body["data"]
        end

        test "returns 400 for invalid since time" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { since: "bad" }

          assert_response :bad_request
        end

        test "returns 400 for invalid until time" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { until: "bad" }

          assert_response :bad_request
        end

        test "stats are nil without a time range" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }
          body = JSON.parse(response.body)

          assert body["data"].all? { |q| q["stats"].nil? }
        end

        test "returns 400 for invalid sort" do
          get rails_pulse.api_v1_queries_path, headers: { "X-Rails-Pulse-Token" => VALID_TOKEN }, params: { sort: "bogus" }

          assert_response :bad_request
        end

        test "time range returns only queries with operations, with stats, sorted by total duration" do
          seed_operations

          get rails_pulse.api_v1_queries_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { since: 1.day.ago.iso8601, until: Time.current.iso8601 }
          body = JSON.parse(response.body)

          assert_response :success
          assert_equal 2, body["meta"]["total"]
          assert_equal [ @orders.id, @users.id ], body["data"].map { |q| q["id"] }

          orders = body["data"].first["stats"]

          assert_equal 2, orders["executions"]
          assert_in_delta 150.0, orders["avg_duration_ms"]
          assert_in_delta 200.0, orders["max_duration_ms"]
          assert_in_delta 300.0, orders["total_duration_ms"]
          assert_equal 5, orders["max_repetition_count"]
          assert_nil body["data"].last["stats"]["max_repetition_count"]
        end

        test "sort without since defaults to the last 24 hours" do
          seed_operations

          get rails_pulse.api_v1_queries_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { sort: "executions" }
          body = JSON.parse(response.body)

          assert_equal 2, body["meta"]["total"]
          assert_equal @orders.id, body["data"].first["id"]
        end

        test "sort by avg_duration reorders results and respects limit" do
          seed_operations

          get rails_pulse.api_v1_queries_path,
              headers: { "X-Rails-Pulse-Token" => VALID_TOKEN },
              params: { since: 1.day.ago.iso8601, sort: "avg_duration", limit: 1 }
          body = JSON.parse(response.body)

          assert_equal [ @users.id ], body["data"].map { |q| q["id"] }
          assert_equal 2, body["meta"]["total"]
        end

        private

        def seed_operations
          @users  = rails_pulse_queries(:simple_query)
          @orders = rails_pulse_queries(:analyzed_query)
          request = rails_pulse_requests(:users_request_1)
          now = Time.current
          RailsPulse::Operation.delete_all

          RailsPulse::Operation.insert_all!([
            op(request, @orders, 100.0, now - 2.hours, repetition_count: 5),
            op(request, @orders, 200.0, now - 1.hour),
            op(request, @users, 180.0, now - 3.hours),
            op(request, @users, 999.0, now - 3.days)
          ])
        end

        def op(request, query, duration, occurred_at, repetition_count: nil)
          {
            request_id: request.id, query_id: query.id, operation_type: "sql", label: query.normalized_sql,
            duration: duration, occurred_at: occurred_at, start_time: 0.0, repetition_count: repetition_count,
            created_at: occurred_at, updated_at: occurred_at
          }
        end
      end
    end
  end
end
