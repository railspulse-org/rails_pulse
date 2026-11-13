require "socket"

module RailsPulse
  # Persists the data RequestCollector gathers for one request: the route,
  # the request row and its operations.
  #
  # With `config.async` (the default) the middleware hands the payload to a
  # single per-process Writer thread through a bounded queue and returns
  # immediately. The writer drains the queue in batches on one connection
  # checked out of the Rails Pulse pool, so tracking never holds more than one
  # of the host's connections and a traffic burst never fans out into a thread
  # per request. When the queue is full the payload is dropped and counted;
  # losing a sample is the intended trade for never slowing the host down.
  #
  # With `config.async = false`, or whenever the pool's connection is pinned
  # to the current thread (transactional tests), writes happen inline.
  #
  # Once a minute the writer also records a WriterHeartbeat event (queue
  # depth, drops since the last sample) so the dashboard and rails_pulse:status
  # can see every process's writer, not just the one serving the page.
  #
  # In remote mode (RailsPulse::Remote) the queue carries items for a central
  # instead, and the writer posts each batch it drains rather than writing
  # it. On a central (RailsPulse::Central) this persistence code records what
  # applications send, one application's database at a time, so the state
  # kept between batches (rollups, the route id cache, heartbeat pruning) is
  # kept per application.
  module Tracker
    # PG::Connection::PQTRANS_INERROR (libpq enum value 3) — the connection's transaction
    # was aborted by a DB-level error and no ROLLBACK has been issued yet. Defined as a
    # constant to avoid a hard dependency on the pg gem. The full enum is:
    #   PQTRANS_IDLE=0, PQTRANS_ACTIVE=1, PQTRANS_INTRANS=2, PQTRANS_INERROR=3, PQTRANS_UNKNOWN=4
    PG_TRANSACTION_INERROR = 3
    private_constant :PG_TRANSACTION_INERROR

    # How often record_heartbeat prunes stale rows, rather than every heartbeat
    PRUNE_INTERVAL = 1.hour
    private_constant :PRUNE_INTERVAL

    # Route ids memoized for rollup folding, cleared wholesale once full
    ROUTE_CACHE_MAX = 2_000
    private_constant :ROUTE_CACHE_MAX

    # ... and expired wholesale on this interval. Cleanup can delete an idle
    # route whose id is still cached here; expiring bounds how long folds keep
    # landing on the deleted id (the next fold recreates the route).
    ROUTE_CACHE_TTL = 10.minutes
    private_constant :ROUTE_CACHE_TTL

    # The background writer: one thread, one bounded queue, one connection.
    class Writer
      BATCH_SIZE = 50
      DROP_LOG_INTERVAL = 60 # seconds between "queue full" log lines
      SHUTDOWN_TIMEOUT = 5   # seconds to wait for the queue to drain at exit
      HEARTBEAT_INTERVAL = 60 # seconds between WriterHeartbeat samples

      attr_reader :queue_size, :dropped

      def initialize(queue_size:, auto_start: true)
        @queue_size = queue_size
        @auto_start = auto_start
        @mutex = Mutex.new
        @queue = SizedQueue.new(queue_size)
        @thread = nil
        @pid = Process.pid
        @dropped = 0
        @drop_window_count = 0
        @drop_window_started = nil
        @dropped_at_last_heartbeat = 0
        @last_heartbeat_at = nil
        @exit_hook_installed = false
      end

      # Never blocks. Returns false (and counts a drop) when the queue is full.
      def enqueue(data)
        ensure_thread!
        @queue.push(data, true)
        true
      rescue ThreadError, ClosedQueueError
        record_drop
        false
      end

      def size
        @queue.size
      end

      def running?
        @thread&.alive? || false
      end

      # Taking a sample resets the drop count for the next window
      def take_heartbeat_sample
        @mutex.synchronize do
          since_last = @dropped - @dropped_at_last_heartbeat
          @dropped_at_last_heartbeat = @dropped
          { queue_size: @queue_size, queue_depth: @queue.size, dropped: since_last, dropped_total: @dropped }
        end
      end

      # Persist everything queued so far on the calling thread. Used by
      # shutdown when the writer thread is gone, and by tests.
      def drain
        batch = []
        batch << @queue.pop(true) while !@queue.empty?
        Tracker.perform_tracking_batch(batch) unless batch.empty?
        batch.size
      rescue ThreadError
        batch.size
      end

      # Stop accepting work, let the thread finish what is queued (up to
      # `timeout` seconds), then persist any remainder inline. Safe to call
      # more than once; the next enqueue starts a fresh queue and thread.
      def shutdown(timeout: SHUTDOWN_TIMEOUT)
        thread = nil
        @mutex.synchronize do
          @queue.close
          thread = @thread
          @thread = nil
        end
        thread.join(timeout) if thread&.alive?
        thread.kill if thread&.alive?
        drained = drain
        Tracker.flush_rollups!
        drained
      end

      private

      def ensure_thread!
        return unless @auto_start
        return if @thread&.alive? && @pid == Process.pid

        @mutex.synchronize do
          # A forked child inherits the parent's queue contents and a thread
          # that no longer exists. Start clean; the parent still owns its data.
          if @pid != Process.pid
            @pid = Process.pid
            @queue = SizedQueue.new(@queue_size)
          elsif @queue.closed?
            @queue = SizedQueue.new(@queue_size)
          end

          next if @thread&.alive?

          @thread = Thread.new { run }
          @thread&.name = "rails_pulse_writer"
          install_exit_hook
        end
      end

      def run
        # pop returns nil both on timeout and once the queue is closed and empty
        loop do
          first = @queue.pop(timeout: HEARTBEAT_INTERVAL)
          if first.nil?
            break if @queue.closed?
          else
            batch = [ first ]
            batch << @queue.pop(true) while batch.size < BATCH_SIZE && !@queue.empty?
            Tracker.perform_tracking_batch(batch)
          end
          heartbeat_if_due
          Tracker.flush_rollups_if_due
        end
      rescue => e
        # perform_tracking_batch rescues its own errors, so this is a bug in the
        # loop itself. Report it; the next enqueue starts a fresh thread.
        RailsPulse.logger.error("Rails Pulse writer thread stopped: #{e.class} - #{e.message}")
      end

      def heartbeat_if_due
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @last_heartbeat_at && now - @last_heartbeat_at < HEARTBEAT_INTERVAL

        @last_heartbeat_at = now
        Tracker.record_heartbeat(take_heartbeat_sample)
      end

      def install_exit_hook
        return if @exit_hook_installed

        @exit_hook_installed = true
        at_exit { shutdown }
      end

      def record_drop
        @mutex.synchronize do
          @dropped += 1
          @drop_window_count += 1
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          next if @drop_window_started && now - @drop_window_started < DROP_LOG_INTERVAL

          RailsPulse.logger.warn(
            "Rails Pulse writer queue is full (#{@queue_size}); dropped #{@drop_window_count} " \
            "request(s) since the last notice. Raise config.async_queue_size or check database latency."
          )
          @drop_window_started = now
          @drop_window_count = 0
        end
      end
    end

    class << self
      def track_request(data)
        return if RailsPulse::Current.skip_recording_rails_pulse_activity
        return unless RailsPulse::SchemaCheck.tracking_allowed?
        return RailsPulse::Remote.track(:request, data) if RailsPulse::Remote.enabled?

        if RailsPulse.configuration.async && !connection_shared_across_threads?
          writer.enqueue(data)
          nil
        else
          perform_tracking(data)
        end
      end

      # Puts anything the writer handles on its queue: a request's payload, or
      # in remote mode an item for the central. Never blocks; false when the
      # queue is full and the item was dropped.
      def enqueue(item)
        writer.enqueue(item)
      end

      # Queue depth and lifetime drop count of the background writer, for
      # health output. Zeros before the writer has been used.
      def stats
        current = @writer
        { queue_size: current&.size || 0, dropped: current&.dropped || 0, running: current&.running? || false }
      end

      # Persist everything queued so far and stop the writer thread. The next
      # tracked request starts it again. Shutdown flushes rollups itself, but
      # inline tracking accumulates them with no writer, so flush here too.
      def flush!
        @writer&.shutdown
        flush_rollups!
      end

      # Discard the writer, queue contents included. For tests.
      def reset_writer!
        @writer_mutex.synchronize { @writer = nil }
        @last_heartbeat_prune_at = {}
      end

      # Discard the rollup accumulator, folded data included, and the route id
      # cache — a transactional test's rolled-back routes must not leak ids
      # into the next test. For tests.
      def reset_rollups!
        @writer_mutex.synchronize { @rollups = {} }
        @route_cache_mutex.synchronize { clear_route_cache(cleared_at: nil) }
      end

      def flush_rollups_if_due
        each_rollup_accumulator { |accumulator| flush_accumulator(accumulator) if accumulator.flush_due? }
      end

      # Upsert every dirty rollup bucket's cumulative totals. Errors are
      # logged, never raised: the drained rows are handed back to the
      # accumulator and retried by a later flush, so a failed write loses
      # nothing unless the outage outlasts the retention cap.
      def flush_rollups!
        each_rollup_accumulator { |accumulator| flush_accumulator(accumulator) }
      end

      # table_exists? has to run inside with_writer_connection too, or the bare
      # call pins a connection on this thread that nothing would ever release.
      #
      # The sample describes this process's writer unless it names another
      # (hostname, pid, host_label), as the heartbeats a central records for
      # its applications do. In remote mode it is sent to the central instead.
      def record_heartbeat(sample)
        sample = { hostname: hostname, pid: Process.pid, host_label: RailsPulse.configuration.cloud.host_label }.merge(sample)
        if RailsPulse::Remote.enabled?
          RailsPulse::Remote.deliver([ RailsPulse::Remote.heartbeat_item(sample) ])
          return true
        end

        with_writer_connection do
          next false unless RailsPulse::Event.table_available?

          RailsPulse::WriterHeartbeat.record!(**sample)
          prune_heartbeats_if_due
          true
        end
      rescue => e
        RailsPulse.logger.debug("Rails Pulse writer heartbeat failed: #{e.class} - #{e.message}")
        false
      end

      def hostname
        @hostname ||= Socket.gethostname
      end

      def healthy?
        RailsPulse::ApplicationRecord.connection.execute("SELECT 1")
        true
      rescue
        false
      end

      # Marks SQL operations that repeat within one request with the
      # normalized statement they share and how many times it ran. Runs on the
      # writer so the normalisation cost stays off the request thread.
      def detect_n_plus_one(operations)
        sql_ops = operations.select { |op| op[:operation_type] == "sql" }
        return if sql_ops.size < 2

        groups = sql_ops.group_by { |op| RailsPulse::SqlQueryNormalizer.normalize(op[:actual_sql].to_s) }
        groups.each do |normalized_sql, ops|
          next if ops.size < 2
          ops.each do |op|
            op[:repeated_query_group] = normalized_sql
            op[:repetition_count] = ops.size
          end
        end
      end

      # One connection checkout for the whole batch. A request that fails to
      # persist is logged and skipped; the others in the batch still land, and
      # their operations go in with a single insert. Requests detail capture
      # declined (detail: false) are folded into rollups instead of persisted.
      # In remote mode the batch is items for the central, and is sent.
      def perform_tracking_batch(batch)
        return RailsPulse::Remote.deliver(batch) if RailsPulse::Remote.enabled?

        with_writer_connection do
          detailed, folded = batch.partition { |data| data[:detail] != false }

          fold_batch(folded)

          persisted = detailed.filter_map do |data|
            request = persist_request(data)
            [ request, data[:operations] ]
          rescue => e
            log_error(e)
            nil
          end

          rows = persisted.flat_map { |request, operations| operation_rows(request, operations) }
          RailsPulse::Operation.persist_bulk(rows, {}) unless rows.empty?
        end
      rescue => e
        log_error(e)
        nil
      end

      private

      def writer
        @writer_mutex.synchronize do
          @writer ||= Writer.new(queue_size: RailsPulse.configuration.async_queue_size)
        end
      end

      # The accumulator for the database being written: the only one outside
      # a central, the current application's on one.
      def rollups
        application = RailsPulse::Central.current_application
        @writer_mutex.synchronize do
          @rollups[application] ||= RollupAccumulator.new
        end
      end

      # Yields each accumulator with its own database connected.
      def each_rollup_accumulator
        accumulators = @writer_mutex.synchronize { @rollups.to_a }
        accumulators.each do |application, accumulator|
          RailsPulse::Central.with_application(application) { yield accumulator }
        end
      end

      def flush_accumulator(accumulator)
        rows = accumulator.drain_rows
        return if rows.blank?

        with_writer_connection { RailsPulse::Rollup.upsert_rows(rows) }
      rescue => e
        accumulator.retain_failed(rows) if rows.present?
        log_error(e)
      end

      # Fold a batch's non-captured requests into the rollups. Their SQL is
      # resolved together — one SELECT for the whole batch — and when that
      # one lookup fails each request falls back to resolving its own, so a
      # transient error costs at most one request's query folds, not the
      # whole batch's.
      def fold_batch(folded)
        return if folded.empty?

        sql_durations = begin
          RailsPulse::Operation.resolve_sql_durations_many(folded.map { |data| data[:operations] })
        rescue => e
          log_error(e)
          nil
        end

        folded.each_with_index do |data, index|
          fold_rollup(data, sql_durations: sql_durations&.fetch(index))
        rescue => e
          log_error(e)
        end
      end

      # Fold one non-captured request into the rollups: the request itself
      # into its route's bucket, its SQL operations into their queries'
      # buckets. Query rows are still created by resolve_sql_durations, so a
      # query first seen in a fast request exists before it ever appears slow.
      def fold_rollup(data, sql_durations: nil)
        route_id = cached_route_id(data[:method], data[:path], data[:controller_action])
        rollups.fold_route(
          route_id: route_id,
          occurred_at: data[:occurred_at],
          duration: data[:duration],
          status: data[:status]
        )

        sql_durations ||= RailsPulse::Operation.resolve_sql_durations(data[:operations])
        sql_durations.each do |query_id, duration|
          rollups.fold_query(query_id: query_id, occurred_at: data[:occurred_at], duration: duration)
        end
      end

      # (method, path, controller_action) => route id, capped and cleared
      # wholesale when full or when ROUTE_CACHE_TTL passes. A new HTTP verb on
      # a known path misses once, which is when find_or_create_for_request
      # appends the verb. On a central the application is part of the key:
      # each one's route ids belong to its own database.
      def cached_route_id(method, path, controller_action)
        key = [ RailsPulse::Central.current_application, method, path, controller_action ]
        cached, generation = @route_cache_mutex.synchronize do
          expire_route_cache_if_due
          [ @route_id_cache[key], @route_cache_generation ]
        end
        return cached if cached

        route = RailsPulse::Route.find_or_create_for_request(method, path, controller_action: controller_action)
        @route_cache_mutex.synchronize do
          clear_route_cache if @route_id_cache.size >= ROUTE_CACHE_MAX
          # A clear since the lookup started may mean cleanup just deleted
          # this route; caching the id now would carry a possibly-dead id
          # past the clear that was meant to drop it, stretching staleness
          # beyond the TTL. The skipped miss just resolves again next fold.
          @route_id_cache[key] = route.id if @route_cache_generation == generation
        end
        route.id
      end

      # Must be called holding @route_cache_mutex.
      def expire_route_cache_if_due
        now = Time.current
        @route_cache_cleared_at ||= now
        return if now - @route_cache_cleared_at < ROUTE_CACHE_TTL

        clear_route_cache
      end

      # Must be called holding @route_cache_mutex. Every clear restarts the
      # TTL window (the cache is empty, so nothing in it can be stale) and
      # bumps the generation so in-flight lookups cannot re-insert ids the
      # clear was meant to drop. A nil cleared_at restarts the window at the
      # next lookup instead.
      def clear_route_cache(cleared_at: Time.current)
        @route_id_cache.clear
        @route_cache_generation += 1
        @route_cache_cleared_at = cleared_at
      end

      # Once per PRUNE_INTERVAL for each database written.
      def prune_heartbeats_if_due
        now = Time.current
        application = RailsPulse::Central.current_application
        last_pruned_at = @last_heartbeat_prune_at[application]
        return if last_pruned_at && now - last_pruned_at < PRUNE_INTERVAL

        @last_heartbeat_prune_at[application] = now
        RailsPulse::WriterHeartbeat.prune!
      end

      def perform_tracking(data)
        if data[:detail] == false
          with_writer_connection { fold_rollup(data) }
          # No writer loop runs on the inline path, so the interval check
          # happens here, paid by whichever request crosses it.
          flush_rollups_if_due
          return nil
        end

        with_writer_connection do
          request = persist_request(data)
          rows = operation_rows(request, data[:operations])
          RailsPulse::Operation.persist_bulk(rows, {}) unless rows.empty?
          request
        end
      rescue => e
        log_error(e)
        nil
      end

      def with_writer_connection
        RailsPulse::ApplicationRecord.connection_pool.with_connection do |conn|
          clear_aborted_transaction(conn)
          RailsPulse::Current.skip_recording_rails_pulse_activity = true
          yield
        end
      ensure
        RailsPulse::Current.skip_recording_rails_pulse_activity = false
      end

      def persist_request(data)
        route = RailsPulse::Route.find_or_create_for_request(data[:method], data[:path], controller_action: data[:controller_action])

        RailsPulse::Request.create!(
          route: route,
          method: data[:method],
          duration: data[:duration],
          status: data[:status],
          is_error: data[:is_error],
          request_uuid: data[:request_uuid],
          controller_action: data[:controller_action],
          occurred_at: data[:occurred_at],
          response_size_bytes: data[:response_size_bytes]
        )
      end

      def operation_rows(request, operations)
        operations = Array(operations)
        return [] if operations.empty?

        detect_n_plus_one(operations)
        operations.map { |op| op.merge(request_id: request.id, job_run_id: nil) }
      end

      # Transactional tests pin one connection per pool and hand that same
      # connection to every thread that asks for one. A background writer would
      # then interleave its statements with the test's on a single socket, which
      # PostgreSQL reports as "message type 0x5a arrived from server while idle".
      # Rails records the pin in the pool's @pinned_connection. That is not
      # public API, so read it defensively and treat any failure as "not shared".
      def connection_shared_across_threads?
        pool = RailsPulse::ApplicationRecord.connection_pool
        pool.instance_variable_get(:@pinned_connection) ? true : false
      rescue StandardError
        false
      end

      def clear_aborted_transaction(conn)
        raw = conn.raw_connection
        # Non-PostgreSQL adapters don't expose transaction_status, so this is a no-op for them.
        return unless raw.respond_to?(:transaction_status) && raw.transaction_status == PG_TRANSACTION_INERROR
        conn.rollback_db_transaction
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def log_error(error)
        RailsPulse.logger.error("Failed to persist tracking data: #{error.message}")
        RailsPulse.logger.error(error.backtrace.join("\n")) if RailsPulse.logger.debug?
      end
    end

    @writer = nil
    @writer_mutex = Mutex.new
    @rollups = {}
    @last_heartbeat_prune_at = {}
    @route_id_cache = {}
    @route_cache_cleared_at = nil
    @route_cache_generation = 0
    @route_cache_mutex = Mutex.new
  end
end
