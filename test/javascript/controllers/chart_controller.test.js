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
