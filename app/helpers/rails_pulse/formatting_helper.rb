module RailsPulse
  module FormattingHelper
    def human_readable_occurred_at(occurred_at)
      return "" unless occurred_at.present?
      # Time.zone, not the server's OS zone — the same zone charts label as
      # the aggregation zone, so this and the charts always agree.
      time = occurred_at.is_a?(String) ? Time.zone.parse(occurred_at) : occurred_at
      return "" if time.nil?
      time.strftime("%b %d, %Y %l:%M %p")
    end

    def time_ago_in_words(time)
      return "Unknown" if time.blank?

      time = Time.zone.parse(time.to_s) if time.is_a?(String)

      seconds_ago = [ Time.current - time, 0 ].max

      case seconds_ago
      when 0..59
        "#{seconds_ago.to_i}s ago"
      when 60..3599
        "#{(seconds_ago / 60).to_i}m ago"
      when 3600..86399
        "#{(seconds_ago / 3600).to_i}h ago"
      else
        "#{(seconds_ago / 86400).to_i}d ago"
      end
    end

    def human_readable_bytes(value)
      return "—" if value.nil?
      number_to_human_size(value, precision: 2)
    end

    def human_readable_summary_period(summary)
      return "" unless summary&.period_start&.present? && summary&.period_end&.present?

      # Already Time.zone-aware from ActiveRecord — the same aggregation
      # zone charts label, so no conversion needed.
      start_time = summary.period_start
      end_time = summary.period_end

      case summary.period_type
      when "hour"
        start_time.strftime("%b %e %Y, %l:%M %p") + " - " + end_time.strftime("%l:%M %p")
      when "day"
        start_time.strftime("%b %e, %Y")
      end
    end
  end
end
