require "test_helper"
require "rails_pulse/cli/formatter"

module RailsPulse
  module CLI
    class FormatterTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      COLUMNS = [
        [ "Method",  8, :method ],
        [ "Path",    20, :path ],
        [ "Created", 15, :created_at ]
      ].freeze

      def response_with(rows)
        { "data" => rows, "meta" => { "total" => rows.size, "limit" => 25, "offset" => 0 } }
      end

      # --- json mode ---

      test "render with json: true outputs pretty-printed JSON" do
        data = response_with([ { "method" => "GET", "path" => "/", "created_at" => "2026-01-01" } ])

        out, _err = capture_io { Formatter.render(data, json: true, columns: COLUMNS) }
        parsed = JSON.parse(out)

        assert parsed.key?("data")
        assert parsed.key?("meta")
      end

      # --- table mode ---

      test "render with no rows outputs (no results)" do
        out, _err = capture_io { Formatter.render(response_with([]), json: false, columns: COLUMNS) }

        assert_includes out, "(no results)"
      end

      test "render outputs column headers uppercased" do
        data = response_with([ { "method" => "GET", "path" => "/", "created_at" => "2026-01-01" } ])

        out, _err = capture_io { Formatter.render(data, json: false, columns: COLUMNS) }

        assert_includes out, "METHOD"
        assert_includes out, "PATH"
        assert_includes out, "CREATED"
      end

      test "render outputs a separator line under the header" do
        data = response_with([ { "method" => "GET", "path" => "/", "created_at" => "2026-01-01" } ])

        out, _err = capture_io { Formatter.render(data, json: false, columns: COLUMNS) }
        lines = out.split("\n")

        assert lines.any? { |l| l.start_with?("---") }, "Expected a separator line starting with '---'"
      end

      test "render outputs row values" do
        data = response_with([ { "method" => "GET", "path" => "/orders", "created_at" => "2026-01-01" } ])

        out, _err = capture_io { Formatter.render(data, json: false, columns: COLUMNS) }

        assert_includes out, "GET"
        assert_includes out, "/orders"
      end

      test "render truncates long values with ellipsis" do
        long_path = "/this/is/a/very/long/path/that/exceeds/column/width"
        data = response_with([ { "method" => "GET", "path" => long_path, "created_at" => "2026-01-01" } ])

        out, _err = capture_io { Formatter.render(data, json: false, columns: COLUMNS) }

        assert_includes out, "…", "Expected long value to be truncated with '…'"
      end

      test "render outputs all rows" do
        rows = [
          { "method" => "GET",  "path" => "/",       "created_at" => "2026-01-01" },
          { "method" => "POST", "path" => "/orders",  "created_at" => "2026-01-02" }
        ]

        out, _err = capture_io { Formatter.render(response_with(rows), json: false, columns: COLUMNS) }

        assert_includes out, "GET"
        assert_includes out, "POST"
        assert_includes out, "/orders"
      end
    end
  end
end
