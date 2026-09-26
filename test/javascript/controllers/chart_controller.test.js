import { describe, it, expect, afterEach, vi, beforeEach } from 'vitest'
import ChartController from '../../../app/javascript/rails_pulse/controllers/chart_controller'
import { mountController } from '../setup'

// ECharts is not available in JSDOM — stub it out so connect() doesn't loop
beforeEach(() => {
  vi.stubGlobal('echarts', undefined)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

// Build minimal HTML for a chart controller element with time-pair data
function makeTimePairHTML(seriesData) {
  const data = JSON.stringify({ series: seriesData })
  const options = JSON.stringify({
    xAxis: { axisLabel: { formatter: 'time' } }
  })
  return `
    <div
      id="chart-test"
      data-controller="rails-pulse--chart"
      data-rails-pulse--chart-type-value="line"
      data-rails-pulse--chart-data-value='${data}'
      data-rails-pulse--chart-options-value='${options}'
    ></div>
  `
}

const BASE_HTML = `
  <div
    id="chart-base"
    data-controller="rails-pulse--chart"
    data-rails-pulse--chart-type-value="line"
    data-rails-pulse--chart-data-value="{}"
    data-rails-pulse--chart-options-value="{}">
  </div>
`

describe('ChartController', () => {
  let app, element, teardown

  afterEach(() => teardown?.())

  // Helper that mounts and returns a controller instance without rendering ECharts
  async function mountChart(html) {
    ;({ app, element, teardown } = await mountController('rails-pulse--chart', ChartController, html))
    return app.getControllerForElementAndIdentifier(element, 'rails-pulse--chart')
  }

  async function mount() {
    ;({ app, element, teardown } = await mountController('rails-pulse--chart', ChartController, BASE_HTML))
  }

  function ctrl() {
    return app.getControllerForElementAndIdentifier(element, 'rails-pulse--chart')
  }

  // # getSafeFormatter('time')

  describe('getSafeFormatter("time")', () => {
    it('returns a function', async () => {
      const html = makeTimePairHTML([{ name: 'P95', data: [] }])
      const ctrl = await mountChart(html)
      const formatter = ctrl.getSafeFormatter('time')
      expect(typeof formatter).toBe('function')
    })

    it('formats two different hour timestamps to two different labels', async () => {
      const html = makeTimePairHTML([{ name: 'P95', data: [] }])
      const ctrl = await mountChart(html)
      const formatter = ctrl.getSafeFormatter('time')

      const t10am = new Date('2024-01-15T10:00:00').getTime()
      const t11am = new Date('2024-01-15T11:00:00').getTime()

      const label10 = formatter(t10am)
      const label11 = formatter(t11am)

      expect(label10).not.toBe(label11)
      expect(label10).toBe('10:00')
      expect(label11).toBe('11:00')
    })

    it('formats sub-hour timestamps to different labels (not all HH:00)', async () => {
      const html = makeTimePairHTML([{ name: 'P95', data: [] }])
      const ctrl = await mountChart(html)
      const formatter = ctrl.getSafeFormatter('time')

      const t705 = new Date('2024-01-15T07:05:00').getTime()
      const t710 = new Date('2024-01-15T07:10:00').getTime()
      const t715 = new Date('2024-01-15T07:15:00').getTime()

      expect(formatter(t705)).toBe('07:05')
      expect(formatter(t710)).toBe('07:10')
      expect(formatter(t715)).toBe('07:15')
      expect(formatter(t705)).not.toBe(formatter(t710))
    })
  })

  // # Daily formatters use the aggregation timezone, not the browser timezone (#303)

  describe('daily formatters use the aggregation timezone', () => {
    // Jan 15 in UTC, but Jan 14 in America/New_York (EST, UTC-5) — the exact
    // boundary mismatch reported in #303.
    const midnightBoundaryUTC = Date.UTC(2024, 0, 15, 2, 0, 0)

    function html(timezone) {
      return `
        <div
          id="chart-tz-test"
          data-controller="rails-pulse--chart"
          data-rails-pulse--chart-type-value="line"
          data-rails-pulse--chart-data-value="{}"
          data-rails-pulse--chart-options-value="{}"
          data-rails-pulse--chart-timezone-value="${timezone}"
          data-rails-pulse--chart-timezone-label-value="UTC"
        ></div>
      `
    }

    it('formats the "date" axis label in the aggregation zone', async () => {
      const ctrl = await mountChart(html('America/New_York'))
      const formatter = ctrl.getSafeFormatter('date')

      expect(formatter(midnightBoundaryUTC)).toBe('Jan 14')
    })

    it('formats "timestamp_to_date" axis labels in the aggregation zone', async () => {
      const ctrl = await mountChart(html('America/New_York'))
      const formatter = ctrl.getSafeFormatter('timestamp_to_date')

      expect(formatter(midnightBoundaryUTC)).toBe('Jan 14')
    })

    it('falls back to the browser zone when no aggregation timezone was provided', async () => {
      const ctrl = await mountChart(html(''))
      const formatter = ctrl.getSafeFormatter('date')

      const expected = new Date(midnightBoundaryUTC)
        .toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
      expect(formatter(midnightBoundaryUTC)).toBe(expected)
    })
  })

  describe('tooltip zone suffix', () => {
    // xAxis.axisLabel.formatter is the deterministic hourly/daily signal
    // isHourlyAxis() reads — it must be set the same way chart_helper.rb's
    // base_chart_options sets it, since that's the whole point of the fix
    // (not sniffing ECharts' own generated axisValueLabel).
    function html(timezone, timezoneLabel, hourly) {
      const options = JSON.stringify({ xAxis: { axisLabel: { formatter: hourly ? 'time' : 'timestamp_to_date' } } })
      return `
        <div
          id="chart-tz-tooltip-test"
          data-controller="rails-pulse--chart"
          data-rails-pulse--chart-type-value="line"
          data-rails-pulse--chart-data-value="{}"
          data-rails-pulse--chart-options-value='${options}'
          data-rails-pulse--chart-timezone-value="${timezone}"
          data-rails-pulse--chart-timezone-label-value="${timezoneLabel}"
        ></div>
      `
    }

    it('appends the aggregation zone label to a daily tooltip_with_timestamp', async () => {
      const ctrl = await mountChart(html('Etc/UTC', 'UTC', false))
      const formatter = ctrl.getSafeFormatter('tooltip_with_timestamp')

      const params = [{
        axisValue: Date.UTC(2024, 0, 15),
        axisValueLabel: 'Jan 15',
        seriesName: 'P95',
        marker: '●',
        value: [ Date.UTC(2024, 0, 15), 100 ]
      }]

      expect(formatter(params)).toContain('(UTC)')
    })

    it('appends the same aggregation zone label to an hourly tooltip_with_timestamp (no browser-zone split)', async () => {
      const ctrl = await mountChart(html('America/New_York', 'EST', true))
      const formatter = ctrl.getSafeFormatter('tooltip_with_timestamp')

      // 02:00 UTC is 21:00 the previous day in America/New_York — if this
      // were still browser-zone-formatted (and the test env's zone isn't
      // America/New_York), the hour and/or day would come out wrong.
      const params = [{
        axisValue: Date.UTC(2024, 0, 15, 2, 0),
        axisValueLabel: '02:00',
        seriesName: 'P95',
        marker: '●',
        value: [ Date.UTC(2024, 0, 15, 2, 0), 100 ]
      }]

      const rendered = formatter(params)
      expect(rendered).toContain('Jan 14, 21:00')
      expect(rendered).toContain('(EST)')
    })

    it('formats hourly and daily tooltips in the same zone (the aggregation zone) for the same chart', async () => {
      const hourlyCtrl = await mountChart(html('Etc/UTC', 'UTC', true))
      const dailyCtrl = await mountChart(html('Etc/UTC', 'UTC', false))

      const hourlyFormatter = hourlyCtrl.getSafeFormatter('tooltip_with_timestamp')
      const dailyFormatter = dailyCtrl.getSafeFormatter('tooltip_with_timestamp')

      const params = [{
        axisValue: Date.UTC(2024, 0, 15, 10, 0),
        seriesName: 'P95',
        marker: '●',
        value: [ Date.UTC(2024, 0, 15, 10, 0), 100 ]
      }]

      expect(hourlyFormatter(params)).toContain('(UTC)')
      expect(dailyFormatter(params)).toContain('(UTC)')
    })

    it('appends the zone suffix to a category-axis tooltip too (daily/weekly/monthly charts send a pre-formatted label, not a timestamp)', async () => {
      const ctrl = await mountChart(html('Etc/UTC', 'UTC', false))
      const formatter = ctrl.getSafeFormatter('tooltip_with_timestamp')

      // Category axis: axisValue is already a formatted string like "Apr 28",
      // not a ms timestamp — this used to skip the zone suffix entirely.
      const params = [{
        axisValue: 'Apr 28',
        seriesName: 'Requests',
        marker: '●',
        value: 42
      }]

      expect(formatter(params)).toContain('Apr 28 (UTC)')
    })

    it('appends the zone suffix to a category-axis sparkline tooltip too', async () => {
      const ctrl = await mountChart(html('Etc/UTC', 'UTC', false))
      const formatter = ctrl.getSafeFormatter('sparkline_tooltip')

      const params = [{
        axisValue: 'Apr 5',
        seriesName: 'P95',
        marker: '●',
        value: 150
      }]

      expect(formatter(params)).toContain('Apr 5 (UTC)')
    })

    it('decides whether auto_date_tooltip needs a year in the aggregation zone, not the browser zone', async () => {
      // "Now" is 2025-01-01 04:30 UTC, which is still 2024-12-31 23:30 in
      // America/New_York. A point from noon UTC on Dec 31 is in the current
      // year in the aggregation zone, so it must not carry a year suffix,
      // even though a UTC browser would call it last year.
      // Only Date is faked: connect() polls for echarts with setTimeout and
      // would never resolve under fully faked timers.
      vi.useFakeTimers({ toFake: [ 'Date' ] })
      vi.setSystemTime(new Date(Date.UTC(2025, 0, 1, 4, 30)))
      try {
        const ctrl = await mountChart(html('America/New_York', 'EST', false))
        const formatter = ctrl.getSafeFormatter('auto_date_tooltip')

        const params = [{
          axisValue: Date.UTC(2024, 11, 31, 12, 0),
          seriesName: 'P95',
          marker: '●',
          value: [ Date.UTC(2024, 11, 31, 12, 0), 100 ]
        }]

        expect(formatter(params)).toMatch(/^Dec 31 \(EST\)/)
      } finally {
        vi.useRealTimers()
      }
    })

    it('omits the suffix entirely when no zone label is available', async () => {
      const ctrl = await mountChart(html('', '', false))
      const formatter = ctrl.getSafeFormatter('tooltip_with_timestamp')

      const params = [{
        axisValue: Date.UTC(2024, 0, 15),
        axisValueLabel: 'Jan 15',
        seriesName: 'P95',
        marker: '●',
        value: [ Date.UTC(2024, 0, 15), 100 ]
      }]

      expect(formatter(params)).not.toContain('(')
    })

    it('classifies hourly by the formatter Ruby chose, not by axisValueLabel shape (#303 combo-chart regression)', async () => {
      // A stacked bar/shadow-pointer combo chart (e.g. Throughput & Errors)
      // can hand back an axisValueLabel that is NOT "HH:MM" even when the
      // underlying data is genuinely hourly. isHourlyAxis() must ignore that
      // and trust xAxis.axisLabel.formatter instead.
      const ctrl = await mountChart(html('Etc/UTC', 'UTC', true))
      const formatter = ctrl.getSafeFormatter('tooltip_with_timestamp')

      const params = [{
        axisValue: Date.UTC(2024, 0, 15, 14, 0),
        axisValueLabel: 'Mon Jan 15 2024 14:00:00 GMT+0000', // not "HH:MM"-shaped
        seriesName: 'Requests',
        marker: '●',
        value: [ Date.UTC(2024, 0, 15, 14, 0), 13 ]
      }]

      const html_ = formatter(params)
      expect(html_).not.toContain('Jan 15<br/>') // did not fall back to a date-only label
      expect(html_).toMatch(/^Jan 15, \d{2}:\d{2} \(/)
    })
  })

  // # buildChartConfig() — formatter preservation

  describe('buildChartConfig() with time-pair data', () => {
    it('preserves a function formatter on xAxis.axisLabel (does not replace it with a string)', async () => {
      const t0 = new Date('2024-01-15T10:00:00').getTime()
      const t1 = new Date('2024-01-15T11:00:00').getTime()
      const seriesData = [{ name: 'P95', data: [[t0, 150], [t1, 200]] }]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()

      expect(typeof config.xAxis.axisLabel.formatter).toBe('function')
    })

    it('sets xAxis.type to "time" when data contains [timestamp, value] pairs', async () => {
      const t0 = new Date('2024-01-15T10:00:00').getTime()
      const t1 = new Date('2024-01-15T11:00:00').getTime()
      const seriesData = [{ name: 'P95', data: [[t0, 150], [t1, 200]] }]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()

      expect(config.xAxis.type).toBe('time')
    })

    it('produces two different formatted labels for two different hour timestamps', async () => {
      const t0 = new Date('2024-01-15T10:00:00').getTime()
      const t1 = new Date('2024-01-15T11:00:00').getTime()
      const seriesData = [{ name: 'P95', data: [[t0, 150], [t1, 200]] }]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()
      const formatter = config.xAxis.axisLabel.formatter

      expect(typeof formatter).toBe('function')
      expect(formatter(t0)).not.toBe(formatter(t1))
    })

    it('sets xAxis.minInterval to the data\'s actual bucket size, so auto-placed ticks cannot land closer together than one real day and repeat the same date label', async () => {
      const day1 = new Date('2024-01-15T00:00:00').getTime()
      const day2 = new Date('2024-01-16T00:00:00').getTime()
      const day3 = new Date('2024-01-17T00:00:00').getTime()
      const seriesData = [{ name: 'P95', data: [[day1, 100], [day2, 110], [day3, 120]] }]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()

      expect(config.xAxis.minInterval).toBe(24 * 60 * 60 * 1000)
    })

    it('derives minInterval from the smallest gap even when an SLO series shares timestamps with the data series', async () => {
      const day1 = new Date('2024-01-15T00:00:00').getTime()
      const day2 = new Date('2024-01-16T00:00:00').getTime()
      const seriesData = [
        { name: 'P95 SLO (200ms)', data: [[day1, 200], [day2, 200]] },
        { name: 'P95', data: [[day1, 100], [day2, 110]] }
      ]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()

      expect(config.xAxis.minInterval).toBe(24 * 60 * 60 * 1000)
    })

    it('does not set minInterval when there is only one data point', async () => {
      const day1 = new Date('2024-01-15T00:00:00').getTime()
      const seriesData = [{ name: 'P95', data: [[day1, 100]] }]
      const html = makeTimePairHTML(seriesData)
      const ctrl = await mountChart(html)

      const config = ctrl.buildChartConfig()

      expect(config.xAxis.minInterval).toBeUndefined()
    })
  })

  // # Tooltip formatters — null value handling

  describe('auto_date_tooltip', () => {
    it('renders 0 instead of null when a series value is null', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('auto_date_tooltip')

      const params = [
        {
          axisValue: 1700000000000,
          axisValueLabel: 'Nov 14',
          seriesName: 'P95',
          marker: '●',
          value: [1700000000000, null]
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P95: 0')
      expect(html).not.toContain('null')
    })

    it('renders the rounded number when a series value is a number', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('auto_date_tooltip')

      const params = [
        {
          axisValue: 1700000000000,
          axisValueLabel: 'Nov 14',
          seriesName: 'P95',
          marker: '●',
          value: [1700000000000, 123.7]
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P95: 124')
    })
  })

  describe('tooltip_with_timestamp', () => {
    it('renders 0 instead of null when a series value is null', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')

      const params = [
        {
          axisValue: 1700000000000,
          axisValueLabel: 'Nov 14',
          seriesName: 'P99',
          marker: '●',
          value: [1700000000000, null]
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P99: 0')
      expect(html).not.toContain('null')
    })

    it('renders the rounded number when a series value is a number', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')

      const params = [
        {
          axisValue: 1700000000000,
          axisValueLabel: 'Nov 14',
          seriesName: 'P99',
          marker: '●',
          value: [1700000000000, 87.3]
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P99: 87')
    })

    it('renders 0 instead of null for a plain null value (non-array)', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')

      const params = [
        {
          axisValue: '2024-01-01',
          axisValueLabel: 'Jan 1',
          seriesName: 'Count',
          marker: '●',
          value: null
        }
      ]

      const html = formatter(params)
      expect(html).toContain('Count: 0')
      expect(html).not.toContain('null')
    })
  })

  describe('sparkline_tooltip', () => {
    it('renders 0 instead of null when the data value is null', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('sparkline_tooltip')

      const params = [
        {
          axisValue: '12:00',
          seriesName: 'P95',
          marker: '●',
          value: null
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P95: 0')
      expect(html).not.toContain('null')
    })

    it('renders the rounded number when the data value is a number', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('sparkline_tooltip')

      const params = [
        {
          axisValue: '12:00',
          seriesName: 'P95',
          marker: '●',
          value: 42.9
        }
      ]

      const html = formatter(params)
      expect(html).toContain('P95: 43')
    })
  })

  // # Tooltip formatters — number formatting

  it('formats large numbers with thousands separators in tooltip_with_timestamp', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')
    expect(typeof formatter).toBe('function')

    const params = [
      {
        axisValue: 'Jan 1',
        axisValueLabel: 'Jan 1',
        seriesName: 'P95',
        marker: '●',
        value: 15752,
      },
    ]

    const html = formatter(params)
    expect(html).toContain('15,752')
    expect(html).not.toMatch(/\b15752\b/)
  })

  it('formats large array values with thousands separators in tooltip_with_timestamp', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')

    const params = [
      {
        axisValue: 'Jan 1',
        axisValueLabel: 'Jan 1',
        seriesName: 'P95',
        marker: '●',
        value: [1700000000000, 15752],
      },
    ]

    const html = formatter(params)
    expect(html).toContain('15,752')
    expect(html).not.toMatch(/\b15752\b/)
  })

  it('leaves small numbers unchanged in tooltip_with_timestamp', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp')

    const params = [
      {
        axisValue: 'Jan 1',
        axisValueLabel: 'Jan 1',
        seriesName: 'P50',
        marker: '●',
        value: 42,
      },
    ]

    const html = formatter(params)
    expect(html).toContain('42')
  })

  it('formats large numbers with thousands separators in auto_date_tooltip', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('auto_date_tooltip')
    expect(typeof formatter).toBe('function')

    const params = [
      {
        axisValue: 'Jan 1',
        seriesName: 'Requests',
        marker: '●',
        value: 123456,
      },
    ]

    const html = formatter(params)
    expect(html).toContain('123,456')
    expect(html).not.toMatch(/\b123456\b/)
  })

  it('formats large array values with thousands separators in auto_date_tooltip', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('auto_date_tooltip')

    const params = [
      {
        axisValue: String(1700000000000),
        seriesName: 'Requests',
        marker: '●',
        value: [1700000000000, 123456],
      },
    ]

    const html = formatter(params)
    expect(html).toContain('123,456')
    expect(html).not.toMatch(/\b123456\b/)
  })

  it('formats large numbers with thousands separators in sparkline_tooltip', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('sparkline_tooltip')
    expect(typeof formatter).toBe('function')

    const params = [
      {
        axisValue: 'Apr 5',
        seriesName: 'P95',
        marker: '●',
        value: 15752,
      },
    ]

    const html = formatter(params)
    expect(html).toContain('15,752')
    expect(html).not.toMatch(/\b15752\b/)
  })

  it('sparkline_tooltip shows actual minutes for sub-hour timestamps', async () => {
    await mount()
    const formatter = ctrl().getSafeFormatter('sparkline_tooltip')
    const t715 = new Date('2024-01-15T07:15:00').getTime()
    const params = [{ axisValue: t715, seriesName: 'P95', marker: '●', value: 42 }]

    const html = formatter(params)
    expect(html).toContain('07:15')
    expect(html).not.toContain('07:00')
  })

  // # sparkline_percentage_tooltip

  describe('sparkline_percentage_tooltip', () => {
    it('formats value as a percentage with two decimal places', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('sparkline_percentage_tooltip')
      expect(typeof formatter).toBe('function')

      const params = [{ axisValue: 'Apr 5', seriesName: 'Error Rate', marker: '●', value: 7.5 }]
      const html = formatter(params)
      expect(html).toContain('7.50%')
    })

    it('shows 0.00% for zero error rate', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('sparkline_percentage_tooltip')
      const params = [{ axisValue: 'Apr 5', seriesName: 'Error Rate', marker: '●', value: 0 }]
      const html = formatter(params)
      expect(html).toContain('0.00%')
    })

    it('formats timestamp as HH:MM', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('sparkline_percentage_tooltip')
      const t715 = new Date('2024-01-15T07:15:00').getTime()
      const params = [{ axisValue: t715, seriesName: 'Error Rate', marker: '●', value: 3.5 }]
      const html = formatter(params)
      expect(html).toContain('07:15')
      expect(html).toContain('3.50%')
    })
  })

  // # tooltip_with_timestamp_rate

  describe('tooltip_with_timestamp_rate', () => {
    it('formats values as percentages with two decimal places', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp_rate')
      expect(typeof formatter).toBe('function')

      const t = new Date('2024-01-15T14:00:00').getTime()
      const params = [
        { axisValue: String(t), axisValueLabel: '14:00', seriesName: '5xx Errors', marker: '●', value: [t, 7.5] },
        { axisValue: String(t), axisValueLabel: '14:00', seriesName: '4xx Errors', marker: '●', value: [t, 0.25] }
      ]

      const html = formatter(params)
      expect(html).toContain('7.50%')
      expect(html).toContain('0.25%')
      expect(html).not.toMatch(/\b7\.5\b(?!%)/)
    })

    it('shows 0.00% for null values', async () => {
      await mount()
      const formatter = ctrl().getSafeFormatter('tooltip_with_timestamp_rate')
      const t = new Date('2024-01-15T14:00:00').getTime()
      const params = [
        { axisValue: String(t), axisValueLabel: '14:00', seriesName: '5xx Errors', marker: '●', value: [t, null] }
      ]
      const html = formatter(params)
      expect(html).toContain('0.00%')
      expect(html).not.toContain('null')
    })
  })
})
