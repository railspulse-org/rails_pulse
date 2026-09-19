module RailsPulse
  class TagFilterService
    # Filters IDs for a given model based on disabled tags and non-tagged visibility
    # @param model_class [Class] The model class (Route, Query, or Job)
    # @param disabled_tags [Array<String>] Tags to exclude
    # @param show_non_tagged [Boolean] Whether to include non-tagged items
    # @return [Array<Integer>] Filtered IDs
    def self.filter_ids(model_class, disabled_tags, show_non_tagged)
      scope(model_class, disabled_tags, show_non_tagged).pluck(:id)
    end

    # The same filter as a relation, for use as a subquery. Summary
    # .with_tag_filters embeds it in an IN (SELECT id ...) so the database
    # applies the tag filter itself instead of the app plucking every route,
    # query and job id and sending them back inline on each card's query.
    # @return [ActiveRecord::Relation]
    def self.scope(model_class, disabled_tags, show_non_tagged)
      relation = model_class.all

      # Exclude items with disabled tags. Explicit ESCAPE: SQLite has no
      # default escape character, so without it an underscore in a tag is
      # never matched literally there and the exclusion matches nothing.
      disabled_tags.each do |tag|
        sanitized_tag = ActiveRecord::Base.sanitize_sql_like(tag.to_s, RailsPulse::Taggable::LIKE_ESCAPE)
        relation = relation.where.not("tags LIKE ? ESCAPE '!'", "%#{sanitized_tag}%")
      end

      # Exclude non-tagged items if show_non_tagged is false
      unless show_non_tagged
        relation = relation.where("tags IS NOT NULL AND tags != '[]'")
      end

      relation
    end

    # Main entry point for tag filtering
    # @param disabled_tags [Array<String>] Tags to filter out
    # @param show_non_tagged [Boolean] Whether to show items without tags
    # @return [Hash] Hash with :route_ids, :query_ids, :job_ids keys
    def self.filter_all(disabled_tags, show_non_tagged)
      # Separate "non_tagged" from actual tags (it's a virtual tag)
      actual_disabled_tags = (disabled_tags || []).reject { |tag| tag == "non_tagged" }

      {
        route_ids: filter_ids(Route, actual_disabled_tags, show_non_tagged),
        query_ids: filter_ids(Query, actual_disabled_tags, show_non_tagged),
        job_ids: filter_ids(Job, actual_disabled_tags, show_non_tagged)
      }
    end
  end
end
