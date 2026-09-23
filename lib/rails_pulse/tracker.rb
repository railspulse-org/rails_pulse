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
  module Tracker
    # PG::Connection::PQTRANS_INERROR (libpq enum value 3) — the connection's transaction
    # was aborted by a DB-level error and no ROLLBACK has been issued yet. Defined as a
    # constant to avoid a hard dependency on the pg gem. The full enum is:
    #   PQTRANS_IDLE=0, PQTRANS_ACTIVE=1, PQTRANS_INTRANS=2, PQTRANS_INERROR=3, PQTRANS_UNKNOWN=4
    PG_TRANSACTION_INERROR = 3
    private_constant :PG_TRANSACTION_INERROR

    # How often record_heartbeat prunes stale heartbeat rows. Heartbeats fire
    # every 60s per process; pruning on every one of them is redundant I/O on
    # the exact connection-usage path this design tries to minimize, since
    # almost every prune finds nothing to delete.
    PRUNE_INTERVAL = 1.hour
    private_constant :PRUNE_INTERVAL

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

      # The next heartbeat's payload: configured capacity, current depth, drops
      # since the previous sample and since the process started. Taking a
      # sample starts the next drop window.
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
        drain
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
        # pop returns nil on the timeout and once the queue is closed and empty;
        # the timeout is what lets an idle writer still send its heartbeat.
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
        return if RequestStore.store[:skip_recording_rails_pulse_activity]
        return unless RailsPulse::SchemaCheck.tracking_allowed?

        if RailsPulse.configuration.async && !connection_shared_across_threads?
          writer.enqueue(data)
          nil
        else
          perform_tracking(data)
        end
      end

      # Queue depth and lifetime drop count of the background writer, for
      # health output. Zeros before the writer has been used.
      def stats
        current = @writer
        { queue_size: current&.size || 0, dropped: current&.dropped || 0, running: current&.running? || false }
      end

      # Persist everything queued so far and stop the writer thread. The next
      # tracked request starts it again.
      def flush!
        @writer&.shutdown
      end

      # Discard the writer, queue contents included. For tests.
      def reset_writer!
        @writer_mutex.synchronize { @writer = nil }
        @last_heartbeat_prune_at = nil
      end

      # Writes one WriterHeartbeat event for this process and prunes old ones.
      # Never raises: a heartbeat that fails must not take the writer down.
      # table_exists? has to run inside with_writer_connection too — a bare
      # call on the writer thread checks out a connection that nothing else
      # on this thread would ever release, permanently pinning one connection
      # from the pool starting with the first heartbeat.
      def record_heartbeat(sample)
        with_writer_connection do
          next false unless RailsPulse::Event.table_available?

          RailsPulse::WriterHeartbeat.record!(hostname: hostname, pid: Process.pid, **sample)
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
      # their operations go in with a single insert.
      def perform_tracking_batch(batch)
        with_writer_connection do
          persisted = batch.filter_map do |data|
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

      def prune_heartbeats_if_due
        now = Time.current
        return if @last_heartbeat_prune_at && now - @last_heartbeat_prune_at < PRUNE_INTERVAL

        @last_heartbeat_prune_at = now
        RailsPulse::WriterHeartbeat.prune!
      end

      def perform_tracking(data)
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
          RequestStore.store[:skip_recording_rails_pulse_activity] = true
          yield
        end
      ensure
        RequestStore.store[:skip_recording_rails_pulse_activity] = false
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
      # Rails 7.2+ records the pin in the pool's @pinned_connection; 7.1 sets a
      # @lock_thread on the pool instead. Neither is public API, so read both
      # defensively and treat any failure as "not shared".
      def connection_shared_across_threads?
        pool = RailsPulse::ApplicationRecord.connection_pool
        return true if pool.instance_variable_get(:@pinned_connection)

        pool.instance_variable_get(:@lock_thread) ? true : false
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
  end
end
