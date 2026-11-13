# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module RailsPulse
  module Remote
    # Posts one gzipped batch to the central. Short timeouts: it runs on the
    # writer thread, and a central that does not answer must cost the writer
    # seconds, not minutes, while requests keep queueing behind it.
    class Client
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 5
      # A vendor type, not application/json, so the central's Rails does not
      # try to parse the gzipped body into params before the endpoint reads it.
      CONTENT_TYPE = "application/vnd.rails-pulse.batch+json"
      CONTRACT_HEADER = "Rails-Pulse-Remote-Contract"

      Response = Struct.new(:status, :body, :headers, keyword_init: true) do
        # The JSON body the central answers with, or an empty hash.
        def json
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end

        def message
          json["error"].presence || "HTTP #{status}"
        end

        def header(name)
          headers[name.downcase]
        end
      end

      # Raised when the central could not be reached or did not answer in time.
      class Unavailable < StandardError; end

      def initialize(settings = nil)
        @settings = settings
      end

      # @param body [String] a gzipped batch (Batch#body)
      # @return [Response]
      def post(body)
        uri = endpoint
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{settings.token}"
        request["Content-Type"] = CONTENT_TYPE
        request["Content-Encoding"] = "gzip"
        request[CONTRACT_HEADER] = CONTRACT.to_s
        request["User-Agent"] = user_agent
        request.body = body

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
        Response.new(status: response.code.to_i, body: response.body, headers: response.each_header.to_h)
      rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError => e
        raise Unavailable, "#{e.class}: #{e.message}"
      end

      # config.remote.url plus BATCHES_PATH, keeping any path the URL has.
      def endpoint
        URI.join(settings.url.to_s.chomp("/") + "/", BATCHES_PATH.delete_prefix("/"))
      end

      private

      def settings
        @settings || RailsPulse.configuration.remote
      end

      def user_agent
        "rails_pulse/#{RailsPulse::VERSION} (remote; ruby #{RUBY_VERSION}; rails #{Rails.version})"
      end
    end
  end
end
