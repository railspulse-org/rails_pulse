module RailsPulse
  module Dashboard
    class StorageStatus
      TABLE_CATALOG = [
        {
          name: :rails_pulse_operations,
          model: "RailsPulse::Operation",
          label: "Operations",
          description: "SQL, view, cache, and other work captured inside requests and jobs",
          time_column: :occurred_at
        },
        {
          name: :rails_pulse_requests,
          model: "RailsPulse::Request",
          label: "Requests",
          description: "Individual HTTP requests",
          time_column: :occurred_at
        },
        {
          name: :rails_pulse_job_runs,
          model: "RailsPulse::JobRun",
          label: "Job runs",
          description: "Individual background job executions",
          time_column: :occurred_at
        },
        {
          name: :rails_pulse_exception_occurrences,
          model: "RailsPulse::ExceptionOccurrence",
          label: "Exception occurrences",
          description: "Stored exception instances (groups keep a lifetime count after cleanup)",
          time_column: :occurred_at
        },
        {
          name: :rails_pulse_summaries,
          model: "RailsPulse::Summary",
          label: "Summaries",
          description: "Hourly and daily aggregates used by charts. Hourly rows older than 2 days are cleaned up",
          time_column: :period_start
        },
        {
          name: :rails_pulse_queries,
          model: "RailsPulse::Query",
          label: "Queries",
          description: "Normalized SQL query fingerprints",
          time_column: :created_at
        },
        {
          name: :rails_pulse_routes,
          model: "RailsPulse::Route",
          label: "Routes",
          description: "Unique request paths",
          time_column: :created_at
        },
        {
          name: :rails_pulse_jobs,
          model: "RailsPulse::Job",
          label: "Jobs",
          description: "Unique background job class names",
          time_column: :created_at
        },
        {
          name: :rails_pulse_exception_groups,
          model: "RailsPulse::ExceptionGroup",
          label: "Exception groups",
          description: "Distinct exception sites. Preserved groups are never deleted",
          time_column: :last_seen_at
        },
        {
          name: :rails_pulse_deployments,
          model: "RailsPulse::Deployment",
          label: "Deployments",
          description: "Deploy markers shown on charts",
          time_column: :started_at
        }
      ].freeze

      def initialize
        @config = RailsPulse.configuration
        @pressure = StoragePressure.new
      end

      def tables
        @tables ||= TABLE_CATALOG.filter_map { |definition| build_table(definition) }
      end

      def pressure_items
        @pressure.pressure_items
      end

      def cleanup
        @cleanup ||= {
          enabled: @config.archiving_enabled,
          retention_period: @config.full_retention_period,
          retention_label: humanize_duration(@config.full_retention_period),
          last_summary_at: last_hourly_summary_end,
          health: cleanup_health,
          health_label: cleanup_health_label
        }
      end

      def database
        @database ||= {
          adapter: adapter_label,
          separate: RailsPulse.connects_to.present?,
          setup_label: RailsPulse.connects_to.present? ? "Separate database" : "Shared with host app",
          database_name: database_name,
          file_size: sqlite_file_size,
          table_bytes: tables_with_size? ? tables.sum { |table| table[:bytes].to_i } : nil,
          size_available: size_available?,
          size_note: size_note
        }
      end

      def dashboard_tables
        capped = tables.select { |table| table[:limit] }
        return tables.first(4) if capped.empty?

        capped.sort_by { |table| -table[:percent].to_f }.first(4)
      end

      def overview
        hottest = hottest_capped_table
        {
          hottest_label: hottest ? hottest[:label] : "—",
          hottest_percent: hottest ? hottest[:percent] : nil,
          total_records: tables.sum { |table| table[:count] },
          display_bytes: display_bytes,
          cleanup_health: cleanup[:health],
          cleanup_label: cleanup[:health_label]
        }
      end

      private

      def connection
        RailsPulse::ApplicationRecord.connection
      end

      def build_table(definition)
        model = definition[:model].safe_constantize
        return unless model
        return unless connection.table_exists?(definition[:name])

        stats = fetch_counts(model, definition)
        limit = @config.max_table_records&.[](definition[:name])
        count = stats[:count]
        percent = limit.to_i.positive? ? ((count.to_f / limit) * 100).round(1) : nil
        severity = fill_severity(percent, count, limit)

        {
          name: definition[:name],
          label: definition[:label],
          description: definition[:description],
          count: count,
          limit: limit,
          percent: percent,
          percent_label: percent_label(percent),
          bar_width: bar_width(percent),
          severity: severity,
          oldest_at: stats[:oldest_at],
          newest_at: stats[:newest_at],
          recent_count: stats[:recent_count],
          runway_label: runway_label(count, limit, stats[:recent_count]),
          bytes: table_bytes(definition[:name]),
          history_label: history_label(stats[:oldest_at], stats[:newest_at])
        }
      rescue => error
        RailsPulse.logger.warn("StorageStatus failed for #{definition[:name]}: #{error.message}")
        {
          name: definition[:name],
          label: definition[:label],
          description: definition[:description],
          count: 0,
          limit: @config.max_table_records&.[](definition[:name]),
          percent: nil,
          percent_label: nil,
          bar_width: 0,
          severity: :error,
          oldest_at: nil,
          newest_at: nil,
          recent_count: 0,
          runway_label: "Error loading",
          bytes: nil,
          history_label: error.message
        }
      end

      def fetch_counts(model, definition)
        quoted_table = connection.quote_table_name(definition[:name])
        time_column = definition[:time_column]

        unless time_column && model.column_names.include?(time_column.to_s)
          count = connection.select_value("SELECT COUNT(*) FROM #{quoted_table}").to_i
          return { count: count, oldest_at: nil, newest_at: nil, recent_count: 0 }
        end

        quoted_column = connection.quote_column_name(time_column)
        row = connection.select_one(
          model.sanitize_sql_array([ <<~SQL, 1.day.ago ])
            SELECT COUNT(*) AS record_count,
                   MIN(#{quoted_column}) AS oldest_at,
                   MAX(#{quoted_column}) AS newest_at,
                   SUM(CASE WHEN #{quoted_column} >= ? THEN 1 ELSE 0 END) AS recent_count
            FROM #{quoted_table}
          SQL
        ) || {}

        {
          count: row_value(row, "record_count").to_i,
          oldest_at: parse_time(row_value(row, "oldest_at")),
          newest_at: parse_time(row_value(row, "newest_at")),
          recent_count: row_value(row, "recent_count").to_i
        }
      end

      def fill_severity(percent, count, limit)
        return :uncapped if limit.nil?
        return :critical if count > limit || percent.to_f >= 90
        return :warning if percent.to_f >= 70

        :healthy
      end

      def percent_label(percent)
        return if percent.nil?
        return "< 0.1%" if percent < 0.1

        "#{percent}%"
      end

      def bar_width(percent)
        return 0 if percent.nil?

        [ [ percent, 0 ].max, 100 ].min
      end

      def runway_label(count, limit, recent_count)
        return "No cap" if limit.nil?
        return "Over cap" if count >= limit
        return "No recent growth" if recent_count.to_i.zero?

        days = (limit - count).to_f / recent_count
        if days < 1
          "< 1 day to cap"
        elsif days < 90
          "~#{days.round} #{'day'.pluralize(days.round)} to cap"
        else
          "Well under cap"
        end
      end

      def history_label(oldest_at, newest_at)
        return "No rows" unless oldest_at && newest_at

        span_days = ((newest_at - oldest_at) / 1.day).round
        span = if span_days < 1
          "< 1 day of history"
        else
          "#{span_days} #{'day'.pluralize(span_days)} of history"
        end

        "#{span} · oldest #{time_ago(oldest_at)}"
      end

      def time_ago(time)
        seconds = [ Time.current - time, 0 ].max
        if seconds < 60
          "just now"
        elsif seconds < 3_600
          "#{(seconds / 60).to_i}m ago"
        elsif seconds < 86_400
          "#{(seconds / 3_600).to_i}h ago"
        else
          days = (seconds / 86_400).to_i
          "#{days}d ago"
        end
      end

      def parse_time(value)
        return if value.blank?
        return value.in_time_zone if value.respond_to?(:in_time_zone) && !value.is_a?(String)

        (Time.zone || Time).parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def row_value(row, key)
        row[key] || row[key.to_s] || row[key.to_s.upcase] || row[key.to_sym]
      end

      def table_bytes(table_name)
        adapter = connection.adapter_name.downcase

        if adapter.include?("postgres")
          connection.select_value(
            "SELECT pg_total_relation_size(#{connection.quote(table_name.to_s)})"
          ).to_i
        elsif adapter.include?("mysql")
          connection.select_value(
            RailsPulse::ApplicationRecord.sanitize_sql_array([ <<~SQL, table_name.to_s ])
              SELECT DATA_LENGTH + INDEX_LENGTH
              FROM information_schema.TABLES
              WHERE TABLE_SCHEMA = DATABASE()
                AND TABLE_NAME = ?
            SQL
          )&.to_i
        elsif adapter.include?("sqlite")
          sqlite_table_bytes(table_name)
        end
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def sqlite_table_bytes(table_name)
        connection.select_value(
          RailsPulse::ApplicationRecord.sanitize_sql_array([
            "SELECT SUM(pgsize) FROM dbstat WHERE name = ?",
            table_name.to_s
          ])
        )&.to_i
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def sqlite_file_size
        return unless connection.adapter_name.downcase.include?("sqlite")
        return unless RailsPulse.connects_to.present?

        path = database_name
        return unless path.present? && File.exist?(path)

        File.size(path)
      rescue StandardError
        nil
      end

      def database_name
        config = RailsPulse::ApplicationRecord.connection_db_config
        config.respond_to?(:database) ? config.database : config.configuration_hash[:database]
      rescue StandardError
        nil
      end

      def adapter_label
        name = connection.adapter_name
        case name.downcase
        when /postgres/ then "PostgreSQL"
        when /mysql/ then "MySQL"
        when /sqlite/ then "SQLite"
        else name
        end
      end

      def tables_with_size?
        tables.any? { |table| table[:bytes].present? }
      end

      def size_available?
        tables_with_size? || sqlite_file_size.present?
      end

      def display_bytes
        return sqlite_file_size if sqlite_file_size
        return tables.sum { |table| table[:bytes].to_i } if tables_with_size?

        nil
      end

      def size_note
        adapter = connection.adapter_name.downcase
        if adapter.include?("sqlite") && RailsPulse.connects_to.blank?
          "SQLite is sharing the host database, so file size would include the rest of the app. Per-table size is shown when SQLite dbstat is available."
        elsif adapter.include?("sqlite") && RailsPulse.connects_to.present?
          "File size of the dedicated Rails Pulse SQLite database."
        elsif adapter.include?("postgres")
          "PostgreSQL relation size including indexes (pg_total_relation_size)."
        elsif adapter.include?("mysql")
          "MySQL data + index length from information_schema."
        end
      end

      def hottest_capped_table
        tables.select { |table| table[:percent] }.max_by { |table| table[:percent] }
      end

      def last_hourly_summary_end
        RailsPulse::Summary
          .where(summarizable_type: "RailsPulse::Request", summarizable_id: 0, period_type: "hour")
          .maximum(:period_end)
      end

      def cleanup_health
        items = pressure_items
        return :critical if items.any? { |item| item[:severity] == :critical }
        return :warning if items.any? { |item| item[:severity] == :warning }
        return :disabled unless @config.archiving_enabled

        :healthy
      end

      def cleanup_health_label
        case cleanup_health
        when :critical then "Cleanup blocked"
        when :warning then "Needs attention"
        when :disabled then "Cleanup off"
        else "Healthy"
        end
      end

      def humanize_duration(duration)
        return "Not set" unless duration

        total_seconds = duration.to_i
        if total_seconds >= 86_400
          days = total_seconds / 86_400
          "#{days} #{'day'.pluralize(days)}"
        elsif total_seconds >= 3_600
          hours = total_seconds / 3_600
          "#{hours} #{'hour'.pluralize(hours)}"
        else
          minutes = total_seconds / 60
          "#{minutes} #{'minute'.pluralize(minutes)}"
        end
      end
    end
  end
end
