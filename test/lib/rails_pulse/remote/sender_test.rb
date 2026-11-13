require "test_helper"

module RailsPulse
  module Remote
    class SenderTest < ActiveSupport::TestCase
      # Answers each post with the next scripted response (a Client::Response,
      # or an exception class to raise), repeating the last one.
      class ScriptedClient
        attr_reader :posts

        def initialize(*responses)
          @responses = responses
          @posts = []
        end

        def post(body)
          @posts << body
          response = @responses.size > 1 ? @responses.shift : @responses.first
          raise response, "connection refused" if response.is_a?(Class)

          response
        end

        def items_posted
          @posts.map { |body| Batch.items_of(body) }
        end
      end

      setup do
        @now = 1_000.0
        @log = StringIO.new
        RailsPulse.stubs(:logger).returns(Logger.new(@log))
      end

      teardown do
        RailsPulse.unstub(:logger)
      end

      # Delivery Tests

      test "an accepted batch is sent once and not held" do
        client = ScriptedClient.new(accepted)
        sender = build_sender(client)

        assert_equal 1, sender.deliver([ item("/a") ])
        assert_equal 1, client.posts.size
        assert_equal 0, sender.stats[:pending_batches]
        assert_equal 0, sender.dropped_total
      end

      test "a batch the central cannot take is held, without raising, and nothing is sent until the backoff passes" do
        client = ScriptedClient.new(Client::Unavailable)
        sender = build_sender(client)

        assert_nothing_raised { sender.deliver([ item("/a") ]) }
        sender.deliver([ item("/b") ])

        assert_equal 1, client.posts.size, "a second batch during the backoff waits instead of costing another timeout"
        assert_equal 2, sender.stats[:pending_batches]
        assert_in_delta Sender::BACKOFF_START, sender.stats[:retry_in]
        assert_equal 1, @log.string.scan("could not deliver to the central").size
      end

      test "held batches are sent oldest first once the central is back" do
        client = ScriptedClient.new(Client::Unavailable, accepted)
        sender = build_sender(client)
        sender.deliver([ item("/a") ])
        sender.deliver([ item("/b") ])

        @now += Sender::BACKOFF_START
        sender.deliver([ item("/c") ])

        assert_equal [ [ "/a" ], [ "/a" ], [ "/b" ], [ "/c" ] ], client.items_posted.map { |items| items.map { |i| i["path"] } }
        assert_equal 0, sender.stats[:pending_batches]
        assert_includes @log.string, "delivering to the central again"
      end

      test "a retried batch keeps its batch_id" do
        client = ScriptedClient.new(response(503), accepted)
        sender = build_sender(client)
        sender.deliver([ item("/a") ])
        @now += Sender::BACKOFF_START

        sender.deliver([])

        ids = client.posts.map { |body| JSON.parse(Zlib.gunzip(body))["batch_id"] }

        assert_equal 2, ids.size
        assert_equal 1, ids.uniq.size
      end

      test "the backoff doubles up to its cap" do
        client = ScriptedClient.new(response(500))
        sender = build_sender(client)

        retries = 4.times.map do
          sender.deliver(client.posts.empty? ? [ item("/a") ] : [])
          retry_in = sender.stats[:retry_in]
          @now += retry_in
          retry_in
        end

        assert_equal [ 5.0, 10.0, 20.0, 40.0 ], retries
      end

      # Limit Tests

      test "a batch is dropped and counted after MAX_ATTEMPTS" do
        client = ScriptedClient.new(response(500))
        sender = build_sender(client)
        sender.deliver([ item("/a"), item("/b") ])

        (Sender::MAX_ATTEMPTS - 1).times do
          @now += Sender::BACKOFF_MAX
          sender.deliver([])
        end

        assert_equal Sender::MAX_ATTEMPTS, client.posts.size
        assert_equal 0, sender.stats[:pending_batches]
        assert_equal 2, sender.dropped_total
        assert_includes @log.string, "gave up on a batch after #{Sender::MAX_ATTEMPTS} attempts"
      end

      test "past MAX_PENDING_BATCHES the oldest held batch is dropped and counted" do
        client = ScriptedClient.new(Client::Unavailable)
        sender = build_sender(client)

        (Sender::MAX_PENDING_BATCHES + 3).times { |i| sender.deliver([ item("/#{i}") ]) }

        assert_equal Sender::MAX_PENDING_BATCHES, sender.stats[:pending_batches]
        assert_equal 3, sender.dropped_total
        assert_equal 1, @log.string.scan("dropped").size, "drops are logged at most once a minute"
      end

      test "items the central accepts the batch but rejects are counted as dropped" do
        client = ScriptedClient.new(accepted(rejected: 2, errors: [ "items[0] (request): path is required" ]))
        sender = build_sender(client)

        sender.deliver([ item("/a"), item("/b"), item("/c") ])

        assert_equal 2, sender.dropped_total
        assert_includes @log.string, "path is required"
      end

      test "take_dropped reports the drops since it was last asked" do
        client = ScriptedClient.new(response(400))
        sender = build_sender(client)
        sender.deliver([ item("/a"), item("/b") ])

        assert_equal 2, sender.take_dropped
        assert_equal 0, sender.take_dropped
        assert_equal 2, sender.dropped_total
      end

      # Response Tests

      test "a batch the central refuses as malformed is dropped, and the next one is still sent" do
        client = ScriptedClient.new(response(422, error: "contract version 1 is not supported"), accepted)
        sender = build_sender(client)
        sender.deliver([ item("/a") ])

        sender.deliver([ item("/b") ])

        assert_equal 1, sender.dropped_total
        assert_equal 0, sender.stats[:pending_batches]
        assert_includes @log.string, "contract version 1 is not supported"
      end

      test "a refused token holds the batch and waits REFUSED_PAUSE before trying again" do
        client = ScriptedClient.new(response(401, error: "unauthorized"))
        sender = build_sender(client)

        sender.deliver([ item("/a") ])

        assert_equal 1, sender.stats[:pending_batches]
        assert_in_delta Sender::REFUSED_PAUSE, sender.stats[:retry_in]
        assert_includes @log.string, "refused this application's token or URL"
      end

      test "a rate limit waits for Retry-After" do
        client = ScriptedClient.new(response(429, headers: { "retry-after" => "42" }))
        sender = build_sender(client)

        sender.deliver([ item("/a") ])

        assert_in_delta 42.0, sender.stats[:retry_in]
        assert_equal 1, sender.stats[:pending_batches]
      end

      test "a batch the central finds too large is split in halves, each sent as a new batch" do
        client = ScriptedClient.new(response(413), accepted)
        sender = build_sender(client)

        sender.deliver([ item("/a"), item("/b"), item("/c") ])

        assert_equal [ [ "/a", "/b", "/c" ], [ "/a", "/b" ], [ "/c" ] ], client.items_posted.map { |items| items.map { |i| i["path"] } }
        assert_equal 0, sender.stats[:pending_batches]
      end

      test "a single item too large to send is dropped" do
        client = ScriptedClient.new(response(413))
        sender = build_sender(client)

        sender.deliver([ item("/huge") ])

        assert_equal 1, sender.dropped_total
        assert_equal 0, sender.stats[:pending_batches]
      end

      # Edge Cases

      test "a forked child starts without its parent's held batches" do
        client = ScriptedClient.new(Client::Unavailable)
        sender = build_sender(client)
        sender.deliver([ item("/parent") ])

        child_pid = Process.pid + 1
        Process.stubs(:pid).returns(child_pid)

        assert_equal 0, sender.stats[:pending_batches]
        assert_equal 0, sender.take_dropped, "the parent's batches are not the child's to count"
      ensure
        Process.unstub(:pid)
      end

      test "an unexpected error is logged and never raised" do
        client = Object.new
        client.define_singleton_method(:post) { |_body| raise ArgumentError, "bug" }
        sender = build_sender(client)

        assert_equal 0, sender.deliver([ item("/a") ])
        assert_includes @log.string, "remote delivery failed: ArgumentError"
      end

      test "items that cannot be encoded are dropped and counted, and held batches still go" do
        client = ScriptedClient.new(Client::Unavailable, accepted)
        sender = build_sender(client)
        sender.deliver([ item("/held") ])
        @now += Sender::BACKOFF_START
        unencodable = Item.new("request", { path: Object.new.tap { |o| o.define_singleton_method(:as_json) { |*| raise "no" } } })

        sender.deliver([ unencodable ])

        assert_equal 1, sender.dropped_total
        assert_equal [ [ "/held" ], [ "/held" ] ], client.items_posted.map { |items| items.map { |i| i["path"] } }
      end

      test "an empty delivery with nothing held sends nothing" do
        client = ScriptedClient.new(accepted)

        assert_equal 0, build_sender(client).deliver([])
        assert_empty client.posts
      end

      private

      def build_sender(client)
        Sender.new(client: client, clock: -> { @now }, jitter: ->(delay) { delay })
      end

      def item(path)
        Item.new("request", { path: path })
      end

      def accepted(rejected: 0, errors: [])
        response(202, accepted: 1, rejected: rejected, errors: errors)
      end

      def response(status, headers: {}, **json)
        Client::Response.new(status: status, body: json.to_json, headers: headers)
      end
    end
  end
end
