module RailsPulse
  module Installers
    # Inserts settings from the install template that the host initializer does
    # not already mention. Existing lines are never rewritten, so `git diff` is
    # the review: keep or discard hunks. Values that differ between a new
    # install and an upgrade (today: track_exceptions) use the gem default.
    class ConfigUpdater
      ASSIGNMENT = /\A\s*(#\s*)?config\.(\w+)\s*=/.freeze
      HASH_ENTRY = /\A\s*([a-z_][a-z0-9_]*):/.freeze

      UPGRADE_VALUE_OVERRIDES = {
        "track_exceptions" => "false"
      }.freeze

      BANNER = <<~RUBY.gsub(/^/, "  ")
        # ====================================================================================================
        #                              ADDED BY rails generate rails_pulse:upgrade
        # ====================================================================================================
        # New settings from this gem version. Existing values above were not changed.
        # Review with git diff and keep or discard hunks as you like.

      RUBY

      attr_reader :output, :source, :destination

      def self.update(destination:, source: nil, output: $stdout)
        new(destination: destination, source: source, output: output).update
      end

      # What `update` would add, without writing anything.
      def self.missing(destination:, source: nil)
        new(destination: destination, source: source).missing
      end

      def self.template_path
        File.expand_path("../../../../lib/generators/rails_pulse/templates/rails_pulse.rb", __FILE__)
      end

      def initialize(destination:, source: nil, output: $stdout)
        @destination = destination
        @source = source || self.class.template_path
        @output = output
      end

      # { keys: [setting keys absent from the host file], hash_keys: [names of
      # entries absent from a hash the host does set] }. Empty arrays when the
      # host mentions everything; both empty when the file does not exist.
      def missing
        return { keys: [], hash_keys: [] } unless File.exist?(destination)

        host = File.read(destination)
        missing_keys = template_settings.map { |setting| setting[:key] } - mentioned_keys(host)
        hash_keys = missing_hash_entries(host, missing_keys)
        { keys: missing_keys, hash_keys: hash_keys.map { |entry| entry[:name] } }
      end

      def update
        return { status: :missing, keys: [], hash_keys: [] } unless File.exist?(destination)

        host = File.read(destination)
        missing_keys = template_settings.map { |setting| setting[:key] } - mentioned_keys(host)
        hash_keys = missing_hash_entries(host, missing_keys)

        return { status: :unchanged, keys: [], hash_keys: [] } if missing_keys.empty? && hash_keys.empty?

        updated = host
        updated = inject_hash_entries(updated, hash_keys) if hash_keys.any?
        updated = append_settings(updated, missing_keys) if missing_keys.any?
        File.write(destination, updated)

        { status: :updated, keys: missing_keys, hash_keys: hash_keys.map { |entry| entry[:name] } }
      end

      private

      def template_settings
        @template_settings ||= parse_settings(File.read(source))
      end

      def parse_settings(content)
        settings = []
        comments = []
        lines = content.lines
        index = 0

        while index < lines.size
          line = lines[index]

          if line.match?(ASSIGNMENT)
            key = line[ASSIGNMENT, 2]
            assignment, index = read_multiline(lines, index)
            unless settings.any? { |setting| setting[:key] == key }
              settings << { key: key, lines: comments + assignment }
            end
            comments = []
          elsif preamble?(line)
            comments = []
            index += 1
          else
            comments << line
            index += 1
          end
        end

        settings
      end

      def preamble?(line)
        line.match?(/\A\s*(RailsPulse\.configure|end)\b/) || line.match?(/\A\s*do\s*\|config\|/)
      end

      def read_multiline(lines, index)
        collected = [ lines[index] ]
        depth = nest_delta(lines[index])
        index += 1

        while index < lines.size && depth.positive?
          collected << lines[index]
          depth += nest_delta(lines[index])
          index += 1
        end

        [ collected, index ]
      end

      def nest_delta(line)
        code = line.sub(/#.*\z/, "")
        code.count("{") - code.count("}") + code.count("[") - code.count("]")
      end

      def mentioned_keys(content)
        content.scan(/config\.(\w+)/).flatten.uniq
      end

      def missing_hash_entries(host, missing_keys)
        template_settings.filter_map do |setting|
          next if missing_keys.include?(setting[:key])
          next unless host.match?(/^\s*config\.#{Regexp.escape(setting[:key])}\s*=\s*\{/)

          setting[:lines].filter_map do |line|
            name = line[HASH_ENTRY, 1]
            next unless name
            next if host.match?(/^\s*#{Regexp.escape(name)}:/)

            { setting: setting[:key], name: name, line: line }
          end
        end.flatten
      end

      def inject_hash_entries(content, entries)
        entries.group_by { |entry| entry[:setting] }.reduce(content) do |text, (setting, grouped)|
          pattern = /(^\s*config\.#{Regexp.escape(setting)}\s*=\s*\{)(.*?)(\n\s*\})/m
          text.sub(pattern) do
            opening, body, closing = Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3]
            "#{opening}#{body_with_comma(body)}\n#{grouped.map { |entry| entry[:line].rstrip }.join("\n")}#{closing}"
          end
        end
      end

      def body_with_comma(body)
        lines = body.lines
        index = lines.rindex { |line| line.strip != "" }
        return body unless index

        working = lines[index].chomp
        return body if working.match?(/,\s*(#.*)?\z/)

        working = if working.include?("#")
          working.sub(/\s+#/, ", #")
        else
          "#{working},"
        end
        lines[index] = "#{working}\n"
        lines.join
      end

      def append_settings(content, keys)
        blocks = keys.filter_map do |key|
          setting = template_settings.find { |candidate| candidate[:key] == key }
          next unless setting

          apply_overrides(setting[:lines], key).join
        end
        return content if blocks.empty?

        insertion = BANNER + blocks.join("\n").gsub(/\n+\z/, "\n")
        insert_before_configure_end(content, insertion)
      end

      def insert_before_configure_end(content, insertion)
        lines = content.lines
        start_index = lines.index { |line| line.match?(/^\s*RailsPulse\.configure\b/) }

        unless start_index
          return content + "\nRailsPulse.configure do |config|\n#{insertion}end\n"
        end

        indent = lines[start_index][/\A\s*/]
        end_index = ((start_index + 1)...lines.size).find do |index|
          lines[index].match?(/\A#{Regexp.escape(indent)}end\b/)
        end

        unless end_index
          return content.sub(/\nend\s*\z/, "\n\n#{insertion}end\n")
        end

        (lines[0...end_index] + [ "\n#{insertion}" ] + lines[end_index..]).join
      end

      def apply_overrides(lines, key)
        return lines unless UPGRADE_VALUE_OVERRIDES.key?(key)

        lines.map do |line|
          line.sub(/config\.#{Regexp.escape(key)}\s*=\s*.*/, "config.#{key} = #{UPGRADE_VALUE_OVERRIDES[key]}")
        end
      end
    end
  end
end
