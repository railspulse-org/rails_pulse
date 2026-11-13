# frozen_string_literal: true

module RailsPulse
  module Remote
    # Sends batches to the central from the writer thread, and holds the ones
    # the central could not take for a later try.
    #
    # Everything here is bounded, because the central being down must cost
    # this application nothing but the data: held batches are capped by count
    # and by bytes (the oldest go first), each batch is tried at most
    # MAX_ATTEMPTS times, and after a failure nothing is sent until a backoff
    # (exponential, with jitter) has passed, so an unreachable central costs
    # the writer one timeout per backoff rather than one per batch. Whatever
    # is dropped is counted and reported with the next writer heartbeat.
    #
    # Held batches live in this process only: a restart loses them, and a
    # forked child starts empty while its parent still sends its own.
    class Sender
      MAX_PENDING_BATCHES = 100
      MAX_PENDING_BYTES = 10 * 1024 * 1024
      MAX_ATTEMPTS = 10
      # Sent per call, so catching up after an outage cannot hold the writer
      # for long while requests queue behind it.
      MAX_SENDS_PER_CALL = 50
      BACKOFF_START = 5.0
      BACKOFF_MAX = 300.0
      # After the central refuses the token or the URL (401, 403, 404).
      REFUSED_PAUSE = 300.0
      DEFAULT_RETRY_AFTER = 30.0
      LOG_INTERVAL = 60.0 # seconds between "dropped" notices

      Pending = Struct.new(:batch_id, :body, :item_count, :attempts)

      def initialize(client: nil, clock: nil, jitter: nil)
        @client = client || Client.new
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @jitter = jitter || ->(delay) { delay * (0.5 + (rand / 2)) }
        @mutex = Mutex.new
        reset_state
      end

      # Holds the items as one new batch, then sends what is due, oldest
      # first. Returns how many batches the central accepted. Never raises.
      def deliver(items)
        @mutex.synchronize do
          ensure_current_process
          batch = build(items) unless items.empty?
          hold(batch) if batch
          send_due
        end
      rescue StandardError => e
        RailsPulse.logger.error("Rails Pulse remote delivery failed: #{e.class} - #{e.message}")
        0
      end

      # Items dropped since the previous call, for the writer heartbeat.
      def take_dropped
        @mutex.synchronize do
          ensure_current_process
          since = @dropped_total - @dropped_at_last_take
          @dropped_at_last_take = @dropped_total
          since
        end
      end

      def dropped_total
        @mutex.synchronize do
          ensure_current_process
          @dropped_total
        end
      end

      def stats
        @mutex.synchronize do
          ensure_current_process
          {
            pending_batches: @pending.size,
            pending_bytes: @pending.sum { |pending| pending.body.bytesize },
            dropped_total: @dropped_total,
            retry_in: @retry_at ? [ @retry_at - @clock.call, 0.0 ].max : nil
          }
        end
      end

      private

      def reset_state
        @pid = Process.pid
        @pending = []
        @retry_at = nil
        @backoff = nil
        @failing = false
        @dropped_total = 0
        @dropped_at_last_take = 0
        @drop_notice_count = 0
        @drop_notice_reasons = []
        @drop_noticed_at = nil
      end

      # A forked child inherits the parent's held batches, which the parent
      # still owns and sends; start clean.
      def ensure_current_process
        reset_state unless @pid == Process.pid
      end

      # nil, counted as dropped, for items that cannot be encoded.
      def build(items)
        Batch.new(items)
      rescue StandardError => e
        drop(items.size, "a batch could not be encoded (#{e.class}: #{e.message})")
        nil
      end

      def hold(batch)
        @pending << Pending.new(batch.batch_id, batch.body, batch.item_count, 0)
        while @pending.size > MAX_PENDING_BATCHES || @pending.sum { |pending| pending.body.bytesize } > MAX_PENDING_BYTES
          oldest = @pending.shift
          drop(oldest.item_count, "the batches held for the central reached their limit")
        end
      end

      def send_due
        accepted = 0
        MAX_SENDS_PER_CALL.times do
          pending = @pending.first
          break unless pending
          break if @retry_at && @clock.call < @retry_at

          outcome = attempt(pending)
          accepted += 1 if outcome == :accepted
          break if outcome == :stop
        end
        accepted
      end

      def attempt(pending)
        response = with_recording_suppressed { @client.post(pending.body) }

        case response.status
        when 200..299
          @pending.shift
          recovered
          rejected = response.json["rejected"].to_i
          drop(rejected, "the central rejected #{rejected} item(s): #{Array(response.json['errors']).first(3).join('; ')}") if rejected.positive?
          :accepted
        when 413
          split(pending)
          :continue
        when 429
          retry_after = response.header("Retry-After").to_f
          pause(retry_after.positive? ? retry_after : DEFAULT_RETRY_AFTER, "the central asked to slow down (HTTP 429)")
          :stop
        when 400, 422
          @pending.shift
          drop(pending.item_count, "the central refused a batch (HTTP #{response.status}: #{response.message})")
          :continue
        when 401, 403, 404
          retry_later(pending, "the central refused this application's token or URL (HTTP #{response.status}: #{response.message})",
                      delay: REFUSED_PAUSE)
          :stop
        else
          retry_later(pending, "HTTP #{response.status}: #{response.message}")
          :stop
        end
      rescue Client::Unavailable => e
        retry_later(pending, e.message)
        :stop
      end

      def retry_later(pending, reason, delay: nil)
        pending.attempts += 1
        if pending.attempts >= MAX_ATTEMPTS
          @pending.delete(pending)
          drop(pending.item_count, "gave up on a batch after #{MAX_ATTEMPTS} attempts (#{reason})")
        end
        pause(delay || next_backoff, reason)
      end

      def pause(seconds, reason)
        @retry_at = @clock.call + seconds
        if @failing
          RailsPulse.logger.debug("Rails Pulse still cannot deliver to the central: #{reason}")
        else
          @failing = true
          RailsPulse.logger.warn(
            "Rails Pulse could not deliver to the central: #{reason}. Holding #{@pending.size} batch(es) " \
            "and retrying in #{seconds.round}s."
          )
        end
      end

      def recovered
        @retry_at = nil
        @backoff = nil
        return unless @failing

        @failing = false
        RailsPulse.logger.info("Rails Pulse is delivering to the central again.")
      end

      # 5s, doubling, up to 5 minutes, with jitter so processes that failed
      # together do not retry together.
      def next_backoff
        @backoff = @backoff ? [ @backoff * 2, BACKOFF_MAX ].min : BACKOFF_START
        @jitter.call(@backoff)
      end

      # Halves a batch the central found too large. Each half is a new batch:
      # it carries different items, so it is not a resend.
      def split(pending)
        index = @pending.index(pending)
        items = Batch.items_of(pending.body)
        if items.size <= 1
          @pending.delete_at(index)
          drop(pending.item_count, "the central refused a single item as too large (HTTP 413)")
          return
        end

        halves = items.each_slice((items.size / 2.0).ceil).map do |half|
          batch = Batch.new(half)
          Pending.new(batch.batch_id, batch.body, batch.item_count, 0)
        end
        @pending[index, 1] = halves
      end

      def drop(count, reason)
        return unless count.positive?

        @dropped_total += count
        @drop_notice_count += count
        @drop_notice_reasons |= [ reason ]
        now = @clock.call
        return if @drop_noticed_at && now - @drop_noticed_at < LOG_INTERVAL

        RailsPulse.logger.warn(
          "Rails Pulse dropped #{@drop_notice_count} item(s) bound for the central since the last notice: " \
          "#{@drop_notice_reasons.first(3).join('; ')}"
        )
        @drop_noticed_at = now
        @drop_notice_count = 0
        @drop_notice_reasons = []
      end

      # Instrumentation that wraps Net::HTTP must not record the post itself
      # as an operation of whatever request or job is current.
      def with_recording_suppressed
        previous = RailsPulse::Current.skip_recording_rails_pulse_activity
        RailsPulse::Current.skip_recording_rails_pulse_activity = true
        yield
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = previous
      end
    end
  end
end
