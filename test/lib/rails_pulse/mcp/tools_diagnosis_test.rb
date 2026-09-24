require "test_helper"
require "rails_pulse/mcp/server"

module RailsPulse
  module Mcp
    class ToolsDiagnosisTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      class StubClient
        attr_reader :calls

        def initialize(responses = {})
          @responses = responses
          @calls = []
        end

        def get(path, params = {})
          @calls << [ path, params ]
          @responses[path] || { "data" => [], "meta" => { "total" => 0, "limit" => 25, "offset" => 0 } }
        end
      end

      QUERIES_RESPONSE = {
        "data" => [
          {
            "id" => 1, "normalized_sql" => "SELECT   *  FROM orders\n WHERE user_id = ?", "issues" => [ "a" ],
            "suggestions" => [ "Add an index on orders.user_id" ],
            "n_plus_one" => { "likely" => true, "confidence" => 80 },
            "stats" => { "executions" => 400, "avg_duration_ms" => 12.5, "max_duration_ms" => 90.0, "total_duration_ms" => 5000.0, "max_repetition_count" => 25 }
          },
          {
            "id" => 2, "normalized_sql" => "SELECT * FROM users WHERE id = ?", "issues" => [], "suggestions" => [],
            "n_plus_one" => { "likely" => false, "confidence" => 0 },
            "stats" => { "executions" => 2000, "avg_duration_ms" => 1.2, "max_duration_ms" => 4.0, "total_duration_ms" => 2400.0, "max_repetition_count" => nil }
          },
          {
            "id" => 3, "normalized_sql" => "SELECT * FROM reports", "issues" => [], "suggestions" => [],
            "n_plus_one" => { "likely" => false, "confidence" => 0 },
            "stats" => { "executions" => 3, "avg_duration_ms" => 350.0, "max_duration_ms" => 900.0, "total_duration_ms" => 1050.0, "max_repetition_count" => nil }
          }
        ],
        "meta" => { "total" => 3, "limit" => 10, "offset" => 0 }
      }.freeze

      JOBS_RESPONSE = {
        "data" => [
          { "id" => 1, "name" => "UserMailerJob", "queue_name" => "mailers", "runs_count" => 100, "failures_count" => 0,
            "avg_duration" => 150.0, "p95_duration" => 200.0, "p99_duration" => 220.0, "failure_rate" => 0.0 },
          { "id" => 2, "name" => "GenerateReportJob", "queue_name" => "default", "runs_count" => 50, "failures_count" => 5,
            "avg_duration" => 45_000.0, "p95_duration" => 70_000.0, "p99_duration" => 90_000.0, "failure_rate" => 10.0 }
        ],
        "meta" => { "total" => 2, "limit" => 100, "offset" => 0 }
      }.freeze

      JOB_RUNS_RESPONSE = {
        "data" => [
          { "id" => 10, "job_name" => "GenerateReportJob", "status" => "failed", "occurred_at" => "2026-06-01T12:00:00Z",
            "error_class" => "Timeout::Error", "error_message" => "x" * 300, "attempts" => 3 },
          { "id" => 11, "job_name" => "GenerateReportJob", "status" => "discarded", "occurred_at" => "2026-06-01T11:00:00Z",
            "error_class" => "Timeout::Error", "error_message" => "expired", "attempts" => 5 },
          { "id" => 12, "job_name" => "GenerateReportJob", "status" => "failed", "occurred_at" => "2026-06-01T10:00:00Z",
            "error_class" => nil, "error_message" => nil, "attempts" => 1 }
        ],
        "meta" => { "total" => 3, "limit" => 100, "offset" => 0 }
      }.freeze

      ROUTES_RESPONSE = {
        "data" => [
          { "id" => 1, "http_methods" => [ "GET" ], "path" => "/", "controller_action" => "HomeController#index", "tags" => nil,
            "stats" => { "request_count" => 500, "avg_duration_ms" => 120.0, "error_count" => 0 } },
          { "id" => 2, "http_methods" => [ "POST" ], "path" => "/checkout", "controller_action" => "CheckoutController#create", "tags" => nil,
            "stats" => { "request_count" => 40, "avg_duration_ms" => 900.0, "error_count" => 3 } },
          { "id" => 3, "http_methods" => [ "GET" ], "path" => "/rails/active_storage/blobs", "controller_action" => nil, "tags" => nil,
            "stats" => { "request_count" => 10, "avg_duration_ms" => 5.0, "error_count" => 0 } }
        ],
        "meta" => { "total" => 3, "limit" => 50, "offset" => 0 }
      }.freeze

      def client(responses = {})
        StubClient.new(responses)
      end

      def call(tool, client, **args)
        result = tool.call(**args, server_context: { client: client })
        [ result, JSON.parse(result.content.first[:text]) ]
      end

      def error_client
        Object.new.tap do |c|
          def c.get(*, **)
            raise CLI::Client::ApiError, "500 Internal Server Error"
          end
        end
      end

      # --- Queries ---

      test "queries passes since, sort, and clamped limit to the API" do
        c = client("/queries" => QUERIES_RESPONSE)
        call(Tools::Queries, c, period: "last_hour", limit: 500, sort: "executions")

        path, params = c.calls.first

        assert_equal "/queries", path
        assert_equal 50, params[:limit]
        assert_equal "executions", params[:sort]
        assert_in_delta Time.now - 3600, Time.iso8601(params[:since]), 5
      end

      test "queries formats stats, compacts SQL, and flags N+1" do
        _, data = call(Tools::Queries, client("/queries" => QUERIES_RESPONSE))
        first = data["queries"].first

        assert_equal 3, data["total_queries"]
        assert_equal "SELECT * FROM orders WHERE user_id = ?", first["sql"]
        assert_equal 400, first["executions"]
        assert_in_delta 5000.0, first["total_duration_ms"]
        assert first["n_plus_one"]["likely"]
        assert_equal 25, first["n_plus_one"]["max_repetition_count"]
        assert_equal 1, first["issue_count"]
        assert_equal [ "Add an index on orders.user_id" ], first["suggestions"]
        assert_nil data["queries"].last["n_plus_one"]["max_repetition_count"]
      end

      test "queries n_plus_one_only filters and summary mentions N+1" do
        _, data = call(Tools::Queries, client("/queries" => QUERIES_RESPONSE), n_plus_one_only: true)

        assert_equal [ 1 ], data["queries"].map { |q| q["id"] }
        assert_includes data["summary"], "1 likely N+1 query"
        assert data["next_steps"].any? { |s| s.include?("preload") }
      end

      test "queries next_steps cover slow and very frequent queries" do
        _, data = call(Tools::Queries, client("/queries" => QUERIES_RESPONSE))

        assert data["next_steps"].any? { |s| s.include?("EXPLAIN") }
        assert data["next_steps"].any? { |s| s.include?("caching") }
      end

      test "queries handles no data" do
        _, data = call(Tools::Queries, client)

        assert_empty data["queries"]
        assert_includes data["summary"], "No query activity"
      end

      test "queries handles API error" do
        result = Tools::Queries.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end

      # --- Jobs ---

      test "jobs combines aggregates with recent failures" do
        c = client("/jobs" => JOBS_RESPONSE, "/job_runs" => JOB_RUNS_RESPONSE)
        _, data = call(Tools::Jobs, c)

        assert_equal %w[GenerateReportJob UserMailerJob], data["jobs"].map { |j| j["name"] }
        assert_in_delta 10.0, data["jobs"].first["failure_rate"]

        failure = data["recent_failures"].first

        assert_equal "GenerateReportJob", failure["job"]
        assert_equal 3, failure["count"]
        assert_equal({ "Timeout::Error" => 2, "unknown" => 1 }, failure["error_classes"])
        assert_equal "2026-06-01T12:00:00Z", failure["latest"]["occurred_at"]
        assert_equal 203, failure["latest"]["error_message"].length
        assert_includes data["summary"], "3 failed run(s)"
        assert_includes data["summary"], "GenerateReportJob (10.0%)"
      end

      test "jobs passes job filter and period to job_runs" do
        c = client("/jobs" => JOBS_RESPONSE, "/job_runs" => JOB_RUNS_RESPONSE)
        _, data = call(Tools::Jobs, c, job: "UserMailerJob", period: "last_7_days", limit: 0)

        run_call = c.calls.find { |path, _| path == "/job_runs" }

        assert_equal "UserMailerJob", run_call[1][:job]
        assert_equal "failed", run_call[1][:status]
        assert_equal [ "UserMailerJob" ], data["jobs"].map { |j| j["name"] }
      end

      test "jobs next_steps flag failure rates, slow jobs, and errors" do
        _, data = call(Tools::Jobs, client("/jobs" => JOBS_RESPONSE, "/job_runs" => JOB_RUNS_RESPONSE))

        assert data["next_steps"].any? { |s| s.include?("failure rate above 5%") }
        assert data["next_steps"].any? { |s| s.include?("p95 over 60s") }
        assert data["next_steps"].any? { |s| s.include?("error_class") }
      end

      test "jobs handles no jobs tracked" do
        _, data = call(Tools::Jobs, client)

        assert_includes data["summary"], "No background jobs"
        assert data["next_steps"].any? { |s| s.include?("track_jobs") }
      end

      test "jobs handles API error" do
        result = Tools::Jobs.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end

      # --- Routes ---

      test "routes lists routes with stats and discovery next_steps" do
        c = client("/routes" => ROUTES_RESPONSE)
        _, data = call(Tools::Routes, c, period: "last_24_hours", limit: 1000, sort: "avg_duration")

        _, params = c.calls.first

        assert_equal 100, params[:limit]
        assert_equal "avg_duration", params[:sort]
        assert_equal 3, data["total_routes"]
        assert_equal "CheckoutController#create", data["routes"][1]["controller_action"]
        assert_equal 40, data["routes"][1]["request_count"]
        assert_includes data["summary"], "Busiest: HomeController#index (500 requests)"
        assert_includes data["summary"], "Slowest: CheckoutController#create"
        assert data["next_steps"].any? { |s| s.include?("rails_pulse_endpoint") }
      end

      test "routes search is passed to the API and applied client-side" do
        c = client("/routes" => ROUTES_RESPONSE)
        _, data = call(Tools::Routes, c, search: "checkout")

        assert_equal "checkout", c.calls.first[1][:search]
        assert_equal [ "/checkout" ], data["routes"].map { |r| r["path"] }
      end

      test "routes summary explains empty results with and without search" do
        _, without = call(Tools::Routes, client)
        _, with = call(Tools::Routes, client, search: "nothing")

        assert_includes without["summary"], "No routes had traffic"
        assert_includes with["summary"], "matching 'nothing'"
      end

      test "routes handles API error" do
        result = Tools::Routes.call(server_context: { client: error_client })

        assert_predicate result, :error?
      end
    end
  end
end
