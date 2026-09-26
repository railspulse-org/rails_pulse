# Charts

One Stimulus controller, `rails-pulse--chart` (`app/javascript/rails_pulse/controllers/chart_controller.js`), renders every chart with a tree-shaken Apache ECharts. Views emit no inline script; data and options travel in `data-` attributes. Read before adding a chart type, a formatter, or an ECharts feature.

## Registered ECharts modules

`app/javascript/rails_pulse/application.js` imports from `echarts/core` and registers only:

| Kind | Registered |
|---|---|
| Series | `BarChart`, `LineChart` |
| Components | `GridComponent`, `TooltipComponent` (installs AxisPointer), `LegendComponent`, `DataZoomComponent`, `MarkLineComponent`, `MarkAreaComponent` |
| Renderer | `CanvasRenderer` |

Anything else (`type: 'pie'`, `toolbox`, `visualMap`) is silently dropped by ECharts and the chart renders blank or without the feature. To add one: import it, add it to `echarts.use([...])`, run `npm run build`, commit the bundle.

## Rendering

`render_stimulus_chart(data, type:, height:, width:, options:, id:, theme:)` in `app/helpers/rails_pulse/chart_helper.rb`. `type` is `bar`, `line` or `area`; `area` becomes a `line` series with `areaStyle`. A sparkline is `bar` with `sparkline_chart_options`. Option builders: `bar_chart_options`, `line_chart_options` (both take `units:`, `zoom:`, `zoom_start:`, `zoom_end:`, `chart_data:`), `sparkline_chart_options`, `area_chart_options`.

Data is a hash keyed by timestamp or label, values either numbers or `{ value:, name: }`. Time-axis charts pass `series:` of `[timestamp_ms, value]` pairs and no `labels:`; when a controller sets `@deployment_markers` the helper merges them into those charts only.

## Formatters

Formatter options are string keys looked up in `SAFE_FORMATTERS` inside `getSafeFormatter`. There is no `eval` or `new Function`, which is what lets the dashboard run under `script-src 'self'`. Unknown keys log a console warning and fall back to identity.

| Kind | Keys |
|---|---|
| Axis value | `duration_ms`, `percentage`, `number_delimited`, `timestamp`, `date`, `time`, `bytes`, `timestamp_to_date` |
| Tooltip | `tooltip_time_ms`, `tooltip_date_ms`, `tooltip_time`, `tooltip_date`, `auto_date_tooltip`, `tooltip_with_timestamp`, `tooltip_with_timestamp_rate`, `sparkline_tooltip`, `sparkline_percentage_tooltip` |

Add a formatter by adding a key to that object. Never add string-to-function conversion. The `__FUNCTION_START__` / `__FUNCTION_END__` markers are stripped for backwards compatibility and mean nothing.

## Controller contract

- Values: `type`, `data`, `options`, `theme` (default `railspulse`), `timezone` (IANA name of `Time.zone`), `timezoneLabel` (its short label). Every date and time formatter renders in `timezone`, never the browser's zone, and tooltip formatters append `timezoneLabel` in parentheses. `isHourlyAxis()` decides hourly versus daily from `xAxis.axisLabel.formatter === "time"`, the key `chart_helper.rb` sets, not from ECharts' generated `axisValueLabel`.
- `chartInstance` getter returns the ECharts instance; `update(event)` re-renders from `event.detail.data` / `.options`.
- `connect` waits up to five seconds (100 × 50 ms) for `echarts`, inits, attaches a `ResizeObserver`, dispatches `stimulus:echarts:rendered` on `document` with `{ containerId, chart, controller }`. `index` and `chart_switcher` listen for it to attach click and zoom handlers.
- `disconnect` disposes the chart and the observer and removes the `rails-pulse:color-scheme-changed` listener. Axis labels are `#999999` light, `rgba(255,255,255,0.55)` dark.
- Do not hold chart instances anywhere else. Stimulus owns the lifecycle across Turbo Drive, Frames and Streams.

## CSP

`test/system/csp_compliance_test.rb` loads the dashboard under `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'`. Keep it green. `public/rails-pulse-assets/csp-test.js` is the page it uses and is not shipped in the gem.

## Tests

`test/helpers/rails_pulse/chart_helper_test.rb` for the helper. `test/javascript/controllers/chart_controller.test.js` for formatter lookup and config building. Rendering is verified in system tests with `test/support/chart_validation_helpers.rb` (`assert_chart_rendered`, `assert_no_inline_scripts`, `validate_chart_data`). Chart colours are constants in `app/models/rails_pulse/chart_colors.rb`.
