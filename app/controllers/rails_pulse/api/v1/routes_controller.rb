module RailsPulse
  module Api
    module V1
      class RoutesController < BaseController
        SORT_COLUMNS = %w[request_count avg_duration error_count].freeze

        def index
          parsed_range = time_range
          return unless parsed_range
          since_start, until_end = parsed_range

          sort = params[:sort].presence
          if sort && !SORT_COLUMNS.include?(sort)
            return render json: { error: "Invalid sort. Valid values: #{SORT_COLUMNS.join(', ')}" }, status: :bad_request
          end

          scope = RailsPulse::Route.all
          if params[:search].present?
            term = "%#{RailsPulse::Route.sanitize_sql_like(params[:search].downcase)}%"
            scope = scope.where("LOWER(path) LIKE :term OR LOWER(controller_action) LIKE :term", term: term)
          end

          if since_start || until_end || sort
            since_start ||= 24.hours.ago if until_end.nil?
            render_with_stats(scope, since_start..until_end, sort || "request_count")
          else
            data, meta = paginated(scope.order(:path))
            render json: { data: data.map { |route| RouteSerializer.serialize(route) }, meta: meta }
          end
        end

        private

        def render_with_stats(scope, range, sort)
          base = RailsPulse::Request.where(occurred_at: range)
          base = base.where(route_id: scope.select(:id)) if params[:search].present?
          total = base.distinct.count(:route_id)

          # CASE WHEN on the boolean column itself is valid on SQLite, PostgreSQL
          # and MySQL alike, so no adapter-specific literal is interpolated.
          rows = base
            .group(:route_id)
            .select(
              "route_id, COUNT(*) AS request_count, AVG(duration) AS avg_duration, " \
              "SUM(CASE WHEN is_error THEN 1 ELSE 0 END) AS error_count"
            )
            .order(Arel.sql("#{sort} DESC"))
            .limit(limit)
            .offset(offset)
            .to_a

          routes = RailsPulse::Route.where(id: rows.map(&:route_id)).index_by(&:id)
          data = rows.filter_map do |row|
            route = routes[row.route_id]
            RouteSerializer.serialize(route, stats: stats_for(row)) if route
          end

          render json: { data: data, meta: { total: total, limit: limit, offset: offset } }
        end

        def stats_for(row)
          {
            request_count:   row.request_count.to_i,
            avg_duration_ms: row.avg_duration.to_f.round(1),
            error_count:     row.error_count.to_i
          }
        end
      end
    end
  end
end
