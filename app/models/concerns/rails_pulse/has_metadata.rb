module RailsPulse
  module HasMetadata
    extend ActiveSupport::Concern

    # metadata can be valid JSON that isn't an object (an array, a scalar)
    def metadata_hash
      return {} if metadata.blank?

      parsed = JSON.parse(metadata)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
