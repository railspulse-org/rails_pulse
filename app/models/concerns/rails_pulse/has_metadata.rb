module RailsPulse
  module HasMetadata
    extend ActiveSupport::Concern

    # Parses the metadata column as JSON, returning {} for blank, unparseable,
    # or valid-but-non-object JSON (an array or scalar) rather than raising or
    # handing callers something they can't call Hash methods on.
    def metadata_hash
      return {} if metadata.blank?

      parsed = JSON.parse(metadata)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
