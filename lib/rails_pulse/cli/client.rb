require "net/http"
require "uri"
require "json"
require_relative "config"

module RailsPulse
  module CLI
    # HTTP client for the read-only JSON API under <mount>/api/v1.
    class Client
      class ApiError < StandardError; end

      # The endpoint exists but needs rails_pulse_pro in the application. The
      # free gem answers 402 with the feature name and where to read more.
      class ProRequiredError < ApiError
        attr_reader :feature, :url

        def initialize(message, feature: nil, url: nil)
          super(message)
          @feature = feature
          @url = url
        end
      end

      def initialize(config = nil)
        @config = config || Config.load
      end

      def get(path, params = {})
        uri = URI("#{@config.url}#{@config.mount_path}/api/v1#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          req = Net::HTTP::Get.new(uri)
          req["X-Rails-Pulse-Token"] = @config.token
          response = http.request(req)
          raise_for(response) unless response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        end
      rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
        raise ApiError, "could not connect to #{uri.host}:#{uri.port} (#{e.message})"
      end

      private

      def raise_for(response)
        raise ApiError, "#{response.code} #{response.message}" unless response.code == "402"

        body = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end
        raise ProRequiredError.new(
          body["message"] || "This endpoint needs Rails Pulse Pro",
          feature: body["feature"], url: body["url"]
        )
      end
    end
  end
end
