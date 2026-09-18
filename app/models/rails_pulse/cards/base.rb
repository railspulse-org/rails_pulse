require "active_support/number_helper"

module RailsPulse
  module Cards
    class Base
      private

      # nil unless the caller passed both start_time and end_time, so the
      # "trailing @period days/hours" fallback below still applies by default.
      def time_window
        return @time_window if defined?(@time_window)

        @time_window = RailsPulse::TimeWindow.build(@start_time, @end_time)
      end

      def now
        @now ||= time_window&.end_time || Time.current
      end

      def window_days
        time_window&.days || @period || 7
      end

      def period_type_hours?
        @period_type == "hour"
      end

      # Enhanced time period helpers (support hour and day)
      def previous_window_start
        if time_window
          time_window.previous(period_type_hours? ? "hour" : "day").start_time
        elsif period_type_hours?
          (now - (window_days * 48).hours).beginning_of_hour
        else
          (now - (window_days * 2).days).beginning_of_day
        end
      end

      def current_window_start
        if time_window
          time_window.start_time
        elsif period_type_hours?
          (now - (window_days * 24).hours).beginning_of_hour
        else
          (now - window_days.days).beginning_of_day
        end
      end

      def show_trend?
        window_days <= 14
      end

      def range_start
        show_trend? ? previous_window_start : current_window_start
      end

      # Base query helper for common summary query pattern
      def base_summary_query(summarizable_type)
        query = RailsPulse::Summary.where(
          summarizable_type: summarizable_type,
          period_type: @period_type || "day",
          period_start: range_start..now
        )

        # Apply tag filters if available
        if respond_to?(:disabled_tags, true) && respond_to?(:show_non_tagged, true)
          query = query.with_tag_filters(@disabled_tags, @show_non_tagged)
        end

        # Filter to specific resource if provided
        query = query.where(summarizable_id: subject_id) if subject_id

        query
      end

      def subject_id
        # Subclasses can override to provide @job.id, @query.id, @route.id
        instance_variable_get(:@job)&.id ||
          instance_variable_get(:@query)&.id ||
          instance_variable_get(:@route)&.id
      end

      def quote(time)
        RailsPulse::Summary.connection.quote(time)
      end

      # Enhanced sparkline generation (support hour and day)
      def sparkline_from(grouped_values)
        if period_type_hours?
          build_hourly_sparkline(grouped_values)
        else
          build_daily_sparkline(grouped_values)
        end
      end

      def build_hourly_sparkline(grouped_values)
        sparkline_hours.each_with_object({}) do |current_time, hash|
          # Use timestamp in milliseconds for JS compatibility
          hash[current_time.to_i * 1000] = { value: grouped_values[current_time] || 0 }
        end
      end

      def build_daily_sparkline(grouped_values)
        sparkline_dates.each_with_object({}) do |day, hash|
          hash[day.strftime("%b %-d")] = { value: grouped_values[day] || 0 }
        end
      end

      # Subclasses can override to customize sparkline start date
      # Default: show only current window (period days)
      # Override to range_start for full 2*period view
      def sparkline_start
        current_window_start
      end

      # Every calendar date in the sparkline window. Via TimeWindow, so a
      # range not starting on a day boundary skips the leading partial day.
      def sparkline_dates
        time_window&.dates || (sparkline_start.to_date..now.to_date).to_a
      end

      # Same skip-partial semantics as sparkline_dates, for hours.
      def sparkline_hours
        time_window&.hour_starts || begin
          start_time = sparkline_start.beginning_of_hour
          end_time = now.beginning_of_hour
          hours = []
          current_time = start_time
          while current_time <= end_time
            hours << current_time
            current_time += 1.hour
          end
          hours
        end
      end

      # Build sparkline query with tag filters and optional subject filter
      def build_sparkline_query(summarizable_type)
        sparkline_query = RailsPulse::Summary
          .with_tag_filters(@disabled_tags, @show_non_tagged)
          .where(
            summarizable_type: summarizable_type,
            period_type: @period_type,
            period_start: current_window_start..now
          )
        sparkline_query = sparkline_query.where(summarizable_id: subject_id) if subject_id
        sparkline_query
      end

      # Group sparkline query by period type (hour or day)
      def group_sparkline_by_period(sparkline_query, sum_field)
        if period_type_hours?
          sparkline_query.group_by_hour(:period_start).sum(sum_field)
        else
          sparkline_query.group_by_date(:period_start).sum(sum_field)
        end
      end

      def period_date_range
        start_date = sparkline_dates.first || current_window_start.to_date
        end_date = now.to_date
        if start_date.year == end_date.year
          "#{start_date.strftime("%b %-d")} – #{end_date.strftime("%b %-d")}"
        else
          "#{start_date.strftime("%b %-d, %Y")} – #{end_date.strftime("%b %-d, %Y")}"
        end
      end

      def comparison_period_text
        if period_type_hours?
          "Compared to previous 24 hours"
        else
          case window_days
          when 1  then "Compared to previous day"
          when 7  then "Compared to previous 7 days"
          when 14 then "Compared to previous 14 days"
          when 30 then "Compared to previous 30 days"
          else         "Compared to previous #{window_days} days"
          end
        end
      end

      # Existing trend calculation (keep as-is)
      def trend_for(current_value, previous_value, precision: 1)
        percentage = previous_value.zero? ? 0.0 : ((current_value - previous_value) / previous_value.to_f * 100).round(precision)

        icon = if percentage.abs < 0.1
          "move-right"
        elsif percentage.positive?
          "trending-up"
        else
          "trending-down"
        end

        [ icon, format_percentage(percentage.abs, precision) ]
      end

      # Compares a subject against its own history rather than against the
      # immediately preceding window.
      #
      # The period-over-period arrow above answers "is this week worse than last
      # week?", which is noisy — last week may itself have been unusual. This
      # answers "is this worse than how this normally behaves?", which is the
      # question the number is actually being read for.
      #
      # Only available where there is a single subject to have a history. Index
      # pages aggregate across every route or query, so they keep the
      # period-over-period arrow.
      #
      # @return [Array(String, String, String), nil] icon, amount, caption
      def baseline_trend_for(subject, metric:)
        return nil if subject.nil?

        comparison = RailsPulse::Operations::Compare.call(subject, metric: metric)
        return nil unless comparison.sufficient_data?

        percentage = comparison.percent_change

        icon = if percentage.abs < 0.1
          "move-right"
        elsif percentage.positive?
          "trending-up"
        else
          "trending-down"
        end

        [ icon, format_percentage(percentage.abs, 1), baseline_caption(comparison) ]
      end

      # Names the change point only when there is a regression to explain. On a
      # healthy metric "since Aug 26" would be noise, and locating it costs a
      # second query that is not worth spending to say nothing.
      def baseline_caption(comparison)
        caption = "Compared to its #{baseline_window_text} normal"
        return caption unless comparison.regression?

        change_point = RailsPulse::Operations::ChangePoint.call(
          comparison.subject, metric: comparison.metric
        )
        return caption if change_point.nil?

        stamp = change_point.hourly? ? change_point.at.strftime("%b %-d %H:%M") : change_point.at.strftime("%b %-d")
        "#{caption} · since #{stamp}"
      end

      def baseline_window_text
        days = (RailsPulse.configuration.baseline_window / 1.day).round
        "#{days}-day"
      end

      # Existing format helpers (keep as-is)
      def format_percentage(value, precision = 1)
        "#{value.round(precision)}%"
      end

      def format_number(value)
        ActiveSupport::NumberHelper.number_to_delimited(value)
      end

      def format_duration(value)
        "#{value.round(0)} ms"
      end
    end
  end
end
