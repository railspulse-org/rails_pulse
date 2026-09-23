module RailsPulse
  module Tables
    class Base
      WEIGHTED_P95 = "SUM(rails_pulse_summaries.p95_duration * rails_pulse_summaries.count) / NULLIF(SUM(rails_pulse_summaries.count), 0)"
      WEIGHTED_P99 = "SUM(rails_pulse_summaries.p99_duration * rails_pulse_summaries.count) / NULLIF(SUM(rails_pulse_summaries.count), 0)"

      def initialize(ransack_query:, period_type: nil, params:, disabled_tags: [], show_non_tagged: true)
        @ransack_query = ransack_query
        @period_type = period_type
        @params = params
        @disabled_tags = disabled_tags
        @show_non_tagged = show_non_tagged
      end

      def to_table
        has_sorts = @ransack_query.sorts.any?

        base_query = @ransack_query.result(distinct: false).reorder(nil)
          .joins(join_clause)
          .where(summarizable_type: summarizable_type, period_type: @period_type)

        base_query = apply_tag_filters(base_query)
        base_query = apply_extra_filters(base_query)

        grouped_query = base_query
          .group(*group_columns)
          .select(*select_columns)

        if has_sorts
          sort = @ransack_query.sorts.first
          direction = sort.dir == "desc" ? :desc : :asc
          named_sort(grouped_query, sort.name, direction) || grouped_query.order(default_sort)
        else
          grouped_query.order(default_sort)
        end
      end

      private

      def apply_tag_filters(query)
        actual_disabled_tags = @disabled_tags.reject { |tag| tag == "non_tagged" }

        # Explicit ESCAPE: SQLite has no default escape character, so without
        # it an underscore in a tag is never matched literally there.
        actual_disabled_tags.each do |tag|
          sanitized_tag = ActiveRecord::Base.sanitize_sql_like(tag.to_s, RailsPulse::Taggable::LIKE_ESCAPE)
          query = query.where.not("#{model_table}.tags LIKE ? ESCAPE '!'", "%#{sanitized_tag}%")
        end

        unless @show_non_tagged
          query = query.where("#{model_table}.tags IS NOT NULL AND #{model_table}.tags != '[]'")
        end

        query
      end

      def apply_extra_filters(query) = query

      def join_clause
        raise NotImplementedError
      end

      def summarizable_type
        raise NotImplementedError
      end

      def model_table
        raise NotImplementedError
      end

      def group_columns
        raise NotImplementedError
      end

      def select_columns
        raise NotImplementedError
      end

      def named_sort(_grouped_query, _sort_name, _direction)
        raise NotImplementedError
      end

      def default_sort
        raise NotImplementedError
      end
    end
  end
end
