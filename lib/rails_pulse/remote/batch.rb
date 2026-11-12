# frozen_string_literal: true

require "bigdecimal"
require "json"
require "securerandom"
require "socket"
require "zlib"

module RailsPulse
  module Remote
    # One request body for the central: items in the envelope the contract
    # defines, as gzipped JSON. Times are UTC ISO 8601 with microseconds,
    # whatever ActiveSupport's JSON precision is set to, so a duration and
    # the hour a request is summarized in survive the trip. Each batch gets a
    # batch_id when it is built and keeps it across retries, which is how the
    # central recognises a batch it has already recorded.
    class Batch
      # Keys the collectors put on an operation that mean something only in
      # this process: the request or job run it belonged to here.
      LOCAL_OPERATION_KEYS = %i[request_id job_run_id].freeze

      attr_reader :batch_id, :item_count, :body

      # @param items [Array<Item, Hash>] items, or item hashes already encoded
      #   (the halves of a batch the central found too large)
      def initialize(items, batch_id: SecureRandom.uuid, now: Time.current)
        @batch_id = batch_id
        @item_count = items.size
        @body = Zlib.gzip(JSON.generate(envelope(items, now)))
      end

      def bytesize
        @body.bytesize
      end

      # The encoded items of a body built here.
      def self.items_of(body)
        JSON.parse(Zlib.gunzip(body)).fetch("items")
      end

      # Plain JSON values: string keys, times as UTC ISO 8601, and anything
      # else through as_json.
      def self.encode(value)
        case value
        when Hash then value.each_with_object({}) { |(key, inner), out| out[key.to_s] = encode(inner) }
        when Array then value.map { |inner| encode(inner) }
        when Time, DateTime then value.to_time.utc.iso8601(6)
        when Date then value.iso8601
        when Symbol then value.to_s
        when Float then value.finite? ? value : nil
        when BigDecimal then value.to_f
        when String, Integer, true, false, nil then value
        else
          json = value.as_json
          json.equal?(value) ? value.to_s : encode(json)
        end
      end

      def self.hostname
        @hostname ||= Socket.gethostname
      end

      private

      def envelope(items, now)
        {
          "version" => CONTRACT,
          "batch_id" => @batch_id,
          "created_at" => now.utc.iso8601(6),
          "hostname" => self.class.hostname,
          "pid" => Process.pid,
          "environment" => Rails.env.to_s,
          "gem_version" => RailsPulse::VERSION,
          "rails_version" => Rails.version,
          "ruby_version" => RUBY_VERSION,
          "items" => items.map { |item| encode_item(item) }
        }
      end

      def encode_item(item)
        return item if item.is_a?(Hash)

        attributes = item.attributes
        if attributes.key?(:operations)
          operations = Array(attributes[:operations]).map { |operation| operation.except(*LOCAL_OPERATION_KEYS) }
          attributes = attributes.merge(operations: operations)
        end
        { "type" => item.type }.merge(self.class.encode(attributes.except(:type)))
      end
    end
  end
end
