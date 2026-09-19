module RailsPulse
  module Jobs
    module Cards
      class P95Duration < RailsPulse::Cards::Base
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
            "SUM(rails_pulse_summaries.p95_duration * rails_pulse_summaries.count) AS total_weighted_p95",
            "SUM(rails_pulse_summaries.count) AS total_runs",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.p95_duration * rails_pulse_summaries.count ELSE 0 END) AS current_weighted_p95",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS current_runs",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.p95_duration * rails_pulse_summaries.count ELSE 0 END) AS previous_weighted_p95",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS previous_runs"
          ).take

          total_runs = metrics&.total_runs.to_i
          total_weighted_p95 = metrics&.total_weighted_p95.to_f
          current_runs = metrics&.current_runs.to_i
          current_weighted_p95 = metrics&.current_weighted_p95.to_f
          previous_runs = metrics&.previous_runs.to_i
          previous_weighted_p95 = metrics&.previous_weighted_p95.to_f

          p95_duration = weighted_average(total_weighted_p95, total_runs)
          current_p95 = weighted_average(current_weighted_p95, current_runs)
          previous_p95 = weighted_average(previous_weighted_p95, previous_runs)

          baseline = baseline_trend_for(@job, metric: :p95)

          if baseline
            trend_icon, trend_amount, trend_caption = baseline
          elsif show_trend?
            trend_icon, trend_amount = trend_for(current_p95, previous_p95)
          end

          grouped_weighted = bucket_by_period(base_query) { |relation| relation.sum(Arel.sql("rails_pulse_summaries.p95_duration * rails_pulse_summaries.count")) }
          grouped_counts = bucket_by_period(base_query) { |relation| relation.sum("rails_pulse_summaries.count") }

          sparkline_data = sparkline_from_averages(grouped_weighted, grouped_counts)

          {
            id: "jobs_p95_duration",
            chart_color: RailsPulse::ChartColors::P95,
            context: "jobs",
            title: "95th Percentile Duration",
            summary: format_duration(p95_duration),
            chart_data: sparkline_data,
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: trend_caption || (show_trend? ? comparison_period_text : nil),
            period_stat: total_runs > 0 ? "Across #{format_number(total_runs)} runs" : period_date_range,
            help_heading: "P95 Duration",
            help_text: "The 95th percentile execution time — 95% of jobs complete faster than this. Weighted by job volume across all classes. A rising P95 indicates jobs are becoming slower, which may cause queue backlog."
          }
        end

        private

        def weighted_average(weighted_duration, total_runs)
          return 0.0 if total_runs.zero?

          (weighted_duration.to_f / total_runs).round(1)
        end

        def sparkline_from_averages(weighted_by_day, counts_by_day)
          start_date = current_window_start.to_date
          end_date = now.to_date

          (start_date..end_date).each_with_object({}) do |day, hash|
            weighted = weighted_by_day[day].to_f
            count = counts_by_day[day].to_f
            avg = count.zero? ? 0.0 : (weighted / count).round(1)
            label = day.strftime("%b %-d")
            hash[label] = { value: avg }
          end
        end
      end
    end
  end
end
