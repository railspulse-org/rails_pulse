# frozen_string_literal: true

module RailsPulse
  # Remote mode: instead of writing to this application's database, Rails
  # Pulse sends what it collects to a central Rails Pulse
  # (RailsPulse::Central) in batches over HTTPS. On when config.remote.url
  # and config.remote.token are both set.
  #
  # Collection is unchanged; only the last step differs. A request, a job
  # run or an exception becomes an Item on the writer's queue (Tracker), and
  # the writer thread posts each batch it drains, so nothing is sent from a
  # request or job thread, a full queue drops the newest item as it always
  # has, and no Rails Pulse table is read or written in this process. The
  # writer's heartbeat and the deployment rake tasks travel as items too.
  # The central records every item with the code that would have recorded
  # it here. The contract is in the README, "Remote and central modes".
  module Remote
    CONTRACT = 1
    BATCHES_PATH = "/rails_pulse/v1/batches"

    # One collected thing on its way to the central: its type (request,
    # job_run, exception, writer_heartbeat or deployment) and its attributes
    # as collected. Encoded only when sent, on the writer thread, so queueing
    # one costs the request thread nothing more than queueing a request does.
    Item = Struct.new(:type, :attributes)

    class << self
      def enabled?
        RailsPulse.configuration&.remote&.enabled? || false
      end

      # Hands one item to the background writer, which sends it with the next
      # batch, or sends it now with config.async = false. Never raises: a
      # failure to send must not become the host's error.
      def track(type, attributes)
        item = Item.new(type.to_s, attributes)
        if RailsPulse.configuration.async
          RailsPulse::Tracker.enqueue(item)
        else
          deliver([ item ])
        end
        nil
      rescue StandardError => e
        RailsPulse.logger.error("Rails Pulse could not queue a #{type} for the central: #{e.class} - #{e.message}")
        nil
      end

      # Sends the writer's batch. Called on the writer thread by
      # Tracker.perform_tracking_batch; never raises.
      def deliver(items)
        sender.deliver(items)
      end

      # Sends the items at once, on this thread, and returns the central's
      # Client::Response. Raises Client::Unavailable when the central cannot
      # be reached. For the deployment rake tasks, which have no writer and
      # report the outcome to whoever ran them.
      def deliver_now(items)
        Client.new.post(Batch.new(items).body)
      end

      # The writer's heartbeat (Tracker.record_heartbeat) as an item. Items
      # this process could not deliver count as dropped, as a full queue's
      # do, so the central's Tracking badge shows both.
      def heartbeat_item(sample)
        attributes = sample.merge(
          dropped: sample[:dropped].to_i + sender.take_dropped,
          dropped_total: sample[:dropped_total].to_i + sender.dropped_total
        )
        Item.new("writer_heartbeat", { sampled_at: Time.current }.merge(attributes))
      end

      def sender
        @sender_mutex.synchronize { @sender ||= Sender.new }
      end

      # Discard the sender and any batches it was holding. For tests.
      def reset!
        @sender_mutex.synchronize { @sender = nil }
      end
    end

    @sender = nil
    @sender_mutex = Mutex.new
  end
end

require "rails_pulse/remote/batch"
require "rails_pulse/remote/client"
require "rails_pulse/remote/sender"
require "rails_pulse/remote/job_run"
