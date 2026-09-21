module RailsPulse
  # The background writer's once-a-minute sample, stored as an Event of kind
  # writer_heartbeat: `subject` is "host:pid", `value` the requests dropped
  # since the previous sample, and `metadata` the queue depth, its configured
  # capacity and the lifetime drop count. Stats are otherwise per process, so
  # with eight Puma workers the dashboard could only ever see the one that
  # happened to serve it; these rows let it, the Storage page and
  # rails_pulse:status add every live writer up.
  class WriterHeartbeat
    KIND = "writer_heartbeat".freeze
    # A writer that has not reported for this long is treated as gone.
    LIVE_WINDOW = 3.minutes
    RETENTION = 24.hours

    Sample = Struct.new(:hostname, :pid, :queue_size, :queue_depth, :dropped_total, :sampled_at, keyword_init: true) do
      def process_label
        "#{hostname}:#{pid}"
      end
    end

    class << self
      def events
        RailsPulse::Event.of_kind(KIND)
      end

      def record!(hostname:, pid:, queue_size:, queue_depth:, dropped:, dropped_total:, sampled_at: Time.current)
        RailsPulse::Event.insert_all([ {
          kind:        KIND,
          subject:     "#{hostname}:#{pid}",
          outcome:     "sampled",
          value:       dropped,
          occurred_at: sampled_at,
          metadata:    { hostname: hostname, pid: pid, queue_size: queue_size, queue_depth: queue_depth, dropped_total: dropped_total }.to_json,
          created_at:  sampled_at,
          updated_at:  sampled_at
        } ])
      end

      def prune!
        events.where(occurred_at: ...RETENTION.ago).delete_all
      end

      # The latest sample from each writer that reported inside LIVE_WINDOW,
      # newest first. A handful of rows per process, reduced in Ruby.
      def live_processes
        events.since(LIVE_WINDOW.ago).recent.to_a.uniq(&:subject).map { |event| sample_from(event) }
      end

      # { "host:pid" => requests dropped inside `window` }
      def dropped_by_process(window: 1.hour)
        events.since(window.ago).group(:subject).sum(:value).transform_values(&:to_i)
      end

      # What the dashboard, Storage page and status task show:
      #   processes        live writers
      #   queue_depth      requests waiting across them, from each one's latest sample
      #   queue_size       the largest configured capacity among them
      #   dropped          requests dropped inside `window`, across every process
      #   last_sampled_at  most recent heartbeat, nil when there is none
      def summary(window: 1.hour)
        processes = live_processes
        {
          processes:       processes.size,
          queue_depth:     processes.sum(&:queue_depth),
          queue_size:      processes.map(&:queue_size).max || 0,
          dropped:         events.since(window.ago).sum(:value).to_i,
          last_sampled_at: events.maximum(:occurred_at)
        }
      end

      private

      def sample_from(event)
        meta = event.metadata_hash
        Sample.new(
          hostname:      meta["hostname"],
          pid:           meta["pid"],
          queue_size:    meta["queue_size"].to_i,
          queue_depth:   meta["queue_depth"].to_i,
          dropped_total: meta["dropped_total"].to_i,
          sampled_at:    event.occurred_at
        )
      end
    end
  end
end
