module RailsPulse
  module Routes
    module Cards
      class RequestCountTotals < RailsPulse::Cards::Base
        def initialize(route: nil, **kwargs)
          super(subject: route, **kwargs)
        end

        def to_metric_card
          # Use base class helper for query construction
          base_query = base_summary_query("RailsPulse::Route")

          metrics = base_query.select(
            "SUM(count) AS total_count",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN count ELSE 0 END) AS current_count",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN count ELSE 0 END) AS previous_count"
          ).take

          # Calculate metrics from single query result
          total_request_count = metrics.total_count || 0
          current_period_count = metrics.current_count || 0
          previous_period_count = metrics.previous_count || 0

          has_data = total_request_count > 0

          # Use base class trend calculation
          if show_trend?
            trend_icon, trend_amount = has_data ? trend_for(current_period_count, previous_period_count) : [ "move-right", "—" ]
          end

          # Create sparkline query using only the current period
          sparkline_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Route",
              period_type: @period_type,
              period_start: current_window_start..now
            )
          sparkline_query = sparkline_query.where(summarizable_id: @subject.id) if @subject

          grouped_data = bucket_by_period(sparkline_query) { |relation| relation.sum(:count) }

          # Use base class sparkline generation (handles hour vs day automatically)
          sparkline_data = sparkline_from(grouped_data)

          # Calculate appropriate rate display based on frequency
          if has_data
            total_minutes = (period_type_hours? ? (@period * 48).hours : (@period * 2).days) / 1.minute.to_f
            requests_per_minute = total_request_count.to_f / total_minutes

            # Choose appropriate time unit for display
            if requests_per_minute >= 1
              summary = "#{requests_per_minute.round(2)} / min"
            elsif requests_per_minute * 60 >= 1
              requests_per_hour = requests_per_minute * 60
              summary = "#{requests_per_hour.round(2)} / hour"
            else
              requests_per_day = requests_per_minute * 60 * 24
              summary = "#{requests_per_day.round(2)} / day"
            end
          else
            summary = "—"
          end

          {
            id: "request_count_totals",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "routes",
            title: "Request Rate",
            summary: summary,
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: has_data ? "#{format_number(total_request_count)} requests" : period_date_range,
            help_heading: "Request Throughput",
            help_text: "Total HTTP requests served over the last 14 days, expressed as an average rate. Use this to understand traffic patterns and capacity planning needs."
          }
        end
      end
    end
  end
end
