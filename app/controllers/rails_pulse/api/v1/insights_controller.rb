module RailsPulse
  module Api
    module V1
      # What needs attention over one summary period, and whether the
      # configured route, query and job thresholds fit what that period recorded.
      # One period rather than a since/until window because a P95 cannot be
      # combined across periods: an hour, day, week or month is read from its
      # own summary rows.
      class InsightsController < BaseController
        PERIOD_TYPES = RailsPulse::Summary::PERIOD_TYPES
        DEFAULT_PERIOD_TYPE = "week".freeze
        STEPS = { "hour" => 1.hour, "day" => 1.day, "week" => 1.week, "month" => 1.month }.freeze

        def show
          period_type = params[:period].presence || DEFAULT_PERIOD_TYPE
          unless PERIOD_TYPES.include?(period_type)
            return render_bad_request("Unknown period '#{period_type}'. Use one of: #{PERIOD_TYPES.join(', ')}.")
          end

          at = parse_time_param(:at)
          return if performed?

          period_start = period_start_for(period_type, at)
          period_end = RailsPulse::Summary.calculate_period_end(period_type, period_start)

          render json: {
            period: {
              type:       period_type,
              start:      period_start,
              end:        period_end,
              summarized: summarized?(period_type, period_start)
            },
            thresholds: {
              routes:  RailsPulse.configuration.route_thresholds,
              queries: RailsPulse.configuration.query_thresholds,
              jobs:    RailsPulse.configuration.job_thresholds
            },
            needs_attention: RailsPulse::PeriodInsights.new(period_type: period_type, period_start: period_start).to_insights_data,
            threshold_recommendations: RailsPulse::ConfigRecommendations
              .for_period(period_type: period_type, period_start: period_start)
              .to_recommendations
          }
        end

        private

        # The period containing `at`, or the latest one that has ended: the
        # current period has no summary until it is over.
        def period_start_for(period_type, at)
          time = at ? at.in_time_zone : Time.current - STEPS[period_type]
          RailsPulse::Summary.normalize_period_start(period_type, time)
        end

        # SummaryJob writes the overall request row for every period it
        # summarizes, even an empty one.
        def summarized?(period_type, period_start)
          RailsPulse::Summary.overall_requests.exists?(period_type: period_type, period_start: period_start)
        end
      end
    end
  end
end
