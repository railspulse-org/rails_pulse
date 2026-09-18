# TimeRangeConcern
#
# Handles time range selection and filtering across all controllers.
# Supports multiple time range sources with priority order:
# 1. Page-specific preset/custom range (from dropdown/picker)
# 2. Chart zoom parameters
# 3. Time range selector (session)
# 4. Global filters (session)
# 5. Default time range
#
# Normalizes times to beginning/end of hour or day based on range duration.
module TimeRangeConcern
  extend ActiveSupport::Concern
  include RansackParamsConcern

  included do
    # Define the constant in the including class - ordered by most common usage
    const_set(:TIME_RANGE_OPTIONS, [
      [ "Last 24 hours", :last_24_hours ],
      [ "Last 7 days", :last_7_days ],
      [ "Last 14 days", :last_14_days ],
      [ "Last 30 days", :last_30_days ],
      [ "Custom range", :custom ]
    ].freeze)
  end

  def default_time_range_key
    :last_24_hours
  end

  def setup_time_range
    default_key = default_time_range_key

    start_time = case default_key
    when :last_24_hours  then 1.day.ago
    when :last_7_days    then 1.week.ago
    when :last_14_days   then 2.weeks.ago
    when :last_30_days   then 1.month.ago
    else                      1.day.ago
    end
    end_time = Time.zone.now
    selected_time_range = default_key

    # Normalized up front so a symbol-keyed hash from a Marshal-backed session
    # store reads the same as the string-keyed one the cookie store produces;
    # anything unrecognized becomes nil and falls through to later priorities.
    session_preference = RailsPulse::TimeRangePreference.normalize(session[:time_range_preference])

    # Priority 1: Page-specific preset from dropdown (check this first!)
    if ransack_params[:period_start_range].present? && ransack_params[:period_start_range].to_sym != :custom
      # Predefined time range from dropdown
      selected_time_range = ransack_params[:period_start_range]

      start_time =
        case selected_time_range.to_sym
        when :last_24_hours  then 1.day.ago
        when :last_7_days    then 1.week.ago
        when :last_14_days   then 2.weeks.ago
        when :last_30_days   then 1.month.ago
        else 1.day.ago # Default fallback
        end
    # Priority 2: Page-specific custom datetime range from picker (only if period_start_range is :custom)
    elsif ransack_params[:period_start_range].present? && ransack_params[:period_start_range].to_sym == :custom && ransack_params[:custom_date_range].present? && ransack_params[:custom_date_range].include?(" to ")
      # Custom datetime range from custom range picker
      dates = ransack_params[:custom_date_range].split(" to ")
      custom_start = parse_time_param(dates[0].strip)
      custom_end = parse_time_param(dates[1].strip)
      if custom_start && custom_end
        start_time = custom_start
        end_time = custom_end
        selected_time_range = :custom
      end
    # Priority 3: Page-specific filters (chart zoom)
    elsif ransack_params[:occurred_at_gteq].present? && ransack_params[:occurred_at_lt].present?
      # Custom time range from chart zoom
      zoom_start = parse_time_param(ransack_params[:occurred_at_gteq])
      zoom_end = parse_time_param(ransack_params[:occurred_at_lt])
      if zoom_start && zoom_end
        start_time = zoom_start
        end_time = zoom_end
        selected_time_range = :custom
      end
    # Priority 4: Time range selector (from session)
    elsif RailsPulse::TimeRangePreference.custom?(session_preference)
      # Custom range from time range selector
      start_time = parse_time_param(session_preference["start_time"]) || start_time
      end_time = parse_time_param(session_preference["end_time"]) || end_time
      selected_time_range = :custom
    elsif session_preference.is_a?(String) && session_preference.present?
      # Preset from time range selector
      selected_time_range = session_preference.to_sym
      start_time =
        case selected_time_range
        when :last_24_hours  then 1.day.ago
        when :last_7_days    then 1.week.ago
        when :last_14_days   then 2.weeks.ago
        when :last_30_days   then 1.month.ago
        else start_time
        end
    # Priority 5: Global filters (from session)
    elsif session_global_filters["start_time"].present? || session_global_filters["end_time"].present?
      start_time = parse_time_param(session_global_filters["start_time"]) || start_time
      end_time = parse_time_param(session_global_filters["end_time"]) || end_time
      selected_time_range = :custom
    end
    # Priority 6: Default time range (already set above)

    time_diff = (end_time.to_i - start_time.to_i) / 3600.0

    # in_time_zone before rounding: a custom range parsed from a string
    # (parse_time_param, below) is a plain Time carrying the server OS's
    # local offset, not Time.zone. beginning_of_day/beginning_of_hour round
    # in whatever offset the receiver carries, so without this conversion
    # the boundary lands on local-offset midnight/top-of-hour — which is a
    # different instant than Time.zone midnight/top-of-hour whenever the
    # server's OS timezone isn't Time.zone. Summary#normalize_period_start
    # always buckets by Time.zone, so a boundary rounded in the wrong zone
    # silently misses every summary row and every chart on the page renders
    # empty. Already-Time.zone values (every path but a parsed string) are
    # a no-op here.
    start_time = start_time.in_time_zone
    end_time = end_time.in_time_zone

    if time_diff <= 25
      start_time = start_time.beginning_of_hour
      end_time = end_time.end_of_hour
    else
      start_time = start_time.beginning_of_day
      end_time = end_time.end_of_day
    end

    # Convert selected_time_range to string for backward compatibility with tests
    [ start_time.to_i, end_time.to_i, selected_time_range.to_s, time_diff ]
  end

  private

  # Returns nil for anything that does not parse, so a hand-edited or stale
  # value falls back to the default range instead of raising.
  def parse_time_param(param)
    case param
    when Time, DateTime
      param.in_time_zone
    when String
      return nil if param.blank?

      # Parse as server local time (not UTC, not Time.zone)
      # This ensures flatpickr datetime strings are interpreted in server's timezone
      Time.parse(param).localtime
    when Numeric
      Time.zone.at(param)
    else
      nil
    end
  rescue ArgumentError, TypeError, RangeError
    nil
  end
end
