module RailsPulse
  # Resolves the dashboard's time range, chart-zoom/table window, and
  # duration-threshold filter from request params and session state, in one
  # pass. Returns a single frozen Result so every caller — controllers,
  # views, cards, charts — reads the same object instead of each re-deriving
  # its own answer.
  #
  # Priority order for the chart/page window (highest first):
  #   1. Page-specific preset from the dropdown (params[:q][:period_start_range])
  #   2. Page-specific custom range from the picker (params[:q][:custom_date_range])
  #   3. Chart zoom / drill-down params (params[:q][:occurred_at_gteq/_lt])
  #   4. Time range selector preference (session[:time_range_preference])
  #   5. Global filters (session[:global_filters]["start_time"/"end_time"])
  #   6. Default (default_key)
  #
  # Every input is parsed in Time.zone, matching how Summary rows are
  # bucketed — parsing a custom-range string in any other zone would
  # misinterpret the intended instant whenever that zone differs from
  # Time.zone, silently resolving to the wrong window.
  class TimeRange
    Result = Struct.new(
      :window, :table_window, :period_type, :selected_time_range,
      :zoom_start, :zoom_end, :start_duration, :selected_response_range,
      keyword_init: true
    )

    PRESET_START = {
      "last_24_hours" => -> { 1.day.ago },
      "last_7_days"   => -> { 1.week.ago },
      "last_14_days"  => -> { 2.weeks.ago },
      "last_30_days"  => -> { 1.month.ago }
    }.freeze

    def self.resolve(params:, session:, default_key: :last_24_hours, duration_range_type: :route)
      new(params: params, session: session, default_key: default_key, duration_range_type: duration_range_type).resolve
    end

    def initialize(params:, session:, default_key:, duration_range_type:)
      @params = params
      @session = session
      @default_key = default_key
      @duration_range_type = duration_range_type
    end

    def resolve
      start_time, end_time, selected_time_range = resolve_window
      start_time, end_time, time_diff_hours = normalize(start_time, end_time)
      period_type = time_diff_hours <= 25 ? "hour" : "day"

      zoom_start, zoom_end, table_start, table_end = resolve_zoom(start_time.to_i, end_time.to_i)
      start_duration, selected_response_range = resolve_duration

      Result.new(
        window: RailsPulse::TimeWindow.new(start_time, end_time),
        table_window: RailsPulse::TimeWindow.new(table_start, table_end),
        period_type: period_type,
        selected_time_range: selected_time_range.to_s,
        zoom_start: zoom_start,
        zoom_end: zoom_end,
        start_duration: start_duration,
        selected_response_range: selected_response_range
      ).freeze
    end

    private

    attr_reader :params, :session, :default_key, :duration_range_type

    # -- Window resolution (priorities 1-6) ----------------------------------

    def resolve_window
      from_page_preset || from_page_custom_range || from_chart_zoom ||
        from_session_custom || from_session_preset || from_global_filters ||
        default_window
    end

    def default_window
      [ preset_start(default_key), Time.zone.now, default_key ]
    end

    def preset_start(key)
      (PRESET_START[key.to_s] || PRESET_START["last_24_hours"]).call
    end

    # Priority 1: page-specific preset from the dropdown.
    def from_page_preset
      range = ransack_params[:period_start_range]
      return nil unless range.present? && range.to_sym != :custom

      [ preset_start(range), Time.zone.now, range ]
    end

    # Priority 2: page-specific custom datetime range from the picker (only
    # when period_start_range is explicitly "custom").
    def from_page_custom_range
      return nil unless ransack_params[:period_start_range].present? &&
        ransack_params[:period_start_range].to_sym == :custom &&
        ransack_params[:custom_date_range].present? &&
        ransack_params[:custom_date_range].include?(" to ")

      dates = ransack_params[:custom_date_range].split(" to ")
      custom_start = parse_time_param(dates[0].strip)
      custom_end = parse_time_param(dates[1].strip)
      return nil unless custom_start && custom_end

      [ custom_start, custom_end, :custom ]
    end

    # Priority 3: custom time range from chart zoom.
    def from_chart_zoom
      return nil unless ransack_params[:occurred_at_gteq].present? && ransack_params[:occurred_at_lt].present?

      zoom_start = parse_time_param(ransack_params[:occurred_at_gteq])
      zoom_end = parse_time_param(ransack_params[:occurred_at_lt])
      return nil unless zoom_start && zoom_end

      [ zoom_start, zoom_end, :custom ]
    end

    # Priority 4a: custom range from the time range selector (session).
    def from_session_custom
      preference = session_time_range_preference
      return nil unless RailsPulse::TimeRangePreference.custom?(preference)

      start_time = parse_time_param(preference["start_time"]) || preset_start(default_key)
      end_time = parse_time_param(preference["end_time"]) || Time.zone.now
      [ start_time, end_time, :custom ]
    end

    # Priority 4b: preset from the time range selector (session).
    def from_session_preset
      preference = session_time_range_preference
      return nil unless preference.is_a?(String) && preference.present?

      [ preset_start(preference), Time.zone.now, preference.to_sym ]
    end

    # Priority 5: global filters (session).
    def from_global_filters
      filters = session_global_filters
      return nil unless filters["start_time"].present? || filters["end_time"].present?

      start_time = parse_time_param(filters["start_time"]) || preset_start(default_key)
      end_time = parse_time_param(filters["end_time"]) || Time.zone.now
      [ start_time, end_time, :custom ]
    end

    def ransack_params
      q = params[:q]
      q.respond_to?(:permit) ? q : ActionController::Parameters.new({})
    end

    def session_time_range_preference
      RailsPulse::TimeRangePreference.normalize(session[:time_range_preference])
    end

    def session_global_filters
      filters = session[:global_filters]
      filters.is_a?(Hash) ? filters : {}
    end

    # Returns nil for anything that does not parse, so a hand-edited or stale
    # value falls back to the default range instead of raising.
    def parse_time_param(param)
      case param
      when Time, DateTime
        param.in_time_zone
      when String
        return nil if param.blank?

        Time.zone.parse(param)
      when Numeric
        Time.zone.at(param)
      else
        nil
      end
    rescue ArgumentError, TypeError, RangeError
      nil
    end

    # Rounds to hour or day boundaries in Time.zone (summaries are always
    # bucketed there) and returns the span in hours (float) alongside.
    def normalize(start_time, end_time)
      start_time = start_time.in_time_zone
      end_time = end_time.in_time_zone
      time_diff_hours = (end_time.to_i - start_time.to_i) / 3600.0

      if time_diff_hours <= 25
        [ start_time.beginning_of_hour, end_time.end_of_hour, time_diff_hours ]
      else
        [ start_time.beginning_of_day, end_time.end_of_day, time_diff_hours ]
      end
    end

    # -- Zoom / table window --------------------------------------------------

    def resolve_zoom(main_start, main_end)
      selected_column_time = params[:selected_column_time]
      zoom_start = params.delete(:zoom_start_time)
      zoom_end = params.delete(:zoom_end_time)

      if selected_column_time
        table_start, table_end = normalize_column_time(selected_column_time.to_i, main_start, main_end)
        # Column selection has highest precedence for the table only; the
        # chart keeps showing the full range, so zoom_start/zoom_end are
        # returned as extracted (not normalized) rather than derived here.
        return [ zoom_start, zoom_end, table_start, table_end ]
      end

      zoom_start, zoom_end = normalize_zoom_times(zoom_start.to_i, zoom_end.to_i) if zoom_start && zoom_end

      table_start = zoom_start || main_start
      table_end = zoom_end || main_end

      [ zoom_start, zoom_end, table_start, table_end ]
    end

    # column_time_ms is JS milliseconds; period boundary is based on the
    # overall page range (main_start/main_end), same as the chart.
    def normalize_column_time(column_time_ms, main_start, main_end)
      column_time_seconds = column_time_ms / 1000
      time_diff_hours = (main_end - main_start) / 3600.0
      column_time_obj = Time.zone&.at(column_time_seconds) || Time.at(column_time_seconds)

      if time_diff_hours <= 25
        [ column_time_obj.beginning_of_hour.to_i, column_time_obj.end_of_hour.to_i ]
      else
        [ column_time_obj.beginning_of_day.to_i, column_time_obj.end_of_day.to_i ]
      end
    end

    # start_ms/end_ms are JS milliseconds; period boundary is based on the
    # zoomed span itself.
    def normalize_zoom_times(start_ms, end_ms)
      start_seconds = start_ms / 1000
      end_seconds = end_ms / 1000
      time_diff_hours = (end_seconds - start_seconds) / 3600.0
      start_obj = Time.zone&.at(start_seconds) || Time.at(start_seconds)
      end_obj = Time.zone&.at(end_seconds) || Time.at(end_seconds)

      if time_diff_hours <= 25
        [ start_obj.beginning_of_hour.to_i, end_obj.end_of_hour.to_i ]
      else
        [ start_obj.beginning_of_day.to_i, end_obj.end_of_day.to_i ]
      end
    end

    # -- Duration threshold -----------------------------------------------------

    def resolve_duration
      thresholds = RailsPulse.configuration.public_send("#{duration_range_type}_thresholds")
      duration_param = ransack_params[:avg_duration] || ransack_params[:duration] || ransack_params[:duration_gteq]

      if duration_param.present?
        [ threshold_for(thresholds, duration_param), duration_param ]
      elsif (global_threshold = session_global_filters["performance_threshold"]).present?
        [ threshold_for(thresholds, global_threshold), global_threshold.to_sym ]
      else
        [ 0, :all ]
      end
    end

    def threshold_for(thresholds, key)
      case key.to_sym
      when :slow then thresholds[:slow]
      when :very_slow then thresholds[:very_slow]
      when :critical then thresholds[:critical]
      else 0
      end
    end
  end
end
