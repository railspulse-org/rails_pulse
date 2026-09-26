require "test_helper"

module RailsPulse
  module Api
    module V1
      class QuerySerializerTest < ActiveSupport::TestCase
        test "serializes all expected fields" do
          query = rails_pulse_queries(:analyzed_query)
          result = QuerySerializer.serialize(query)

          assert_equal query.id,             result[:id]
          assert_equal query.normalized_sql, result[:normalized_sql]
          assert_equal query.hashed_sql,     result[:hashed_sql]
          assert_equal query.analyzed_at,    result[:analyzed_at]
          assert_equal query.issues,         result[:issues]
          assert_equal query.suggestions,    result[:suggestions]
        end

        test "returns a hash with exactly the expected keys" do
          result = QuerySerializer.serialize(rails_pulse_queries(:simple_query))

          assert_equal %i[id normalized_sql hashed_sql analyzed_at issues suggestions n_plus_one stats], result.keys
        end

        test "handles nil analyzed_at for unanalyzed queries" do
          result = QuerySerializer.serialize(rails_pulse_queries(:simple_query))

          assert_nil result[:analyzed_at]
          assert_nil result[:stats]
          assert_equal({ likely: false, confidence: nil }, result[:n_plus_one])
        end

        test "exposes n_plus_one analysis and passes stats through" do
          query = rails_pulse_queries(:analyzed_query)
          query.update!(n_plus_one_analysis: { is_likely_n_plus_one: true, confidence_score: 80 })
          stats = { executions: 3, avg_duration_ms: 10.0 }

          result = QuerySerializer.serialize(query.reload, stats: stats)

          assert_equal({ likely: true, confidence: 80 }, result[:n_plus_one])
          assert_equal stats, result[:stats]
        end
      end
    end
  end
end
