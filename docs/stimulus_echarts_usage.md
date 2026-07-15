# Stimulus Charts (ECharts)

How Rails Pulse renders charts for maintainers working on the gem.

Charts use `RailsPulse::ChartHelper#render_stimulus_chart` in views and the `rails-pulse--chart` Stimulus controller (`app/javascript/rails_pulse/controllers/chart_controller.js`) with Apache ECharts. Formatter strings never pass through `eval()`. The controller resolves them through a whitelist in `getSafeFormatter`.

## Rendering a chart

```erb
<%= render_stimulus_chart(
  @chart_data,
  type: "bar",
  height: "400px",
  options: bar_chart_options(units: "ms")
) %>
```

`render_stimulus_chart` accepts:

| Argument | Meaning |
|----------|---------|
| `data` | Chart payload (Hash; see shapes below) |
| `type:` | ECharts series type string (`"bar"`, `"line"`, `"area"`, …) |
| `height:` | CSS height (default `"400px"`) |
| `width:` | CSS width (default `"100%"`) |
| `theme:` | Theme name (default `"railspulse"`) |
| `options:` | Extra ECharts option hash (often from helper builders) |
| `id:` | Optional DOM id |

It emits a `<div>` with Stimulus values for type, data JSON, options JSON, and theme.

If `@deployment_markers` is set and the payload is a **time-axis** chart (`:series` present, no `:labels`), markers are merged into the payload automatically.

## Chart data shapes

Verified by helper tests and controller data detection:

**Time axis** — points are `[timestamp_ms, value]` (optionally wrapped in `{ value: [...] }`). No `:labels` key.

```ruby
{
  series: [
    { name: "P95", data: [ [ 1_700_000_000_000, 120 ], [ 1_700_000_360_000, 95 ] ] }
  ]
}
```

**Category axis** — parallel `:labels` and numeric series data:

```ruby
{
  labels: [ "Apr 28", "Apr 29" ],
  series: [ { name: "P50", data: [ 100, 110 ] } ]
}
```

The controller sets `xAxis.type` to `"time"` or `"category"` from the first data point.

## Option builders

Defined in `app/helpers/rails_pulse/chart_helper.rb`:

- `bar_chart_options(units:, zoom:, …)`
- `line_chart_options(units:, zoom:, …)`
- `area_chart_options`
- `sparkline_chart_options`

`base_chart_options` picks formatter **keys** (not JS source):

- X label: `"time"` when `@period_type == "hour"` or `@time_diff_hours <= 25`, otherwise `"timestamp_to_date"`
- Tooltip: `"tooltip_with_timestamp_rate"` when `units == "%"`, otherwise `"tooltip_with_timestamp"`
- Sparkline tooltip: `"sparkline_tooltip"`

Axis labels that should show a unit use ECharts template strings such as `"{value} ms"` (allowed without a registry key).

## Safe formatter registry

Pass registry keys as strings in options (for example `formatter: "timestamp_to_date"`). Keys currently defined in `getSafeFormatter`:

**Value formatters:** `duration_ms`, `percentage`, `number_delimited`, `timestamp`, `date`, `time`, `bytes`, `timestamp_to_date`

**Tooltip formatters:** `tooltip_time_ms`, `tooltip_date_ms`, `tooltip_time`, `tooltip_date`, `auto_date_tooltip`, `tooltip_with_timestamp`, `sparkline_tooltip`, `sparkline_percentage_tooltip`, `tooltip_with_timestamp_rate`

Unknown keys log a console warning and fall back to an identity function. Some legacy inline-looking strings are still heuristically mapped to registry entries; prefer explicit keys for new code.

## Zoom

When `zoom: true`, builders add a slider + inside `dataZoom`. With `zoom_start`, `zoom_end`, and `chart_data`, start/end values are timestamps (ms) for time-axis series, or category indices for labeled series.

## Assets

Rebuild chart JS/CSS after controller changes:

```bash
npm run build        # production assets into public/ + vendor/
npm run build:dev    # with source maps
```

Served by `RailsPulse::Middleware::AssetServer` from `/rails-pulse-assets/`, not the host app’s asset pipeline.

## Testing charts

- **Ruby:** `test/helpers/rails_pulse/chart_helper_test.rb` covers helpers and payload shapes.
- **JS:** `test/javascript/controllers/chart_controller.test.js` covers formatter and data-path logic with ECharts stubbed (`vi.stubGlobal('echarts', undefined)`). It does not render a real canvas. Full visual behavior belongs in system tests.
