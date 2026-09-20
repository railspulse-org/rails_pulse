module RailsPulse
  module Jobs
    module Cards
      class FailureRate < RailsPulse::Cards::Base
        def initialize(job: nil, disabled_tags: [], show_non_tagged: true, period: 14, period_type: "day", start_time: nil, end_time: nil)
          @job = job
          @disabled_tags = disabled_tags
          @show_non_tagged = show_non_tagged
          @period = period
          @period_type = period_type
          @start_time = start_time
          @end_time = end_time
        end

        def to_metric_card
          base_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Job",
              period_type: @period_type,
              period_start: range_start..now
            )
          base_query = base_query.where(summarizable_id: @job.id) if @job

          metrics = base_query.select(
            "SUM(rails_pulse_summaries.count) AS total_count",
            "SUM(rails_pulse_summaries.error_count) AS total_errors",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS current_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.error_count ELSE 0 END) AS current_errors",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS previous_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.error_count ELSE 0 END) AS previous_errors"
          ).take

          total_runs = metrics&.total_count.to_i
          total_errors = metrics&.total_errors.to_i
          current_runs = metrics&.current_count.to_i
          current_errors = metrics&.current_errors.to_i
          previous_runs = metrics&.previous_count.to_i
          previous_errors = metrics&.previous_errors.to_i

          failure_rate = rate_for(total_errors, total_runs)
          current_rate = rate_for(current_errors, current_runs)
          previous_rate = rate_for(previous_errors, previous_runs)

          trend_icon, trend_amount = trend_for(current_rate, previous_rate) if show_trend?

          # Create a separate query for sparkline data using only the current period
          sparkline_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Job",
              period_type: @period_type,
              period_start: current_window_start..now
            )
          sparkline_query = sparkline_query.where(summarizable_id: @job.id) if @job

          grouped_errors = bucket_by_period(sparkline_query) { |relation| relation.sum("rails_pulse_summaries.error_count") }
          grouped_counts = bucket_by_period(sparkline_query) { |relation| relation.sum("rails_pulse_summaries.count") }

          sparkline_data = sparkline_from_failure_rates(grouped_errors, grouped_counts)

          {
            id: "jobs_failure_rate",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "jobs",
            title: "Failure Rate",
            summary: "#{format_percentage(failure_rate, 1)}",
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: total_runs > 0 ? "#{format_number(total_errors)} failures · #{format_number(total_runs)} runs" : period_date_range,
            help_heading: "Failure Rate",
            help_text: "Percentage of job executions that raised an error over the last 14 days. A rising failure rate may indicate bugs, external dependency issues, or jobs receiving invalid data."
          }
        end

        private

        def rate_for(errors, total)
          return 0.0 if total.zero?

          (errors.to_f / total * 100).round(1)
        end

        def sparkline_from_failure_rates(errors_by_period, counts_by_period)
          if @period_type == "hour"
            sparkline_hours.each_with_object({}) do |current_time, result|
              errors = errors_by_period[current_time].to_f
              total = counts_by_period[current_time].to_f
              rate = total.zero? ? 0.0 : (errors / total * 100).round(1)
              # Use timestamp in milliseconds as key to preserve uniqueness across days
              result[current_time.to_i * 1000] = { value: rate }
            end
          else
            sparkline_dates.each_with_object({}) do |day, hash|
              errors = errors_by_period[day].to_f
              total = counts_by_period[day].to_f
              rate = total.zero? ? 0.0 : (errors / total * 100).round(1)
              label = day.strftime("%b %-d")
              hash[label] = { value: rate }
            end
          end
        end
      end
    end
  end
end
