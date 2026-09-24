module RailsPulse
  module Charts
    class Base
      def initialize(ransack_query:, period_type: nil, subject: nil, window: nil, start_duration: nil, disabled_tags: [], show_non_tagged: true)
        @ransack_query = ransack_query
        @period_type = period_type
        @subject = subject
        @window = window
        @start_duration = start_duration
        @disabled_tags = disabled_tags
        @show_non_tagged = show_non_tagged
      end

      private

      # Common helper for building base summary queries with tag filters
      def base_summary_query
        @ransack_query.result(distinct: false)
          .with_tag_filters(@disabled_tags, @show_non_tagged)
          .where(
            summarizable_type: summarizable_type,
            period_type: @period_type
          )
          .then { |q| @subject ? q.where(summarizable_id: @subject.id) : q }
      end

      # Common helper for time step calculation
      def time_step
        @period_type.to_s == "hour" ? 3600 : 86400
      end

      # Abstract method - must be implemented by subclasses
      def summarizable_type
        raise NotImplementedError, "#{self.class} must implement summarizable_type"
      end

      # Common helper for padding missing data points with zeros
      def pad_data_with_zeros(raw_data, start_time, end_time, step)
        {}.tap do |padded|
          (start_time.to_i..end_time.to_i).step(step) do |timestamp|
            padded[timestamp] = raw_data[timestamp] || 0
          end
        end
      end
    end
  end
end
