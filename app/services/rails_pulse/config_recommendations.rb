module RailsPulse
  # Suggests retuning route_thresholds, query_thresholds and job_thresholds
  # when one summary period shows them to be out of step with the
  # application: a slow threshold most of the slowest routes, queries or jobs
  # exceed only adds noise, and a critical threshold nothing came within half
  # of will never fire.
  #
  # Reads the period's ten slowest routes and jobs (by P95) and ten most
  # expensive queries (by total time). The query critical check also reads
  # the period's highest query P95, because a rarely run slow query is not
  # among the most expensive yet is exactly what a critical threshold must
  # catch. Each recommendation carries a config_snippet that keeps the
  # threshold keys it does not change.
  #
  # A recommendation is only emitted when its suggestion actually moves the
  # threshold the way the text says and keeps slow < very_slow < critical in
  # order: a "lower your critical threshold" snippet that repeats or raises
  # the current value, or merges the very_slow and critical bands, would be
  # worse than silence.
  class ConfigRecommendations
    SAMPLE_SIZE = 10

    # How each kind is named in the text, the setting it tunes, and the steps
    # suggested slow and critical thresholds round up to.
    KINDS = {
      route: {
        label: "Route", plural: "routes", setting: :route_thresholds, slow_step: 50, critical_step: 500,
        slow_note: ", which may generate more noise than signal in the Needs Attention section",
        critical_note: " Lowering it helps surface real regressions before they become user-visible."
      },
      query: { label: "Query", plural: "queries", setting: :query_thresholds, slow_step: 10, critical_step: 100 },
      job:   { label: "Job", plural: "jobs", setting: :job_thresholds, slow_step: 500, critical_step: 5_000 }
    }.freeze

    def self.for_period(period_type:, period_start:)
      period = RailsPulse::Summary.where(period_type: period_type, period_start: period_start)

      route_rows = sample(period.for_routes.order(p95_duration: :desc))
      query_rows = sample(period.for_queries.order(Arel.sql("rails_pulse_summaries.count * rails_pulse_summaries.avg_duration DESC")))
      job_rows   = sample(period.for_jobs.order(p95_duration: :desc))

      query_max_p95 = period.for_queries.maximum(:p95_duration)&.round(0)

      new(route_rows: route_rows, query_rows: query_rows, query_max_p95: query_max_p95, job_rows: job_rows)
    end

    def self.sample(scope)
      scope.limit(SAMPLE_SIZE).pluck(:p95_duration).map { |p95| { p95_duration: p95&.round(0) } }
    end
    private_class_method :sample

    # query_max_p95 is the period's highest query P95; without it the
    # highest among query_rows stands in. Routes and jobs are sampled by P95,
    # so their first row is already the period's highest.
    def initialize(route_rows:, query_rows:, query_max_p95: nil, job_rows: [])
      @rows          = { route: route_rows, query: query_rows, job: job_rows }
      @query_max_p95 = query_max_p95
    end

    def to_recommendations
      KINDS.keys.flat_map { |kind| recommendations_for(kind) }
    end

    private

    def recommendations_for(kind)
      rows = @rows[kind]
      return [] if rows.size < 3

      spec       = KINDS[kind]
      thresholds = RailsPulse.configuration.public_send(spec[:setting])
      slow       = thresholds[:slow].to_i
      very_slow  = thresholds[:very_slow].to_i
      critical   = thresholds[:critical].to_i
      p95s       = rows.map { |r| r[:p95_duration].to_i }
      above_slow = p95s.count { |p| p >= slow }
      max_p95    = ((kind == :query && @query_max_p95) || p95s.max).to_i
      recs       = []

      suggested = ceil_to(slow * 1.5, spec[:slow_step])
      if above_slow >= 3 && above_slow.to_f / rows.size >= 0.4 && suggested < very_slow
        recs << {
          title:          "#{spec[:label]} slow threshold may be too low",
          detail:         "#{above_slow} of #{rows.size} sampled #{spec[:plural]} exceeded the #{slow}ms slow " \
                          "threshold this period#{spec[:slow_note]}.",
          config_snippet: snippet(spec[:setting], thresholds, slow: suggested)
        }
      end

      suggested = [ ceil_to(max_p95 * 2.0, spec[:critical_step]), slow * 3, very_slow + spec[:critical_step] ].max
      if max_p95 > 0 && max_p95 < critical / 2 && suggested < critical
        recs << {
          title:          "#{spec[:label]} critical threshold may be too permissive",
          detail:         "No #{spec[:label].downcase} came close to the #{critical}ms critical threshold this period " \
                          "(highest P95: #{max_p95}ms).#{spec[:critical_note]}",
          config_snippet: snippet(spec[:setting], thresholds, critical: suggested)
        }
      end

      recs
    end

    # The whole hash, so pasting the line does not drop very_slow.
    def snippet(setting, current, **changes)
      pairs = current.merge(changes).map { |key, value| "#{key}: #{value}" }
      "config.#{setting} = { #{pairs.join(', ')} }"
    end

    # Round value up to the nearest multiple of step.
    def ceil_to(value, step)
      (value.to_f / step).ceil * step
    end
  end
end
