module RailsPulse
  module Api
    module V1
      class QueriesController < BaseController
        SORT_COLUMNS = %w[total_duration avg_duration executions max_duration].freeze

        def index
          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          sort = params[:sort].presence
          if sort && !SORT_COLUMNS.include?(sort)
            return render json: { error: "Invalid sort. Valid values: #{SORT_COLUMNS.join(', ')}" }, status: :bad_request
          end

          if since_start || until_end || sort
            since_start ||= 24.hours.ago if until_end.nil?
            render_with_stats(since_start..until_end, sort || "total_duration")
          else
            data, meta = paginated(RailsPulse::Query.all.order(:id))
            render json: { data: data.map { |query| QuerySerializer.serialize(query) }, meta: meta }
          end
        end

        private

        def render_with_stats(range, sort)
          base = RailsPulse::Operation.where.not(query_id: nil).where(occurred_at: range)
          total = base.distinct.count(:query_id)

          rows = base
            .group(:query_id)
            .select(
              "query_id, COUNT(*) AS executions, AVG(duration) AS avg_duration, " \
              "MAX(duration) AS max_duration, SUM(duration) AS total_duration, " \
              "MAX(repetition_count) AS max_repetition_count"
            )
            .order(Arel.sql("#{sort} DESC"))
            .limit(limit)
            .offset(offset)
            .to_a

          queries = RailsPulse::Query.where(id: rows.map(&:query_id)).index_by(&:id)
          data = rows.filter_map do |row|
            query = queries[row.query_id]
            QuerySerializer.serialize(query, stats: stats_for(row)) if query
          end

          render json: { data: data, meta: { total: total, limit: limit, offset: offset } }
        end

        def stats_for(row)
          {
            executions:           row.executions.to_i,
            avg_duration_ms:      row.avg_duration.to_f.round(1),
            max_duration_ms:      row.max_duration.to_f.round(1),
            total_duration_ms:    row.total_duration.to_f.round(1),
            max_repetition_count: row.max_repetition_count&.to_i
          }
        end
      end
    end
  end
end
