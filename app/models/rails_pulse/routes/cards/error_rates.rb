module RailsPulse
  module Routes
    module Cards
      class ErrorRates < RailsPulse::Cards::Base
        def initialize(route: nil, **kwargs)
          super(subject: route, **kwargs)
        end

        def to_metric_card
          # Use base class helper for query construction
          base_query = base_summary_query("RailsPulse::Route")

          metrics = base_query.select(
            "SUM(error_count) AS total_errors",
            "SUM(status_4xx) AS total_4xx",
            "SUM(count) AS total_requests",
            "SUM(CASE WHEN period_start >= #{quote(current_window_start)} THEN error_count + status_4xx ELSE 0 END) AS current_total_errors",
            "SUM(CASE WHEN period_start >= #{quote(range_start)} AND period_start < #{quote(current_window_start)} THEN error_count + status_4xx ELSE 0 END) AS previous_total_errors"
          ).take

          total_errors = metrics.total_errors || 0
          total_4xx = metrics.total_4xx || 0
          total_requests = metrics.total_requests || 0
          current_total = metrics.current_total_errors || 0
          previous_total = metrics.previous_total_errors || 0

          has_data = total_requests > 0

          server_rate = has_data ? (total_errors.to_f / total_requests * 100).round(2) : 0
          client_rate = has_data ? (total_4xx.to_f / total_requests * 100).round(2) : 0

          baseline = baseline_trend_for(@subject, metric: :error_rate)

          if baseline
            trend_icon, trend_amount, trend_caption = baseline
          elsif show_trend?
            trend_icon, trend_amount = has_data ? trend_for(current_total, previous_total) : [ "move-right", "—" ]
          end

          # Build sparkline data as error rate (%) per period
          sparkline_query = build_sparkline_query("RailsPulse::Route")
          grouped_counts = group_sparkline_by_period(sparkline_query, :count)
          grouped_errors = group_sparkline_by_period(sparkline_query, :error_count)
          grouped_4xx    = group_sparkline_by_period(sparkline_query, :status_4xx)
          sparkline_data = sparkline_from_error_rates(grouped_errors, grouped_4xx, grouped_counts)

          total_rate = has_data ? (server_rate + client_rate).round(2) : 0
          summary = has_data ? "#{total_rate}% of requests" : "—"

          {
            id: "error_rates",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "routes",
            title: "Error Rate",
            summary: summary,
            chart_data: sparkline_data,
            sparkline_options: { tooltip: { formatter: "sparkline_percentage_tooltip" } },
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: trend_caption || (show_trend? ? comparison_period_text : nil),
            period_stat: has_data ? "#{format_number(total_errors + total_4xx)} errors" : period_date_range,
            help_heading: "Error Rates",
            help_text: "Combined 5xx and 4xx error rate over the last 2 weeks. 5xx server errors indicate bugs or infrastructure issues. 4xx client errors may indicate broken API consumers or deprecated endpoints."
          }
        end

        private

        def sparkline_from_error_rates(errors_by_period, client_errors_by_period, counts_by_period)
          if @period_type == "hour"
            sparkline_hours.each_with_object({}) do |current_time, result|
              errors = errors_by_period[current_time].to_f + client_errors_by_period[current_time].to_f
              total  = counts_by_period[current_time].to_f
              rate   = total.zero? ? 0.0 : (errors / total * 100).round(2)
              result[current_time.to_i * 1000] = { value: rate }
            end
          else
            sparkline_dates.each_with_object({}) do |day, hash|
              errors = errors_by_period[day].to_f + client_errors_by_period[day].to_f
              total  = counts_by_period[day].to_f
              rate   = total.zero? ? 0.0 : (errors / total * 100).round(2)
              hash[day.strftime("%b %-d")] = { value: rate }
            end
          end
        end
      end
    end
  end
end
