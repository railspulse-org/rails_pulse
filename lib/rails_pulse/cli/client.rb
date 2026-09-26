require "net/http"
require "uri"
require "json"
require_relative "config"

module RailsPulse
  module CLI
    # HTTP client for the read-only JSON API under <mount>/api/v1.
    class Client
      class ApiError < StandardError; end

      # The endpoint exists but is served by an extension the application
      # does not have. The API answers 402 with the feature name.
      class ExtensionRequiredError < ApiError
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
        body = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end
        body = {} unless body.is_a?(Hash)

        if response.code == "402"
          raise ExtensionRequiredError.new(
            body["message"] || "This endpoint is provided by an extension that is not installed",
            feature: body["feature"], url: body["url"]
          )
        end

        # The API explains a 400 or 401 in the body ("Invalid sort. Valid
        # values: ..."); relay it rather than only the status line.
        message = "#{response.code} #{response.message}".strip
        message = "#{message}: #{body["error"]}" if body["error"].is_a?(String) && !body["error"].empty?
        raise ApiError, message
      end
    end
  end
end
