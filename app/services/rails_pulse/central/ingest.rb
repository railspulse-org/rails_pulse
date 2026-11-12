module RailsPulse
  module Central
    # Records one batch an application sent (RailsPulse::Remote::Batch) in
    # the database Rails Pulse is connected to, which the caller points at
    # that application's shard (Central.with_application). Each item goes
    # through the code that records the same thing where it is collected:
    #
    #   request           Tracker.perform_tracking_batch: route, request,
    #                     operations, N+1 marks, or rollups for a folded one
    #   job_run           JobRunCollector.record
    #   exception         ExceptionCaptureService.record
    #   writer_heartbeat  Tracker.record_heartbeat
    #   deployment        Deployment, as the rake tasks write it
    #
    # Items are decoded against the contract first, field by field, into the
    # shapes those methods take, so nothing the sender adds reaches a table.
    # An item that does not match is rejected on its own and the rest are
    # still recorded; an envelope that does not match raises Invalid and
    # nothing is. A batch whose batch_id was already recorded is acknowledged
    # without being recorded again, which makes a retry after a lost response
    # harmless.
    class Ingest
      # The batch as a whole cannot be read: answered with 422.
      class Invalid < StandardError; end

      TYPES = %w[deployment request job_run exception writer_heartbeat].freeze
      MAX_ITEMS = 1_000
      MAX_OPERATIONS = 10_000
      MAX_ERRORS = 20
      BATCH_ID_FORMAT = /\A[0-9A-Za-z-]{1,64}\z/

      # Each recorded batch leaves an Event, which is how a resend is
      # recognised; they are pruned after a day.
      BATCH_KIND = "remote_batch".freeze
      BATCH_RETENTION = 1.day
      PRUNE_INTERVAL = 1.hour

      DEPLOYMENT_ACTIONS = %w[record finish].freeze

      # The keys an operation may carry: what the subscribers collect. Its
      # request, job run and query, and its N+1 marks, are set here. A folded
      # request's SQL carries only the first four.
      OPERATION_FIELDS = {
        "operation_type" => :string, "label" => :string, "actual_sql" => :string, "duration" => :number,
        "codebase_location" => :string, "start_time" => :number, "occurred_at" => :time,
        "row_count" => :integer, "cache_hit" => :boolean
      }.freeze
      SLIM_OPERATION_FIELDS = %w[operation_type label actual_sql duration].freeze

      Result = Struct.new(:batch_id, :accepted, :rejected, :errors, :duplicate, keyword_init: true)

      # Raised for one item's field; the item is rejected with the message.
      class ItemError < StandardError; end

      @last_pruned_at = {}
      @prune_mutex = Mutex.new

      class << self
        # Prunes this database's batch events at most once per PRUNE_INTERVAL.
        def prune_if_due(now)
          application = RailsPulse::Central.current_application
          due = @prune_mutex.synchronize do
            last = @last_pruned_at[application]
            next false if last && now - last < PRUNE_INTERVAL

            @last_pruned_at[application] = now
          end
          RailsPulse::Event.of_kind(BATCH_KIND).where(occurred_at: ...(now - BATCH_RETENTION)).delete_all if due
        end
      end

      def initialize(payload, now: Time.current)
        @payload = payload
        @now = now
        @errors = []
        @rejected = 0
      end

      # @return [Result]
      def perform
        validate_envelope!
        batch_id = @payload["batch_id"]
        return Result.new(batch_id: batch_id, accepted: 0, rejected: 0, errors: [], duplicate: true) if recorded?(batch_id)

        decoded = decode_items
        accepted = record(decoded)
        remember(batch_id, accepted)

        Result.new(batch_id: batch_id, accepted: accepted, rejected: @rejected, errors: @errors, duplicate: false)
      end

      private

      def validate_envelope!
        raise Invalid, "the batch must be a JSON object" unless @payload.is_a?(Hash)

        version = @payload["version"]
        unless version == RailsPulse::Remote::CONTRACT
          raise Invalid, "contract version #{version.inspect} is not supported; this central accepts #{RailsPulse::Remote::CONTRACT}"
        end

        unless @payload["batch_id"].is_a?(String) && @payload["batch_id"].match?(BATCH_ID_FORMAT)
          raise Invalid, "batch_id must be a string of up to 64 letters, digits and dashes"
        end

        items = @payload["items"]
        raise Invalid, "items must be an array" unless items.is_a?(Array)
        raise Invalid, "items holds #{items.size} entries; at most #{MAX_ITEMS} are accepted per batch" if items.size > MAX_ITEMS
      end

      # -- Decoding -------------------------------------------------------

      # [[type, attributes], ...] for the items that match the contract.
      def decode_items
        @payload["items"].each_with_index.filter_map do |item, index|
          raise ItemError, "must be an object" unless item.is_a?(Hash)

          type = item["type"]
          raise ItemError, "has an unknown type #{type.inspect}" unless TYPES.include?(type)

          [ type, send("decode_#{type}", item) ]
        rescue ItemError => e
          reject(index, item.is_a?(Hash) ? item["type"] : nil, e.message)
          nil
        end
      end

      def decode_request(item)
        request = {
          method:            string(item, "method", required: true),
          path:              string(item, "path", required: true),
          duration:          number(item, "duration", required: true),
          status:            integer(item, "status", required: true),
          controller_action: string(item, "controller_action"),
          occurred_at:       time(item, "occurred_at", required: true)
        }
        detail = boolean(item, "detail")

        # A request detail capture declined: route identity, duration and
        # status, and its SQL reduced to statement and duration.
        return request.merge(detail: false, operations: operations(item, slim: true)) if detail == false

        request[:detail] = true if detail
        request.merge(
          is_error:            boolean(item, "is_error").then { |value| value.nil? ? request[:status] >= 500 : value },
          request_uuid:        string(item, "request_uuid", required: true),
          response_size_bytes: integer(item, "response_size_bytes"),
          operations:          operations(item)
        )
      end

      def decode_job_run(item)
        {
          job_class:      string(item, "job_class", required: true),
          queue_name:     string(item, "queue_name"),
          run_id:         string(item, "run_id", required: true),
          initial_status: string(item, "initial_status", required: true, one_of: RailsPulse::JobRun::STATUSES),
          status:         string(item, "status", required: true, one_of: RailsPulse::JobRun::STATUSES),
          enqueued_at:    time(item, "enqueued_at"),
          occurred_at:    time(item, "occurred_at", required: true),
          attempts:       integer(item, "attempts"),
          adapter:        string(item, "adapter"),
          arguments:      string(item, "arguments"),
          duration:       number(item, "duration"),
          error_class:    string(item, "error_class"),
          error_message:  string(item, "error_message"),
          operations:     operations(item)
        }
      end

      def decode_exception(item)
        {
          exception_class: string(item, "exception_class", required: true),
          location:        string(item, "location", required: true),
          message:         string(item, "message"),
          backtrace:       backtrace(item),
          request_url:     string(item, "request_url"),
          request_method:  string(item, "request_method"),
          request_params:  object(item, "request_params"),
          environment:     string(item, "environment"),
          deploy_sha:      string(item, "deploy_sha"),
          occurred_at:     time(item, "occurred_at", required: true)
        }
      end

      def decode_writer_heartbeat(item)
        {
          hostname:      string(item, "hostname", required: true),
          pid:           integer(item, "pid", required: true),
          host_label:    string(item, "host_label"),
          queue_size:    integer(item, "queue_size", required: true),
          queue_depth:   integer(item, "queue_depth", required: true),
          dropped:       integer(item, "dropped", required: true),
          dropped_total: integer(item, "dropped_total", required: true),
          sampled_at:    time(item, "sampled_at", required: true)
        }
      end

      def decode_deployment(item)
        action = string(item, "action", required: true, one_of: DEPLOYMENT_ACTIONS)
        revision = string(item, "revision", required: true)
        return { action: action, revision: revision, finished_at: time(item, "finished_at", required: true) } if action == "finish"

        {
          action:      action,
          revision:    revision,
          started_at:  time(item, "started_at", required: true),
          finished_at: time(item, "finished_at"),
          metadata:    object(item, "metadata")
        }
      end

      # Only the keys an operation was sent with are kept, so the rows have
      # the same keys they would have had where it was collected.
      def operations(item, slim: false)
        list = item["operations"]
        return [] if list.nil?
        raise ItemError, "operations must be an array" unless list.is_a?(Array)
        raise ItemError, "operations holds more than #{MAX_OPERATIONS} entries" if list.size > MAX_OPERATIONS

        fields = slim ? OPERATION_FIELDS.slice(*SLIM_OPERATION_FIELDS) : OPERATION_FIELDS
        list.each_with_index.map do |operation, index|
          raise ItemError, "operations[#{index}] must be an object" unless operation.is_a?(Hash)

          decoded = fields.each_with_object({}) do |(key, type), out|
            next unless operation.key?(key)

            out[key.to_sym] = send(type, operation, key, label: "operations[#{index}].#{key}")
          end
          check_operation!(decoded, index, slim)
          decoded
        end
      end

      def check_operation!(operation, index, slim)
        unless RailsPulse::Operation::OPERATION_TYPES.include?(operation[:operation_type])
          raise ItemError, "operations[#{index}].operation_type must be one of #{RailsPulse::Operation::OPERATION_TYPES.join(', ')}"
        end
        raise ItemError, "operations[#{index}].duration is required" if operation[:duration].nil?
        return if slim

        raise ItemError, "operations[#{index}].occurred_at is required" if operation[:occurred_at].nil?

        # The column is NOT NULL with a default, which an explicit NULL skips.
        operation[:start_time] ||= 0.0
      end

      def backtrace(item)
        frames = item["backtrace"]
        return [] if frames.nil?
        raise ItemError, "backtrace must be an array" unless frames.is_a?(Array)

        frames.first(RailsPulse::ExceptionCaptureService::BACKTRACE_FRAME_LIMIT).each_with_index.map do |frame, index|
          raise ItemError, "backtrace[#{index}] must be an object" unless frame.is_a?(Hash)

          {
            file:   string(frame, "file", required: true, label: "backtrace[#{index}].file"),
            line:   integer(frame, "line", required: true, label: "backtrace[#{index}].line"),
            method: string(frame, "method", required: true, label: "backtrace[#{index}].method")
          }
        end
      end

      def string(source, key, required: false, one_of: nil, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be a string" unless value.is_a?(String)
        raise ItemError, "#{label} must be one of #{one_of.join(', ')}" if one_of && !one_of.include?(value)

        value
      end

      def number(source, key, required: false, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be a number of zero or more" unless value.is_a?(Numeric) && value >= 0

        value.to_f
      end

      def integer(source, key, required: false, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be a whole number" unless value.is_a?(Integer)

        value
      end

      def boolean(source, key, required: false, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be true or false" unless value == true || value == false

        value
      end

      def time(source, key, required: false, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be an ISO 8601 time" unless value.is_a?(String)

        Time.iso8601(value).in_time_zone
      rescue ArgumentError
        raise ItemError, "#{label} must be an ISO 8601 time"
      end

      def object(source, key, required: false, label: key)
        value = fetch(source, key, required, label)
        return nil if value.nil?
        raise ItemError, "#{label} must be an object" unless value.is_a?(Hash)

        value
      end

      def fetch(source, key, required, label)
        value = source[key]
        raise ItemError, "#{label} is required" if required && value.nil?

        value
      end

      def reject(index, type, message)
        @rejected += 1
        @errors << "items[#{index}]#{" (#{type})" if type.is_a?(String)}: #{message}" if @errors.size < MAX_ERRORS
      end

      # -- Recording ------------------------------------------------------

      # Deployments first, so an exception in the same batch is stamped with
      # the revision it shipped in.
      def record(decoded)
        by_type = decoded.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        accepted = 0

        Array(by_type["deployment"]).each { |deployment| accepted += 1 if record_deployment(deployment) }

        requests = Array(by_type["request"])
        if requests.any?
          RailsPulse::Tracker.perform_tracking_batch(requests)
          RailsPulse::Tracker.flush_rollups_if_due
          accepted += requests.size
        end

        Array(by_type["job_run"]).each { |run| accepted += 1 if attempt("job_run") { RailsPulse::JobRunCollector.record(run) } }
        Array(by_type["exception"]).each do |exception|
          accepted += 1 if attempt("exception") { RailsPulse::ExceptionCaptureService.record(exception) || true }
        end
        Array(by_type["writer_heartbeat"]).each do |heartbeat|
          accepted += 1 if attempt("writer_heartbeat") { RailsPulse::Tracker.record_heartbeat(heartbeat) || raise("not recorded") }
        end

        accepted
      end

      def record_deployment(deployment)
        attempt("deployment") do
          if deployment[:action] == "finish"
            row = RailsPulse::Deployment.latest_for_revision(deployment[:revision])
            raise ActiveRecord::RecordNotFound, "no deployment recorded for revision #{deployment[:revision]}" unless row

            row.update!(finished_at: deployment[:finished_at])
          else
            RailsPulse::Deployment.create!(deployment.except(:action).merge(metadata: deployment[:metadata]&.to_json))
          end
        end
      end

      # A failure to record one item is the sender's to see, as a rejection,
      # and this central's to log; the other items are still recorded.
      def attempt(type)
        yield
        true
      rescue StandardError => e
        RailsPulse.logger.error("[RailsPulse] Could not record a #{type} sent to the central: #{e.class} - #{e.message}")
        @rejected += 1
        @errors << "#{type}: #{e.message}" if @errors.size < MAX_ERRORS
        false
      end

      def recorded?(batch_id)
        RailsPulse::Event.of_kind(BATCH_KIND).for_subject(batch_id).exists?
      end

      def remember(batch_id, accepted)
        RailsPulse::Event.insert_all([ {
          kind:        BATCH_KIND,
          subject:     batch_id,
          outcome:     "recorded",
          value:       accepted,
          occurred_at: @now,
          metadata:    { hostname: @payload["hostname"], pid: @payload["pid"], items: @payload["items"].size,
                         rejected: @rejected }.compact.to_json,
          created_at:  @now,
          updated_at:  @now
        } ])
        self.class.prune_if_due(@now)
      rescue StandardError => e
        RailsPulse.logger.error("[RailsPulse] Could not remember batch #{batch_id}: #{e.class} - #{e.message}")
      end
    end
  end
end
