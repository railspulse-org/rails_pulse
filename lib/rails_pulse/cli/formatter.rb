require "json"

module RailsPulse
  module CLI
    class Formatter
      def self.render(response, json: false, columns: [])
        if json
          puts JSON.pretty_generate(response)
        else
          render_table(response["data"], columns)
        end
      end

      def self.render_table(rows, columns)
        return puts "(no results)" if rows.empty?

        header = columns.map { |header, width, _key| header.upcase.ljust(width) }.join("  ")
        puts header
        puts "-" * header.length

        rows.each do |row|
          line = columns.map do |_header, width, key|
            val = row[key.to_s].to_s
            val.length > width ? "#{val[0, width - 1]}…" : val.ljust(width)
          end.join("  ")
          puts line
        end
      end
    end
  end
end
