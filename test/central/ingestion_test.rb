require_relative "central_test_helper"

module RailsPulse
  class CentralIngestionTest < CentralIntegrationTest
    # Structure Tests

    test "a batch is recorded in the database of the application its token belongs to" do
      post_batch([ request_item(path: "/alpha-only") ], token: ALPHA_TOKEN)

      assert_response 202
      assert_equal 1, response.parsed_body["accepted"]
      assert_equal 0, response.parsed_body["rejected"]

      in_application(:alpha) do
        assert_equal [ "/alpha-only" ], RailsPulse::Route.pluck(:path)
        assert_equal 1, RailsPulse::Request.count
        assert_equal 1, RailsPulse::Operation.count
        assert_equal "SELECT * FROM posts WHERE id = ?", RailsPulse::Query.sole.normalized_sql
      end
      in_application(:beta) do
        assert_equal 0, RailsPulse::Route.count
        assert_equal 0, RailsPulse::Request.count
        assert_equal 0, RailsPulse::Operation.count
      end
    end

    test "two applications' batches never mix" do
      post_batch([ request_item(path: "/a") ], token: ALPHA_TOKEN)
      post_batch([ request_item(path: "/b"), request_item(path: "/b") ], token: BETA_TOKEN)

      assert_response 202
      in_application(:alpha) do
        assert_equal [ "/a" ], RailsPulse::Route.pluck(:path)
        assert_equal 1, RailsPulse::Request.count
      end
      in_application(:beta) do
        assert_equal [ "/b" ], RailsPulse::Route.pluck(:path)
        assert_equal 2, RailsPulse::Request.count
      end
    end

    test "operations are recorded with their request and N+1 marks, as the writer records them" do
      sql = { operation_type: "sql", label: nil, duration: 1.5, codebase_location: "app/models/post.rb",
              start_time: Time.current.to_f, occurred_at: Time.current, row_count: 1 }
      operations = [
        sql.merge(actual_sql: "SELECT * FROM comments WHERE post_id = 1"),
        sql.merge(actual_sql: "SELECT * FROM comments WHERE post_id = 2"),
        { operation_type: "template", label: "posts/index.html.erb", duration: 4.0, codebase_location: "app/views/posts/index.html.erb",
          start_time: Time.current.to_f, occurred_at: Time.current }
      ]

      post_batch([ request_item(path: "/posts", operations: operations) ])

      in_application(:alpha) do
        request = RailsPulse::Request.sole
        rows = RailsPulse::Operation.where(request_id: request.id).order(:id)

        assert_equal %w[sql sql template], rows.map(&:operation_type)
        assert_equal [ 2, 2 ], rows.first(2).map(&:repetition_count)
        assert_nil rows.first.actual_sql, "actual_sql is dropped unless the central opts in with capture_actual_sql"
        assert_equal 1, RailsPulse::Query.count
      end
    end

    test "folded requests are rolled up in their own application's database, with its own route ids" do
      # beta's route for /shared gets a different id than alpha's
      in_application(:beta) { RailsPulse::Route.find_or_create_for_request("GET", "/beta-first", controller_action: "beta#first") }

      post_batch([ folded_item(path: "/shared") ], token: ALPHA_TOKEN)
      post_batch([ folded_item(path: "/shared"), folded_item(path: "/shared") ], token: BETA_TOKEN)
      RailsPulse::Tracker.flush_rollups!

      in_application(:alpha) do
        route = RailsPulse::Route.find_by!(path: "/shared")
        rollup = RailsPulse::Rollup.find_by!(rollupable_type: "RailsPulse::Route")

        assert_equal route.id, rollup.rollupable_id
        assert_equal 1, rollup.count
        assert_equal 0, RailsPulse::Request.count
      end
      in_application(:beta) do
        route = RailsPulse::Route.find_by!(path: "/shared")
        rollup = RailsPulse::Rollup.find_by!(rollupable_type: "RailsPulse::Route")

        assert_equal route.id, rollup.rollupable_id
        assert_equal 2, rollup.count
      end
    end

    test "a resent batch is acknowledged without being recorded twice" do
      batch_id = SecureRandom.uuid
      post_batch([ folded_item(path: "/twice") ], batch_id: batch_id)
      post_batch([ folded_item(path: "/twice") ], batch_id: batch_id)

      assert_response 202
      assert response.parsed_body["duplicate"]
      RailsPulse::Tracker.flush_rollups!
      in_application(:alpha) { assert_equal 1, RailsPulse::Rollup.find_by!(rollupable_type: "RailsPulse::Route").count }
    end

    test "the same batch_id from another application is that application's own batch" do
      batch_id = SecureRandom.uuid
      post_batch([ request_item(path: "/a") ], token: ALPHA_TOKEN, batch_id: batch_id)
      post_batch([ request_item(path: "/b") ], token: BETA_TOKEN, batch_id: batch_id)

      assert_not response.parsed_body["duplicate"]
      in_application(:beta) { assert_equal 1, RailsPulse::Request.count }
    end

    test "an uncompressed batch is accepted too" do
      post_batch([ request_item(path: "/plain") ], gzip: false)

      assert_response 202
      in_application(:alpha) { assert_equal 1, RailsPulse::Request.count }
    end

    # Authentication Tests

    test "an unknown token is refused with 401 and nothing is recorded" do
      post_batch([ request_item(path: "/nope") ], token: "z" * 46)

      assert_response 401
      in_application(:alpha) { assert_equal 0, RailsPulse::Request.count }
      in_application(:beta) { assert_equal 0, RailsPulse::Request.count }
    end

    test "a request without a bearer token is refused with 401" do
      post "/rails_pulse/v1/batches", params: "{}", headers: { "Content-Type" => RailsPulse::Remote::Client::CONTENT_TYPE }

      assert_response 401
      assert_equal "unauthorized", response.parsed_body["error"]
    end

    test "an application with no token accepts nothing" do
      applications = RailsPulse.configuration.central.applications.deep_dup
      applications[:beta] = applications[:beta].merge(token: nil)

      with_central_applications(applications) do
        post "/rails_pulse/v1/batches", params: "{}", headers: { "Authorization" => "Bearer " }
      end

      assert_response 401
    end

    # Malformed Batch Tests

    test "a body that is not JSON is refused with 400" do
      post_batch([], body: "not json", gzip: false)

      assert_response 400
    end

    test "a body sent as gzip that is not gzip is refused with 400" do
      post_batch([], body: "{\"version\":1}", gzip: true)

      assert_response 400
    end

    test "another contract version is refused with 422" do
      post_batch([], body: { version: 99, batch_id: SecureRandom.uuid, items: [] }.to_json, gzip: false)

      assert_response 422
      assert_match(/contract version 99/, response.parsed_body["error"])
    end

    test "an envelope without an items array is refused with 422" do
      post_batch([], body: { version: 1, batch_id: SecureRandom.uuid, items: {} }.to_json, gzip: false)

      assert_response 422
    end

    test "an envelope without a usable batch_id is refused with 422" do
      post_batch([], body: { version: 1, batch_id: "not a/valid id", items: [] }.to_json, gzip: false)

      assert_response 422
    end

    test "a body over the size limit is refused with 413" do
      post_batch([], body: "x" * (RailsPulse::Central::BatchesController::MAX_BODY_BYTES + 1), gzip: false)

      assert_response 413
    end

    test "an item that does not match the contract is rejected alone and the rest are recorded" do
      broken = request_item(path: "/broken")
      broken.attributes.delete(:request_uuid)
      unknown = item("telemetry", { anything: 1 })

      post_batch([ broken, request_item(path: "/fine"), unknown ])

      assert_response 202
      body = response.parsed_body

      assert_equal 1, body["accepted"]
      assert_equal 2, body["rejected"]
      assert_includes body["errors"], "items[0] (request): request_uuid is required"
      assert_includes body["errors"], "items[2] (telemetry): has an unknown type \"telemetry\""
      in_application(:alpha) { assert_equal [ "/fine" ], RailsPulse::Route.pluck(:path) }
    end

    test "fields the contract does not define never reach a table" do
      sneaky = request_item(path: "/sneaky", operations: [
        { operation_type: "sql", actual_sql: "SELECT 1", duration: 1.0, start_time: 1.0, occurred_at: Time.current,
          request_id: 999_999, query_id: 999_999, repetition_count: 50, created_at: 10.years.ago }
      ])

      post_batch([ sneaky ])

      in_application(:alpha) do
        operation = RailsPulse::Operation.sole

        assert_equal RailsPulse::Request.sole.id, operation.request_id
        assert_equal RailsPulse::Query.sole.id, operation.query_id
        assert_nil operation.repetition_count
        assert_in_delta Time.current, operation.created_at, 60
      end
    end

    # Edge Cases

    test "an application whose database is behind the gem answers 503 so the sender retries" do
      RailsPulse::SchemaCheck.stubs(:current?).returns(false)

      post_batch([ request_item(path: "/later") ])

      assert_response 503
      in_application(:alpha) { assert_equal 0, RailsPulse::Request.count }
    end

    test "an empty batch is accepted" do
      post_batch([])

      assert_response 202
      assert_equal 0, response.parsed_body["accepted"]
    end

    private

    def request_item(path:, operations: nil)
      item("request", {
        method: "GET", path: path, duration: 120.0, status: 200, controller_action: "posts#index",
        occurred_at: Time.current, is_error: false, request_uuid: SecureRandom.uuid, response_size_bytes: 512,
        operations: operations || [ { operation_type: "sql", label: nil, actual_sql: "SELECT * FROM posts WHERE id = 1",
                                      duration: 3.2, codebase_location: "app/controllers/posts_controller.rb",
                                      start_time: Time.current.to_f, occurred_at: Time.current, row_count: 1 } ]
      })
    end

    def folded_item(path:)
      item("request", {
        method: "GET", path: path, duration: 40.0, status: 200, controller_action: "shared#show",
        occurred_at: Time.current, detail: false,
        operations: [ { operation_type: "sql", actual_sql: "SELECT 1", label: nil, duration: 0.5 } ]
      })
    end

    def with_central_applications(applications)
      original = RailsPulse.configuration.central.applications
      RailsPulse.configuration.central.applications = applications
      yield
    ensure
      RailsPulse.configuration.central.applications = original
    end
  end
end
