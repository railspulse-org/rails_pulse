require "test_helper"

class RailsPulse::ChartHelperTest < ActionView::TestCase
  include RailsPulse::ChartHelper

  # ============================================================================
  # Chart Options Tests - Base Configuration
  # ============================================================================

  test "base_chart_options sets defaults with units and zoom" do
    opts = base_chart_options(units: "ms", zoom: true)

    assert_equal "{value} ms", opts[:yAxis][:axisLabel][:formatter]
    assert_equal "60", opts[:grid][:bottom]
    assert opts[:animation]
  end

  # ============================================================================
  # Chart Options Tests - Specific Chart Types
  # ============================================================================

  test "bar_chart_options deep merges series" do
    opts = bar_chart_options(units: "ms", zoom: false)

    assert_equal [ 5, 5, 5, 5 ], opts[:series][:itemStyle][:borderRadius]
  end

  test "line_chart_options deep merges series" do
    opts = line_chart_options(units: "ms", zoom: false)

    refute opts[:series][:smooth]  # Lines are not smoothed by default
    assert_equal 3, opts[:series][:lineStyle][:width]
    assert_equal "circle", opts[:series][:symbol]
  end

  test "sparkline_chart_options hides axes and grid" do
    opts = sparkline_chart_options

    assert_equal "bar", opts[:series][:type]
    refute opts[:yAxis][:show]
  end

  test "area_chart_options sets symbol and line style" do
    opts = area_chart_options

    assert_equal "roundRect", opts[:series][:symbol]
    assert_equal 8, opts[:series][:symbolSize]
  end

  # ============================================================================
  # Zoom Configuration Tests
  # ============================================================================

  test "bar_chart_options applies zoom configuration with chart_data" do
    chart_data = {
      100 => { value: 1 },
      200 => { value: 2 },
      300 => { value: 3 }
    }

    opts = bar_chart_options(units: "ms", zoom: true,
                             zoom_start: 110, zoom_end: 290,
                             chart_data: chart_data)

    assert_kind_of Array, opts[:dataZoom]
    slider = opts[:dataZoom].first

    assert_equal 0, slider[:startValue]
    assert_equal 2, slider[:endValue]
  end

  test "line_chart_options sets dataZoom when zoom true and chart_data empty" do
    opts = line_chart_options(zoom: true, chart_data: {})

    assert_equal "slider", opts[:dataZoom].first[:type]
  end

  # ============================================================================
  # render_stimulus_chart Tests - Basic Rendering
  # ============================================================================

  test "render_stimulus_chart generates Stimulus-compatible div" do
    data = { 100 => 1, 200 => 2, 300 => 3 }
    html = render_stimulus_chart(data, type: "bar", height: "300px")

    assert_match(/data-controller="rails-pulse--chart"/, html)
    assert_match(/data-rails-pulse--chart-type-value="bar"/, html)
    assert_match(/data-rails-pulse--chart-data-value/, html)
    assert_match(/style="height: 300px/, html)
  end

  test "render_stimulus_chart serializes data correctly" do
    data = { 100 => 1, 200 => 2 }
    html = render_stimulus_chart(data, type: "bar")

    # Extract data attribute value
    doc = Nokogiri::HTML(html)
    data_attr = doc.at_css("[data-rails-pulse--chart-data-value]")
    parsed_data = JSON.parse(data_attr["data-rails-pulse--chart-data-value"])

    assert_equal({ "100" => 1, "200" => 2 }, parsed_data)
  end

  test "render_stimulus_chart supports different chart types" do
    data = { 100 => 1, 200 => 2 }

    bar_html = render_stimulus_chart(data, type: "bar")
    line_html = render_stimulus_chart(data, type: "line")

    assert_match(/data-rails-pulse--chart-type-value="bar"/, bar_html)
    assert_match(/data-rails-pulse--chart-type-value="line"/, line_html)
  end

  test "render_stimulus_chart includes options as JSON" do
    data = { 100 => 1, 200 => 2 }
    options = bar_chart_options(units: "ms")
    html = render_stimulus_chart(data, type: "bar", options: options)

    assert_match(/data-rails-pulse--chart-options-value/, html)

    # Extract and parse options
    doc = Nokogiri::HTML(html)
    options_attr = doc.at_css("[data-rails-pulse--chart-options-value]")
    parsed_options = JSON.parse(options_attr["data-rails-pulse--chart-options-value"])

    assert parsed_options["series"]
    assert parsed_options["tooltip"]
  end

  # ============================================================================
  # render_stimulus_chart Tests - Configuration Options
  # ============================================================================

  test "render_stimulus_chart generates unique IDs" do
    data = { 100 => 1 }
    html1 = render_stimulus_chart(data, type: "bar")
    html2 = render_stimulus_chart(data, type: "bar")

    # Extract IDs
    id1 = html1.match(/id="([^"]+)"/)[1]
    id2 = html2.match(/id="([^"]+)"/)[1]

    refute_equal id1, id2, "Chart IDs should be unique"
  end

  test "render_stimulus_chart accepts custom ID" do
    data = { 100 => 1 }
    html = render_stimulus_chart(data, type: "bar", id: "custom-chart-id")

    assert_match(/id="custom-chart-id"/, html)
  end

  test "render_stimulus_chart sets theme value" do
    data = { 100 => 1 }
    html = render_stimulus_chart(data, type: "bar", theme: "dark")

    assert_match(/data-rails-pulse--chart-theme-value="dark"/, html)
  end

  test "render_stimulus_chart uses default theme when not specified" do
    data = { 100 => 1 }
    html = render_stimulus_chart(data, type: "bar")

    assert_match(/data-rails-pulse--chart-theme-value="railspulse"/, html)
  end

  # ============================================================================
  # base_chart_options - x_formatter Tests
  # ============================================================================

  test "base_chart_options uses timestamp_to_date formatter by default" do
    opts = base_chart_options

    assert_equal "timestamp_to_date", opts[:xAxis][:axisLabel][:formatter]
  end

  test "base_chart_options uses time formatter when @time_range period_type is hour" do
    @time_range = RailsPulse::TimeRange::Result.new(period_type: "hour")
    opts = base_chart_options

    assert_equal "time", opts[:xAxis][:axisLabel][:formatter]
  end

  test "base_chart_options uses timestamp_to_date when @time_range period_type is day" do
    @time_range = RailsPulse::TimeRange::Result.new(period_type: "day")
    opts = base_chart_options

    assert_equal "timestamp_to_date", opts[:xAxis][:axisLabel][:formatter]
  end

  # ============================================================================
  # render_stimulus_chart - deployment marker injection Tests
  # ============================================================================

  test "render_stimulus_chart injects deployment_markers when @deployment_markers is set" do
    @deployment_markers = [ { timestamp: 1_700_000_000_000, revision: "abc123", started_at: "2024-01-01T00:00:00Z" } ]
    data = { series: [ { name: "Requests", data: [ [ 1_700_000_000_000, 10 ] ] } ] }

    html = render_stimulus_chart(data, type: "line")
    doc = Nokogiri::HTML(html)
    parsed = JSON.parse(doc.at_css("[data-rails-pulse--chart-data-value]")["data-rails-pulse--chart-data-value"])

    assert parsed.key?("deployment_markers")
    assert_equal 1, parsed["deployment_markers"].length
    assert_equal "abc123", parsed["deployment_markers"].first["revision"]
  end

  test "render_stimulus_chart does not inject deployment_markers when @deployment_markers is nil" do
    @deployment_markers = nil
    data = { series: [ { name: "Requests", data: [ [ 1_700_000_000_000, 10 ] ] } ] }

    html = render_stimulus_chart(data, type: "line")
    doc = Nokogiri::HTML(html)
    parsed = JSON.parse(doc.at_css("[data-rails-pulse--chart-data-value]")["data-rails-pulse--chart-data-value"])

    refute parsed.key?("deployment_markers")
  end

  test "render_stimulus_chart does not inject deployment_markers when @deployment_markers is empty" do
    @deployment_markers = []
    data = { series: [ { name: "Requests", data: [ [ 1_700_000_000_000, 10 ] ] } ] }

    html = render_stimulus_chart(data, type: "line")
    doc = Nokogiri::HTML(html)
    parsed = JSON.parse(doc.at_css("[data-rails-pulse--chart-data-value]")["data-rails-pulse--chart-data-value"])

    refute parsed.key?("deployment_markers")
  end

  test "render_stimulus_chart does not inject deployment_markers for non-series data" do
    @deployment_markers = [ { timestamp: 1_700_000_000_000, revision: "abc123", started_at: "2024-01-01T00:00:00Z" } ]
    data = { 100 => 1, 200 => 2 }

    html = render_stimulus_chart(data, type: "bar")
    doc = Nokogiri::HTML(html)
    parsed = JSON.parse(doc.at_css("[data-rails-pulse--chart-data-value]")["data-rails-pulse--chart-data-value"])

    refute parsed.key?("deployment_markers")
  end

  test "render_stimulus_chart does not inject deployment_markers for string-label charts" do
    @deployment_markers = [ { timestamp: 1_700_000_000_000, revision: "abc123", started_at: "2024-01-01T00:00:00Z" } ]
    data = { labels: [ "Apr 28", "Apr 29" ], series: [ { name: "P50", data: [ 100, 110 ] } ] }

    html = render_stimulus_chart(data, type: "line")
    doc = Nokogiri::HTML(html)
    parsed = JSON.parse(doc.at_css("[data-rails-pulse--chart-data-value]")["data-rails-pulse--chart-data-value"])

    refute parsed.key?("deployment_markers")
  end

  # ============================================================================
  # Zoom - time-axis format Tests
  # ============================================================================

  test "bar_chart_options sets ms timestamps for time-axis data (Array pairs)" do
    chart_data = {
      series: [ {
        name: "Requests",
        data: [ [ 1_700_000_000, 10 ], [ 1_700_086_400, 20 ], [ 1_700_172_800, 30 ] ]
      } ]
    }

    opts = bar_chart_options(zoom: true, zoom_start: 1_700_000_000, zoom_end: 1_700_172_800,
                             chart_data: chart_data)
    slider = opts[:dataZoom].first

    assert_equal 1_700_000_000 * 1000, slider[:startValue]
    assert_equal 1_700_172_800 * 1000, slider[:endValue]
  end

  test "bar_chart_options sets ms timestamps for time-axis data (Hash with value array)" do
    chart_data = {
      series: [ {
        name: "DB Load",
        data: [ { value: [ 1_700_000_000_000, 15.5 ], itemStyle: { color: "green" } } ]
      } ]
    }

    opts = bar_chart_options(zoom: true, zoom_start: 1_700_000, zoom_end: 1_700_100,
                             chart_data: chart_data)
    slider = opts[:dataZoom].first

    assert_equal 1_700_000 * 1000, slider[:startValue]
    assert_equal 1_700_100 * 1000, slider[:endValue]
  end

  test "bar_chart_options with new format chart_data using labels array" do
    chart_data = {
      labels: [ 100, 200, 300 ],
      series: [ { name: "Requests", data: [ 1, 2, 3 ] } ]
    }

    opts = bar_chart_options(zoom: true, zoom_start: 150, zoom_end: 250, chart_data: chart_data)

    assert_kind_of Array, opts[:dataZoom]
    assert_equal "slider", opts[:dataZoom].first[:type]
  end

  test "bar_chart_options handles empty chart_data gracefully" do
    opts = bar_chart_options(zoom: true, zoom_start: 100, zoom_end: 200, chart_data: {})

    assert_kind_of Array, opts[:dataZoom]
  end
end
