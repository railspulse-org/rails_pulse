module RailsPulse
  module Api
    module V1
      class QuerySerializer
        def self.serialize(query, stats: nil)
          analysis = (query.n_plus_one_analysis || {}).transform_keys(&:to_s)

          {
            id:             query.id,
            normalized_sql: query.normalized_sql,
            hashed_sql:     query.hashed_sql,
            analyzed_at:    query.analyzed_at,
            issues:         query.issues,
            suggestions:    query.suggestions,
            n_plus_one:     {
              likely:     analysis["is_likely_n_plus_one"] == true,
              confidence: analysis["confidence_score"]
            },
            stats:          stats
          }
        end
      end
    end
  end
end
