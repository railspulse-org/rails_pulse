module RailsPulse
  module Subscribers
    class OperationSubscriber
      class << self
        def subscribe!
          subscribe_sql_queries!
          subscribe_controller_actions!
          subscribe_template_rendering!
          subscribe_partial_rendering!
          subscribe_layout_rendering!
          subscribe_cache_read!
          subscribe_cache_write!
          subscribe_http_requests!
          subscribe_active_job!
          subscribe_collection_rendering!
          subscribe_mailer!
          subscribe_active_storage!
        end

        private

        def clean_sql_label(sql)
          return sql unless sql
          return sql unless sql.include?("/*")
          sql.gsub(/\/\*[^*]*\*\//, "").strip
        end

        def relative_path(absolute_path)
          return absolute_path unless absolute_path&.start_with?("/")

          rails_root = Rails.root.to_s
          if absolute_path.start_with?(rails_root)
            absolute_path.sub(rails_root + "/", "")
          else
            absolute_path
          end
        end

        def app_path
          @app_path ||= Rails.root.join("app").to_s
        end

        def find_app_frame
          caller_locations.each do |loc|
            path = loc.absolute_path || loc.path
            return path if path && path.start_with?(app_path)
          end
          nil
        end

        def controller_action_source_location(payload)
          return nil unless payload[:controller] && payload[:action]

          cache_key = "#{payload[:controller]}##{payload[:action]}"
          @source_location_cache ||= {}
          return @source_location_cache[cache_key] if @source_location_cache.key?(cache_key)

          result = nil
          begin
            controller_klass = payload[:controller].constantize
            if controller_klass.instance_methods(false).include?(payload[:action].to_sym)
              file, line = controller_klass.instance_method(payload[:action]).source_location
              result = "#{relative_path(file)}:#{line}" if file && line
            end
            # fallback: try superclass (for ApplicationController actions)
            if result.nil? && controller_klass.superclass.respond_to?(:instance_method)
              if controller_klass.superclass.instance_methods(false).include?(payload[:action].to_sym)
                file, line = controller_klass.superclass.instance_method(payload[:action]).source_location
                result = "#{relative_path(file)}:#{line}" if file && line
              end
            end
          rescue => e
            RailsPulse.logger.debug "Could not resolve controller source location: #{e.class} - #{e.message}"
          end

          @source_location_cache[cache_key] = result
        end

        def capture_operation(event_name, start, finish, payload, operation_type, label_key = nil, extra: {})
          return unless RailsPulse.configuration.enabled
          return if RequestStore.store[:skip_recording_rails_pulse_activity]

          request_id = RequestStore.store[:rails_pulse_request_id]
          job_run_id = RequestStore.store[:rails_pulse_job_run_id]
          return unless request_id || job_run_id

          # Skip RailsPulse-related operations to prevent recursion
          if operation_type == "sql"
            sql = payload[:sql]
            return if sql&.include?("rails_pulse_")
          end

          actual_sql = nil
          label = case label_key
          when :sql
            actual_sql = clean_sql_label(payload[:sql])
            nil  # associate_query sets label from normalized SQL
          when :template then relative_path(payload[:identifier] || payload[:template])
          when :partial then relative_path(payload[:identifier] || payload[:partial])
          when :controller then "#{payload[:controller]}##{payload[:action]}"
          when :cache then payload[:key]
          else payload[label_key] || event_name
          end

          codebase_location =
            if payload[:identifier]
              relative_path(payload[:identifier])
            elsif payload[:template]
              relative_path(payload[:template])
            elsif operation_type == "controller"
              controller_action_source_location(payload) || find_app_frame || caller_locations(3, 1).first&.path
            elsif operation_type == "sql"
              relative_path(find_app_frame || caller_locations(3, 1).first&.path)
            else
              find_app_frame || caller_locations(3, 1).first&.path
            end

          operation_data = {
            request_id: request_id,
            job_run_id: job_run_id,
            operation_type: operation_type,
            label: label,
            actual_sql: actual_sql,
            duration: [ (finish - start) * 1000, 0 ].max,
            codebase_location: codebase_location,
            start_time: start.to_f,
            occurred_at: Time.zone.at(start)
          }.merge(extra)

          RequestStore.store[:rails_pulse_operations] ||= []
          RequestStore.store[:rails_pulse_operations] << operation_data
        end

        def store_operation(label:, operation_type:, start:, finish:, codebase_location:)
          return unless RailsPulse.configuration.enabled
          return if RequestStore.store[:skip_recording_rails_pulse_activity]

          request_id = RequestStore.store[:rails_pulse_request_id]
          job_run_id = RequestStore.store[:rails_pulse_job_run_id]
          return unless request_id || job_run_id

          operation_data = {
            request_id: request_id,
            job_run_id: job_run_id,
            operation_type: operation_type,
            label: label,
            duration: [ (finish - start) * 1000, 0 ].max,
            codebase_location: codebase_location,
            start_time: start.to_f,
            occurred_at: Time.zone.at(start)
          }

          RequestStore.store[:rails_pulse_operations] ||= []
          RequestStore.store[:rails_pulse_operations] << operation_data
        end

        def subscribe_sql_queries!
          ActiveSupport::Notifications.subscribe "sql.active_record" do |name, start, finish, id, payload|
            begin
              next if payload[:name] == "SCHEMA"
              # Cached reads never hit the database, so there's nothing to time or
              # analyze for N+1s — skip before the stack walk in capture_operation.
              next if payload[:cached]
              next if query_ignored?(payload[:sql])
              capture_operation(name, start, finish, payload, "sql", :sql, extra: { row_count: payload[:row_count] })
            rescue => e
              RailsPulse.logger.error "Exception in SQL subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def query_ignored?(sql)
          return false if sql.nil?

          RailsPulse.configuration.ignored_queries.any? do |pattern|
            case pattern
            when String
              pattern == sql
            when Regexp
              pattern.match?(sql)
            else
              false
            end
          end
        end

        def subscribe_controller_actions!
          ActiveSupport::Notifications.subscribe "process_action.action_controller" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "controller", :controller)
            rescue => e
              RailsPulse.logger.error "Exception in controller subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_template_rendering!
          ActiveSupport::Notifications.subscribe "render_template.action_view" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "template", :template)
            rescue => e
              RailsPulse.logger.error "Exception in template subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_partial_rendering!
          ActiveSupport::Notifications.subscribe "render_partial.action_view" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "partial", :partial)
            rescue => e
              RailsPulse.logger.error "Exception in partial subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_layout_rendering!
          ActiveSupport::Notifications.subscribe "render_layout.action_view" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "layout", :template)
            rescue => e
              RailsPulse.logger.error "Exception in layout subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_cache_read!
          ActiveSupport::Notifications.subscribe "cache_read.active_support" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "cache_read", :cache, extra: { cache_hit: payload[:hit] })
            rescue => e
              RailsPulse.logger.error "Exception in cache_read subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_cache_write!
          ActiveSupport::Notifications.subscribe "cache_write.active_support" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "cache_write", :cache)
            rescue => e
              RailsPulse.logger.error "Exception in cache_write subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_http_requests!
          ActiveSupport::Notifications.subscribe "request.net_http" do |name, start, finish, id, payload|
            begin
              label = "#{payload[:method]} #{payload[:uri]}"
              codebase_location = find_app_frame || caller_locations(2, 1).first&.path
              store_operation(label: label, operation_type: "http", start: start, finish: finish, codebase_location: codebase_location)
            rescue => e
              RailsPulse.logger.error "Exception in HTTP subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_active_job!
          ActiveSupport::Notifications.subscribe "perform.active_job" do |name, start, finish, id, payload|
            begin
              label = payload[:job].class.name
              codebase_location = find_app_frame || caller_locations(2, 1).first&.path
              store_operation(label: label, operation_type: "job", start: start, finish: finish, codebase_location: codebase_location)
            rescue => e
              RailsPulse.logger.error "Exception in job subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_collection_rendering!
          ActiveSupport::Notifications.subscribe "render_collection.action_view" do |name, start, finish, id, payload|
            begin
              capture_operation(name, start, finish, payload, "collection", :template)
            rescue => e
              RailsPulse.logger.error "Exception in collection subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_mailer!
          ActiveSupport::Notifications.subscribe "deliver.action_mailer" do |name, start, finish, id, payload|
            begin
              label = "#{payload[:mailer]}##{payload[:action]}"
              codebase_location = find_app_frame || caller_locations(2, 1).first&.path
              store_operation(label: label, operation_type: "mailer", start: start, finish: finish, codebase_location: codebase_location)
            rescue => e
              RailsPulse.logger.error "Exception in mailer subscriber: #{e.class} - #{e.message}"
            end
          end
        end

        def subscribe_active_storage!
          ActiveSupport::Notifications.subscribe "service_upload.active_storage" do |name, start, finish, id, payload|
            begin
              label = "Upload: #{payload[:key]}"
              codebase_location = find_app_frame || caller_locations(2, 1).first&.path
              store_operation(label: label, operation_type: "storage", start: start, finish: finish, codebase_location: codebase_location)
            rescue => e
              RailsPulse.logger.error "Exception in storage subscriber: #{e.class} - #{e.message}"
            end
          end
        end
      end
    end
  end
end
