# frozen_string_literal: true

module RailsPulse
  module Remote
    # Stands in for the JobRun row while a job runs in remote mode. It takes
    # the attributes JobRunCollector would have written, and the updates it
    # would have made, and is sent with the run's operations once the job
    # ends. The central records it with the same writes, in the same order:
    # the run as it started, then its outcome (JobRunCollector.record).
    class JobRun
      attr_reader :attributes

      # @param attributes [Hash] job_class, queue_name, run_id and the
      #   attributes the run starts with, status included
      def initialize(attributes)
        @attributes = attributes.merge(initial_status: attributes[:status])
      end

      # The run id. JobRunCollector keeps it as the current job run id, and
      # the operation subscriber records operations only while one is set.
      def id
        attributes[:run_id]
      end

      def update!(changes)
        attributes.merge!(changes)
        true
      end

      def track(operations)
        Remote.track(:job_run, attributes.merge(operations: operations))
      end
    end
  end
end
