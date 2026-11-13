require "stringio"
require "zlib"

module RailsPulse
  module Central
    # Where applications in remote mode post their batches: POST
    # /rails_pulse/v1/batches on the central, routed by the central's own
    # routes file. The bearer token names the application, and its batch is
    # recorded in that application's database by Central::Ingest.
    #
    #   202  recorded (or recorded before, for a resent batch_id); the body
    #        counts the items accepted and rejected
    #   400  the body is not gzipped JSON
    #   401  no token, or one no application has
    #   413  the body is over MAX_BODY_BYTES
    #   422  the envelope does not match the contract (version, batch_id, items)
    #   503  the application's database is behind this gem or unreachable;
    #        the sender keeps the batch and tries again
    #
    # An API controller: no session, cookies, CSRF or dashboard callbacks.
    # The token is the only credential, compared in constant time.
    class BatchesController < ActionController::API
      # Compressed or not; a full writer batch is a small fraction of it.
      MAX_BODY_BYTES = 8 * 1024 * 1024

      def create
        application = RailsPulse::Central.application_for_token(bearer_token)
        return render_error(401, "unauthorized") unless application

        payload = read_payload
        return if performed?

        RailsPulse::Central.with_application(application) do
          next render_error(503, "the database for #{application} needs a Rails Pulse schema upgrade") unless RailsPulse::SchemaCheck.current?
          next render_error(503, "the database for #{application} is unavailable") unless RailsPulse::Tracker.healthy?

          result = Ingest.new(payload).perform
          render json: {
            batch_id: result.batch_id,
            accepted: result.accepted,
            rejected: result.rejected,
            errors: result.errors,
            duplicate: result.duplicate
          }, status: 202
        end
      rescue Ingest::Invalid => e
        render_error(422, e.message)
      end

      private

      def bearer_token
        request.authorization.to_s[/\ABearer\s+(\S+)\z/, 1]
      end

      # Read straight from the body: the gem sends a vendor content type so
      # Rails never parses it into params (and never logs it). Both sizes are
      # capped, so a small gzipped body cannot inflate past the limit.
      def read_payload
        body = request.body
        body.rewind if body.respond_to?(:rewind)
        raw = body.read(MAX_BODY_BYTES + 1).to_s
        return too_large if raw.bytesize > MAX_BODY_BYTES

        raw = Zlib::GzipReader.new(StringIO.new(raw)).read(MAX_BODY_BYTES + 1).to_s if gzipped?
        return too_large if raw.bytesize > MAX_BODY_BYTES

        JSON.parse(raw)
      rescue JSON::ParserError, Zlib::Error
        render_error(400, "the body must be #{gzipped? ? 'gzipped ' : ''}JSON")
      end

      def gzipped?
        request.headers["Content-Encoding"].to_s.split(",").map(&:strip).include?("gzip")
      end

      def too_large
        render_error(413, "the batch is over #{MAX_BODY_BYTES} bytes")
      end

      def render_error(status, message)
        render json: { error: message }, status: status
        nil
      end
    end
  end
end
