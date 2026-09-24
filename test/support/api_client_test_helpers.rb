require "net/http"
require "tmpdir"

# For tests of the rails-pulse CLI and the MCP server. Keeps them hermetic:
# no credentials from the developer's shell or ~/.rails-pulse, a throwaway
# config file, and no real network. A Net::HTTP.start that has not been
# stubbed with stub_http_response fails at once instead of hanging.
module ApiClientTestHelpers
  extend ActiveSupport::Concern

  ENV_KEYS = %w[RAILS_PULSE_URL RAILS_PULSE_TOKEN RAILS_PULSE_MOUNT_PATH RAILS_PULSE_CONFIG].freeze

  NET_HTTP_START_GUARD = lambda do |*_args, **_opts, &_block|
    raise "Net::HTTP.start called in tests without a stub. Use stub_http_response."
  end

  included do
    setup do
      @saved_api_client_env = ENV_KEYS.to_h { |key| [ key, ENV.delete(key) ] }
      @api_client_config_dir = Dir.mktmpdir("rails_pulse_cli")
      ENV["RAILS_PULSE_CONFIG"] = File.join(@api_client_config_dir, ".rails-pulse")
      @original_net_http_start = Net::HTTP.method(:start)
      restore_net_http_start
    end

    teardown do
      silence_warnings { Net::HTTP.define_singleton_method(:start, @original_net_http_start) }
      ENV_KEYS.each { |key| ENV.delete(key) }
      @saved_api_client_env.each { |key, value| ENV[key] = value if value }
      FileUtils.rm_rf(@api_client_config_dir)
    end
  end

  private

  # Where RailsPulse::CLI::Config reads and writes during this test.
  def config_path
    ENV.fetch("RAILS_PULSE_CONFIG")
  end

  # Stubs Net::HTTP.start to answer every request with the given status and
  # body. The block receives the outgoing request and its URI.
  def stub_http_response(code, body, &block)
    silence_warnings do
      Net::HTTP.define_singleton_method(:start) do |host, port, **_opts, &http_block|
        response_class = Net::HTTPResponse::CODE_TO_OBJ[code.to_s] || Net::HTTPResponse
        response = response_class.new("1.1", code.to_s, "")
        response.instance_variable_set(:@body, body)
        response.instance_variable_set(:@read, true)

        http_stub = Object.new
        http_stub.define_singleton_method(:request) do |req|
          uri = URI("https://#{host}#{req.path}")
          block&.call(req, uri)
          response
        end
        http_block.call(http_stub)
      end
    end
  end

  # Makes Net::HTTP.start raise, as a refused connection would.
  def stub_http_failure(error = Errno::ECONNREFUSED)
    silence_warnings { Net::HTTP.define_singleton_method(:start) { |*_args, **_opts| raise error } }
  end

  # Puts the no-network guard back after a stub.
  def restore_net_http_start
    silence_warnings { Net::HTTP.define_singleton_method(:start, &NET_HTTP_START_GUARD) }
  end
end
