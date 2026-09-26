module RailsPulse
  module ApplicationHelper
    include BacktraceHelper
    include BreadcrumbsHelper
    include ChartHelper
    include CspHelper
    include FormattingHelper
    include FormHelper
    include IconHelper
    include RouteHelper
    include StatusHelper
    include TableHelper
    include TagsHelper

    # Convert time range symbol to human-readable label
    def humanize_time_range(time_range_symbol)
      case time_range_symbol.to_sym
      when :last_day then "last 24 hours"
      when :last_week then "last week"
      when :last_two_weeks then "last 2 weeks"
      when :last_month then "last month"
      when :last_24_hours then "last 24 hours"
      when :last_7_days then "last 7 days"
      when :last_14_days then "last 14 days"
      when :last_30_days then "last 30 days"
      when :custom then "custom range"
      else time_range_symbol.to_s.humanize.downcase
      end
    end

    # Tooltip text for the chart-panel zone badge: the exact resolved interval
    # (when a controller has resolved one) plus the aggregation zone every
    # chart — hourly or daily — is consistently labeled in.
    def time_range_zone_tooltip
      zone = RailsPulse::TimeRange.aggregation_zone_label
      lines = []

      if (window = @time_range&.window)
        lines << "Showing #{window.start_time.strftime('%b %-d, %Y %l:%M %p')} – #{window.end_time.strftime('%b %-d, %Y %l:%M %p')} (#{zone})"
      end

      lines << "All times are shown in #{zone}."
      lines.join("\n")
    end

    def page_url(page_number)
      url_for(request.query_parameters.merge(page: page_number))
    end

    def archived_page_url(page_number)
      url_for(request.query_parameters.merge(archived_page: page_number, anchor: "archived-data"))
    end
  end
end
