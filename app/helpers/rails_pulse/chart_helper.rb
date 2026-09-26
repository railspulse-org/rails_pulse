module RailsPulse
  module ChartHelper
    # Main chart rendering method - unified API for all chart types
    # Uses Stimulus controller to handle chart initialization
    def render_stimulus_chart(data, type:, **options)
      # Auto-inject deployment markers into time-axis charts only.
      # Time-axis charts store timestamps inside series data as [timestamp_ms, value] pairs
      # and have no separate :labels key. Category/string-label charts (e.g. dashboard) are excluded.
      if data.is_a?(Hash) && data[:labels].nil? && data[:series].present? && @deployment_markers&.any?
        data = data.merge(deployment_markers: @deployment_markers)
      end

      chart_id = options[:id] || "rails-pulse-chart-#{SecureRandom.hex(8)}"
      height = options[:height] || "400px"
      width = options[:width] || "100%"
      theme = options[:theme] || "railspulse"
      chart_options = options[:options] || {}

      # Build data attributes for Stimulus
      stimulus_data = {
        controller: "rails-pulse--chart",
        rails_pulse__chart_type_value: type,
        rails_pulse__chart_data_value: data.to_json,
        rails_pulse__chart_options_value: chart_options.to_json,
        rails_pulse__chart_theme_value: theme,
        # Lets the chart format daily labels/tooltips in the zone summaries
        # were actually bucketed in, instead of the browser's zone (which can
        # land a daily boundary on the wrong calendar day — see #303). The
        # short label keeps sparkline tooltips readable; the full zone name
        # is in the badge's title next to each chart.
        rails_pulse__chart_timezone_value: RailsPulse::TimeRange.aggregation_zone_iana,
        rails_pulse__chart_timezone_label_value: RailsPulse::TimeRange.aggregation_zone_short_label
      }

      content_tag(:div, "",
        id: chart_id,
        style: "height: #{height}; width: #{width};",
        data: stimulus_data
      )
    end

    # Base chart options shared across all chart types
    def base_chart_options(units: nil, zoom: false)
      hourly = @time_range&.period_type == "hour"
      x_formatter = hourly ? "time" : "timestamp_to_date"
      tooltip_formatter = units == "%" ? "tooltip_with_timestamp_rate" : "tooltip_with_timestamp"
      {
        tooltip: {
          trigger: "axis",
          axisPointer: { type: "shadow" },
          formatter: tooltip_formatter
        },
        xAxis: {
          axisLine: { show: false },
          axisTick: { show: false },
          axisLabel: {
            formatter: x_formatter
          }
        },
        yAxis: {
          splitArea: { show: false },
          axisLabel: {
            formatter: "{value} #{units}"
          }
        },
        grid: {
          left: "0",
          right: "2%",
          bottom: (zoom ? "60" : "0"),
          top: "10%",
          containLabel: true
        },
        animation: true
      }
    end

    def bar_chart_options(units: nil, zoom: false, chart_start: 0, chart_end: 100, zoom_start: nil, zoom_end: nil, chart_data: nil)
      options = base_chart_options(units: units, zoom: zoom).deep_merge({
        series: {
          itemStyle: { borderRadius: [ 5, 5, 5, 5 ] }
        }
      })

      apply_zoom_configuration(options, zoom, zoom_start, zoom_end, chart_data)

      options
    end

    def line_chart_options(units: nil, zoom: false, chart_start: 0, chart_end: 100, zoom_start: nil, zoom_end: nil, chart_data: nil)
      options = base_chart_options(units: units, zoom: zoom).deep_merge({
        series: {
          smooth: false,
          lineStyle: { width: 3 },
          symbol: "circle",
          symbolSize: 8
        }
      })

      apply_zoom_configuration(options, zoom, zoom_start, zoom_end, chart_data)

      options
    end

    def sparkline_chart_options
      # Compact sparkline columns that fill the canvas with no axes/labels/gaps
      base_chart_options.deep_merge({
        tooltip: {
          trigger: "axis",
          axisPointer: { type: "shadow" },
          formatter: "sparkline_tooltip"
        },
        series: {
          type: "bar",
          itemStyle: { borderRadius: [ 2, 2, 0, 0 ] },
          barCategoryGap: "10%",
          barGap: "0%"
        },
        yAxis: { show: false, splitLine: { show: false } },
        xAxis: {
          type: "category",
          boundaryGap: true,
          axisLine: { show: false },
          axisTick: { show: false },
          splitLine: { show: false },
          axisLabel: { show: false }
        },
        grid: { left: 0, right: 0, top: 0, bottom: 0, containLabel: false, show: false }
      })
    end

    def area_chart_options
      base_chart_options.deep_merge({
        series: {
          smooth: true,
          lineStyle: { width: 3 },
          symbol: "roundRect",
          symbolSize: 8
        }
      })
    end

    private

    def apply_zoom_configuration(options, zoom, zoom_start, zoom_end, chart_data)
      return unless zoom

      zoom_config = {
        type: "slider",
        height: 20,
        bottom: 10,
        showDetail: false
      }

      if zoom_start.present? && zoom_end.present? && chart_data.present?
        zoom_start_int = zoom_start.respond_to?(:to_i) ? zoom_start.to_i : zoom_start
        zoom_end_int = zoom_end.respond_to?(:to_i) ? zoom_end.to_i : zoom_end

        # Detect format: time-axis format has [timestamp_ms, value] pairs directly or under :value
        first_point = chart_data.dig(:series, 0, :data, 0)
        is_time_axis = first_point.is_a?(Array) || first_point.is_a?(Hash) && first_point[:value].is_a?(Array)

        if is_time_axis
          # Time axis: startValue/endValue are timestamps in milliseconds
          zoom_config[:startValue] = zoom_start_int * 1000
          zoom_config[:endValue] = zoom_end_int * 1000
        else
          # Category axis: convert zoom timestamps to array indices
          chart_timestamps = if chart_data.is_a?(Hash) && chart_data[:labels].present?
            chart_data[:labels]
          elsif chart_data.is_a?(Hash)
            chart_data.keys.select { |k| k.is_a?(Numeric) }
          else
            []
          end

          if chart_timestamps.any?
            closest_start = chart_timestamps.min_by { |ts| (ts.to_i - zoom_start_int.to_i).abs }
            closest_end = chart_timestamps.min_by { |ts| (ts.to_i - zoom_end_int.to_i).abs }
            start_index = chart_timestamps.index(closest_start)
            end_index = chart_timestamps.index(closest_end)
            zoom_config[:startValue] = start_index
            zoom_config[:endValue] = end_index
          end
        end
      end

      options[:dataZoom] = [
        zoom_config,
        { type: "inside" }
      ]
    end
  end
end
