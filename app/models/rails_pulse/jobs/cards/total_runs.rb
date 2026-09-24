module RailsPulse
  module Jobs
    module Cards
      class TotalRuns < RailsPulse::Cards::Base
        def initialize(job: nil, period: 14, **kwargs)
          super(subject: job, period: period, **kwargs)
        end

        def to_metric_card
          base_query = RailsPulse::Summary
            .with_tag_filters(@disabled_tags, @show_non_tagged)
            .where(
              summarizable_type: "RailsPulse::Job",
              period_type: @period_type,
              period_start: range_start..now
            )
          base_query = base_query.where(summarizable_id: @subject.id) if @subject

          metrics = base_query.select(
            "SUM(rails_pulse_summaries.count) AS total_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS current_count",
            "SUM(CASE WHEN rails_pulse_summaries.period_start >= #{quote(range_start)} AND rails_pulse_summaries.period_start < #{quote(current_window_start)} THEN rails_pulse_summaries.count ELSE 0 END) AS previous_count"
          ).take

          total_runs = metrics&.total_count.to_i
          current_runs = metrics&.current_count.to_i
          previous_runs = metrics&.previous_count.to_i

          trend_icon, trend_amount = trend_for(current_runs, previous_runs) if show_trend?

          grouped_runs = bucket_by_period(base_query) { |relation| relation.sum("rails_pulse_summaries.count") }

          {
            id: "jobs_total_runs",
            chart_color: RailsPulse::ChartColors::DEFAULT,
            context: "jobs",
            title: "Job Runs",
            summary: "#{format_number(total_runs)} runs",
            chart_data: sparkline_from(grouped_runs),
            trend_icon: trend_icon,
            trend_amount: trend_amount,
            trend_text: (show_trend? ? comparison_period_text : nil),
            period_stat: period_date_range,
            help_heading: "Job Runs",
            help_text: "Total background job executions over the last 14 days. Includes all job classes and queues. Use this to understand job throughput and spot unexpected spikes or drops in processing volume."
          }
        end
      end
    end
  end
end
