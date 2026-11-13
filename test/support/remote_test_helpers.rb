require "zlib"

# For tests of remote mode (RailsPulse::Remote). with_remote_mode turns it on
# for one block, with a fresh writer and sender, and puts everything back.
# Posts are answered by stub_http_response (ApiClientTestHelpers); the
# bodies they capture decode with remote_items.
module RemoteTestHelpers
  REMOTE_URL = "https://central.example.com".freeze
  REMOTE_TOKEN = "remote-#{'t' * 40}".freeze

  private

  def with_remote_mode(url: REMOTE_URL, token: REMOTE_TOKEN, async: false)
    remote = RailsPulse.configuration.remote
    original_async = RailsPulse.configuration.async
    RailsPulse::Tracker.reset_writer!
    RailsPulse::Remote.reset!
    remote.url = url
    remote.token = token
    RailsPulse.configuration.async = async

    yield
  ensure
    RailsPulse::Tracker.flush! if async
    RailsPulse.configuration.async = original_async
    remote.url = nil
    remote.token = nil
    RailsPulse::Tracker.reset_writer!
    RailsPulse::Remote.reset!
  end

  # Records every body posted to the central and answers it with `status`.
  def capture_remote_posts(status: 202, body: { accepted: 0, rejected: 0, errors: [] }.to_json)
    posts = []
    stub_http_response(status, body) { |request, uri| posts << { request: request, uri: uri } }
    posts
  end

  # The items of the captured posts, in order.
  def remote_items(posts)
    posts.flat_map { |post| JSON.parse(Zlib.gunzip(post[:request].body))["items"] }
  end
end
