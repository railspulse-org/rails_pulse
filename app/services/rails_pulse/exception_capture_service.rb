module RailsPulse
  class ExceptionCaptureService
    APP_FRAME_PATTERN = %r{/app/|/lib/|/config/}
    # /lib/ruby/ matches interpreter stdlib (…/lib/ruby/3.3.0/…) without
    # treating project paths that happen to contain "ruby" as gem code.
    GEM_FRAME_PATTERN = %r{/gems/|/rubygems/|/bundler/|/lib/ruby/}

    PARAMS_SIZE_LIMIT = 10_240 # 10KB
    DEPLOY_SHA_TTL    = 60     # seconds
    # Cap stored frames so a pathological backtrace cannot balloon the row.
    BACKTRACE_FRAME_LIMIT = 50

    # Cached on the class so every request in this process shares one value instead
    # of each hitting the DB. Because multiple threads can call capture concurrently,
    # the cache variables need a mutex to prevent torn reads/writes.
    @_deploy_sha_mutex     = Mutex.new # guards @_deploy_sha_value and @_deploy_sha_cached_at
    @_deploy_sha_value     = nil
    @_deploy_sha_cached_at = nil

    class << self
      def capture(exception, request_url: nil, request_method: nil, request_params: nil, environment: nil, deploy_sha: nil)
        return unless RailsPulse::SchemaCheck.tracking_allowed?

        new(exception, request_url: request_url, request_method: request_method, request_params: request_params, environment: environment, deploy_sha: deploy_sha).capture
      end

      def fetch_deploy_sha
        @_deploy_sha_mutex.synchronize do
          # Check expiry inside the lock so only one thread does the DB query when
          # the cache is cold — other threads block here and then see the fresh value.
          if @_deploy_sha_cached_at.nil? || (Time.current.to_f - @_deploy_sha_cached_at) >= DEPLOY_SHA_TTL
            @_deploy_sha_value     = RailsPulse::Deployment.order(started_at: :desc).first&.revision
            @_deploy_sha_cached_at = Time.current.to_f
          end
          @_deploy_sha_value
        end
      end

      def reset_deploy_sha_cache!
        @_deploy_sha_mutex.synchronize do
          @_deploy_sha_value     = nil
          @_deploy_sha_cached_at = nil
        end
      end
    end

    def initialize(exception, request_url: nil, request_method: nil, request_params: nil, environment: nil, deploy_sha: nil)
      @exception = exception
      @request_url = request_url
      @request_method = request_method
      @request_params = request_params
      @environment = environment || Rails.env.to_s
      @deploy_sha = deploy_sha
    end

    def capture
      return unless RailsPulse.configuration.track_exceptions
      return if RequestStore.store[:skip_recording_rails_pulse_activity]

      frames      = parse_backtrace(@exception.backtrace || [])
      location    = fingerprint_location(frames)
      fingerprint = Digest::SHA256.hexdigest("#{@exception.class.name}:#{location}")
      now         = Time.current

      group = upsert_group(fingerprint, location, now)
      create_occurrence(group, frames, now) unless group.status == "ignored"
    rescue => e
      Rails.logger.error("[RailsPulse] ExceptionCaptureService error: #{e.message}")
      nil
    end


    private

    # Memoized: both upsert_group and create_occurrence need the sanitized
    # message, and this runs on the host's error path.
    def sanitize_exception_message(exception)
      @sanitize_exception_message ||= ExceptionMessageSanitizer.for_exception(exception)
    end

    # Reusable aborted-transaction recovery shared with Tracker.
    def clear_aborted_transaction(conn)
      raw = conn.raw_connection
      return unless raw.respond_to?(:transaction_status) && raw.transaction_status == 3 # PG_TRANSACTION_INERROR
      conn.rollback_db_transaction
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def parse_backtrace(raw_backtrace)
      raw_backtrace.first(BACKTRACE_FRAME_LIMIT).filter_map do |line|
        match = line.match(/\A(.+):(\d+):in ['`](.+?)'\z/)
        next unless match
        { file: match[1], line: match[2].to_i, method: match[3] }
      end
    end

    def first_app_frame(frames)
      frames.find { |f| f[:file].match?(APP_FRAME_PATTERN) && !f[:file].match?(GEM_FRAME_PATTERN) }
    end

    # Relative path used in the fingerprint and stored on the group so
    # Capistrano-style release prefixes do not split groups across deploys.
    def fingerprint_location(frames)
      frame = first_app_frame(frames)
      return "unknown" unless frame

      path = normalize_app_path(frame[:file])
      anonymous = frame[:method].include?("block") || frame[:method].start_with?("<")
      anonymous ? "#{path}:#{frame[:line]}" : "#{path}##{frame[:method]}"
    end

    def normalize_app_path(file)
      path = file.to_s
      root = Rails.root.to_s.chomp("/")
      if root.present? && path.start_with?("#{root}/")
        return path.delete_prefix("#{root}/")
      end

      # Rightmost /app/, /lib/, or /config/ so Capistrano paths like
      # /var/www/app/releases/TIMESTAMP/app/models/user.rb keep only app/models/user.rb.
      if (idx = path.rindex(/\/(?:app|lib|config)\//))
        path[(idx + 1)..]
      else
        path
      end
    end

    # Single SQL upsert: inserts a new group or updates the existing one.
    # occurrence_count is incremented atomically in the same statement, so no
    # separate update_counters call is needed and no race window exists.
    def upsert_group(fingerprint, location, now)
      message = sanitize_exception_message(@exception)
      conn    = ExceptionGroup.connection
      clear_aborted_transaction(conn)

      # Explicitly set status/preserve: SQLite schema dumps omit boolean DEFAULT false,
      # so omitting those columns makes INSERT fail with NOT NULL on preserve.
      if conn.adapter_name.downcase.include?("mysql")
        conn.execute(<<~SQL)
          INSERT INTO rails_pulse_exception_groups
            (fingerprint, exception_class, location, message, first_seen_at, last_seen_at, occurrence_count, status, preserve, created_at, updated_at)
          VALUES (
            #{conn.quote(fingerprint)},
            #{conn.quote(@exception.class.name)},
            #{conn.quote(location)},
            #{conn.quote(message)},
            #{conn.quote(now)},
            #{conn.quote(now)},
            1,
            #{conn.quote("open")},
            #{conn.quote(false)},
            #{conn.quote(now)},
            #{conn.quote(now)}
          )
          ON DUPLICATE KEY UPDATE
            exception_class  = VALUES(exception_class),
            location         = VALUES(location),
            message          = VALUES(message),
            last_seen_at     = VALUES(last_seen_at),
            occurrence_count = occurrence_count + 1,
            updated_at       = VALUES(updated_at)
        SQL
      else
        conn.execute(<<~SQL)
          INSERT INTO rails_pulse_exception_groups
            (fingerprint, exception_class, location, message, first_seen_at, last_seen_at, occurrence_count, status, preserve, created_at, updated_at)
          VALUES (
            #{conn.quote(fingerprint)},
            #{conn.quote(@exception.class.name)},
            #{conn.quote(location)},
            #{conn.quote(message)},
            #{conn.quote(now)},
            #{conn.quote(now)},
            1,
            #{conn.quote("open")},
            #{conn.quote(false)},
            #{conn.quote(now)},
            #{conn.quote(now)}
          )
          ON CONFLICT (fingerprint) DO UPDATE SET
            exception_class  = EXCLUDED.exception_class,
            location         = EXCLUDED.location,
            message          = EXCLUDED.message,
            last_seen_at     = EXCLUDED.last_seen_at,
            occurrence_count = rails_pulse_exception_groups.occurrence_count + 1,
            updated_at       = EXCLUDED.updated_at
        SQL
      end

      group = ExceptionGroup.find_by!(fingerprint: fingerprint)

      ExceptionGroup.where(id: group.id, status: "resolved")
                    .update_all(status: "open", resolved_at: nil, updated_at: Time.current)

      group
    end

    def current_deploy_sha
      self.class.fetch_deploy_sha
    end

    def filtered_params
      return nil unless RailsPulse.configuration.capture_exception_params
      return nil if @request_params.blank?

      params_hash = @request_params.respond_to?(:to_unsafe_h) ? @request_params.to_unsafe_h : @request_params.to_h
      filter      = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered    = filter.filter(params_hash)

      serialized = filtered.to_json
      serialized.bytesize <= PARAMS_SIZE_LIMIT ? filtered : nil
    end

    def create_occurrence(group, frames, now)
      ExceptionOccurrence.create!(
        exception_group: group,
        exception_class: @exception.class.name,
        message:         sanitize_exception_message(@exception),
        backtrace:       frames,
        request_url:     @request_url,
        request_method:  @request_method,
        request_params:  filtered_params,
        environment:     @environment,
        deploy_sha:      @deploy_sha || current_deploy_sha,
        occurred_at:     now
      )
    end
  end
end
