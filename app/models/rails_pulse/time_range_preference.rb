module RailsPulse
  # Normalizes the time range preference stored in the session so every
  # reader sees the same shape regardless of which session store wrote it.
  #
  # The cookie store round-trips through JSON and stringifies hash keys, but a
  # Marshal-backed store (activerecord-session_store's default) hands back the
  # symbol keys the writer used. Readers that only knew one shape raised
  # NoMethodError on the other and locked the dashboard into 500s for the rest
  # of the browser session.
  module TimeRangePreference
    # A preset name as a String, a custom range as a string-keyed Hash, or nil
    # for anything unrecognized so callers fall back to their defaults.
    def self.normalize(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s)
      when String, Symbol
        value.to_s
      else
        nil
      end
    end

    def self.custom?(preference)
      preference.is_a?(Hash) && preference["type"] == "custom"
    end
  end
end
