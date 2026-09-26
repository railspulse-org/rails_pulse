import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    type: String,            // "bar", "line", "area", "sparkline"
    data: Object,            // Chart data
    options: Object,         // ECharts configuration
    theme: String,           // ECharts theme
    timezone: String,        // IANA zone summaries were bucketed in (e.g. "Etc/UTC")
    timezoneLabel: String    // Human label for the same zone (e.g. "UTC")
  }

  connect() {
    this.initializeChart()
    this.handleColorSchemeChange = this.onColorSchemeChange.bind(this)
    this.handleSeriesToggle = this.onSeriesToggle.bind(this)
    this.handleDeploymentMarkersToggle = this.onDeploymentMarkersToggle.bind(this)
    document.addEventListener('rails-pulse:color-scheme-changed', this.handleColorSchemeChange)
    document.addEventListener('rails-pulse:toggle-series', this.handleSeriesToggle)
    document.addEventListener('rails-pulse:toggle-deployment-markers', this.handleDeploymentMarkersToggle)
  }

  disconnect() {
    document.removeEventListener('rails-pulse:color-scheme-changed', this.handleColorSchemeChange)
    document.removeEventListener('rails-pulse:toggle-series', this.handleSeriesToggle)
    document.removeEventListener('rails-pulse:toggle-deployment-markers', this.handleDeploymentMarkersToggle)
    this.disposeChart()
  }

  // Main initialization with retry logic
  initializeChart() {
    this.retryCount = 0
    this.maxRetries = 100 // 5 seconds
    this.attemptInit()
  }

  attemptInit() {
    if (typeof echarts === 'undefined') {
      this.retryCount++
      if (this.retryCount >= this.maxRetries) {
        console.error('[RailsPulse] echarts not loaded after 5 seconds for', this.element.id)
        this.showError()
        return
      }
      setTimeout(() => this.attemptInit(), 50)
      return
    }

    this.renderChart()
  }

  renderChart() {
    try {
      // Initialize chart
      this.chart = echarts.init(this.element, this.themeValue || 'railspulse')

      // Build and set options
      const config = this.buildChartConfig()
      this.chart.setOption(config)

      // Apply current color scheme
      this.applyColorScheme()

      // Dispatch event for other controllers (event-based communication)
      document.dispatchEvent(new CustomEvent('stimulus:echarts:rendered', {
        detail: {
          containerId: this.element.id,
          chart: this.chart,
          controller: this
        }
      }))

      // Responsive resize — also reposition pixel-based deployment markers
      this.resizeObserver = new ResizeObserver(() => {
        if (this.chart) {
          this.chart.resize()
        }
      })
      this.resizeObserver.observe(this.element)

      // Listen for legend toggle events to adjust border radius dynamically
      this.chart.on('legendselectchanged', (params) => {
        this.handleLegendToggle(params)
      })

      // Click-to-copy on deployment marker lines
      this.chart.on('click', (params) => {
        if (params.componentType === 'markLine' && params.name) {
          navigator.clipboard.writeText(params.name).then(() => {
            this.showCopiedToast(params.name)
          }).catch(() => {})
        }
      })


      // Mark as rendered for tests
      this.element.setAttribute('data-chart-rendered', 'true')

    } catch (error) {
      console.error('[RailsPulse] Error initializing chart:', error)
      this.showError()
    }
  }

  buildChartConfig() {
    // Start with provided options
    const config = { ...this.optionsValue }

    // Process formatters (convert function strings to actual functions)
    this.processFormatters(config)

    // Set data (xAxis and series)
    this.setChartData(config)

    // Add hidden legend so series can be toggled programmatically via dispatchAction
    // Initialize series visibility from toggle button data-active attributes, defaulting to true
    if (!config.legend) {
      const toggleButtons = document.querySelectorAll(
        `[data-rails-pulse--series-toggle-chart-id-value="${this.element.id}"]`
      )
      const buttonStates = {}
      toggleButtons.forEach(btn => {
        const name = btn.getAttribute('data-rails-pulse--series-toggle-series-name-value')
        if (name) buttonStates[name] = btn.dataset.active !== 'false'
      })

      const selected = {}
      if (config.series && Array.isArray(config.series)) {
        config.series.forEach(s => {
          if (s.name) {
            selected[s.name] = s.name in buttonStates ? buttonStates[s.name] : true
          }
        })
      }
      config.legend = { show: false, selected: selected }
    }

    // Add deployment markers as a dedicated hidden series (time axis only)
    const chartData = this.dataValue
    const markers = chartData.deployment_markers
    if (markers && markers.length > 0 && this._usesTimeAxisData(chartData)) {
      const scope = this.element.closest('[data-controller~="rails-pulse--index"]') || document
      const deploysButton = scope.querySelector('[data-controller~="rails-pulse--deployment-markers-toggle"]')
      const isVisible = !deploysButton || deploysButton.dataset.active !== 'false'
      config.series = config.series || []
      config.series.push(this._buildDeploymentMarkerSeries(markers, isVisible))
    }

    return config
  }

  setChartData(config) {
    const data = this.dataValue

    // Check if data is in multi-series format (has series key)
    if (data && typeof data === 'object' && data.series) {
      // Detect axis type from first data point: [timestamp, value] pairs or { value: [timestamp, value] }
      // use a true time axis; plain values remain category axis.
      const firstPoint = data.series[0]?.data?.[0]
      const isTimePairs = Array.isArray(firstPoint) || Array.isArray(firstPoint?.value)

      config.xAxis = config.xAxis || {}
      if (isTimePairs) {
        config.xAxis.type = 'time'
        // Without this, ECharts spaces ticks by pixel width, not by the data's
        // actual bucket size — a multi-day "time" axis can end up with more
        // ticks than days, and since the label formatter only shows the date,
        // adjacent ticks on the same day render as duplicate-looking labels.
        const bucketMs = this._minTimestampGapMs(data.series)
        if (bucketMs) config.xAxis.minInterval = bucketMs
      } else {
        config.xAxis.type = 'category'
        config.xAxis.data = data.labels
      }

      // Set yAxis
      config.yAxis = config.yAxis || {}
      config.yAxis.type = 'value'

      // Set series data from provided series array, merging any series-level options (e.g. itemStyle)
      const seriesOptions = (config.series && !Array.isArray(config.series)) ? config.series : {}
      config.series = data.series.map((seriesData) => ({
        type: this.typeValue,
        ...seriesOptions,
        ...seriesData
      }))

    } else {
      // Single-series format (backward compatibility)
      // Extract labels and values
      const labels = Object.keys(data).map(k => {
        const num = Number(k)
        return isNaN(num) ? k : num
      })

      const values = Object.values(data).map(v => {
        if (typeof v === 'object' && v !== null) {
          // If object has value property, check if it has other properties too
          if (v.value !== undefined) {
            // If it has other properties (like itemStyle), return the whole object
            const keys = Object.keys(v)
            if (keys.length > 1 || (keys.length === 1 && keys[0] !== 'value')) {
              return v
            }
            // Otherwise just return the value
            return v.value
          }
          return v
        }
        return v
      })

      // Set xAxis data
      config.xAxis = config.xAxis || {}
      config.xAxis.type = 'category'
      config.xAxis.data = labels

      // Set yAxis
      config.yAxis = config.yAxis || {}
      config.yAxis.type = 'value'

      // Set series data
      if (Array.isArray(config.series)) {
        // If series is already an array, update first series
        config.series[0] = config.series[0] || {}
        config.series[0].type = this.typeValue
        config.series[0].data = values
      } else if (config.series && typeof config.series === 'object') {
        // If series is a single object (from helper), convert to array
        const seriesConfig = { ...config.series }
        config.series = [{
          type: this.typeValue,
          data: values,
          ...seriesConfig
        }]
      } else {
        // No series provided, create default
        config.series = [{
          type: this.typeValue,
          data: values
        }]
      }
    }
  }

  _usesTimeAxisData(data = this.dataValue) {
    const firstPoint = data?.series?.find(series => Array.isArray(series?.data) && series.data.length > 0)?.data?.[0]
    return Array.isArray(firstPoint) || Array.isArray(firstPoint?.value)
  }

  // Smallest gap (ms) between any two distinct timestamps across all series,
  // used as xAxis.minInterval so auto-placed ticks never fall closer together
  // than the data actually does.
  _minTimestampGapMs(series) {
    const timestamps = new Set()
    series.forEach(s => {
      (s.data || []).forEach(point => {
        const pair = Array.isArray(point) ? point : (Array.isArray(point?.value) ? point.value : null)
        if (pair && typeof pair[0] === 'number') timestamps.add(pair[0])
      })
    })

    const sorted = Array.from(timestamps).sort((a, b) => a - b)
    let minGap = null
    for (let i = 1; i < sorted.length; i++) {
      const gap = sorted[i] - sorted[i - 1]
      if (gap > 0 && (minGap === null || gap < minGap)) minGap = gap
    }
    return minGap
  }

  deploymentMarkerSeriesId = 'rails-pulse-deployment-markers'

  _buildDeploymentMarkerSeries(markers, visible = true) {
    return {
      id: this.deploymentMarkerSeriesId,
      type: 'line',
      data: [],
      name: '',
      showSymbol: false,
      symbolSize: 0,
      silent: false,
      animation: false,
      legendHoverLink: false,
      lineStyle: { opacity: 0 },
      itemStyle: { opacity: 0 },
      tooltip: { show: false },
      z: 10,
      markLine: visible ? this._buildMarkLineConfig(markers) : { data: [] }
    }
  }

  _buildMarkLineConfig(markers) {
    const labelFormatter = (params) => {
      const timestamp = params?.data?.xAxis
      const revision = params?.data?.revision
      if (typeof timestamp !== 'number') return ''

      const timeString = new Date(timestamp).toLocaleTimeString('en-US', {
        hour: '2-digit', minute: '2-digit', hour12: false
      })

      if (!revision) return `{time|${timeString}}`
      return `{time|${timeString}}\n{revision|${revision}}`
    }

    const lineStyle = { color: '#22c55e', type: 'dashed', width: 2, opacity: 0.8 }
    const labelConfig = {
      color: '#22c55e',
      formatter: labelFormatter,
      rich: {
        time: {
          color: '#22c55e',
          fontWeight: 600
        },
        revision: {
          color: '#22c55e',
          fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
          fontSize: 11
        }
      }
    }

    return {
      symbol: [ 'none', 'none' ],
      silent: false,
      lineStyle: lineStyle,
      label: {
        ...labelConfig,
        show: false
      },
      emphasis: {
        lineStyle: lineStyle,
        label: {
          ...labelConfig,
          show: true
        }
      },
      data: markers.map(m => ({
        xAxis: m.timestamp,
        name: m.revision,
        revision: m.revision,
        started_at: m.started_at
      })),
      tooltip: {
        show: true,
        formatter: (params) => {
          const revision = params?.data?.revision || params.name
          const startedAt = params?.data?.started_at
          if (!startedAt) return revision
          const date = new Date(startedAt).toLocaleString('en-US', {
            month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
          })
          return `<strong>Deploy</strong><br/><code style="font-size:11px">${revision}</code><br/>${date}<br/><span style="font-size:10px;opacity:0.7">Click to copy SHA</span>`
        }
      }
    }
  }

  processFormatters(config) {
    // Process tooltip formatter
    if (config.tooltip?.formatter && typeof config.tooltip.formatter === 'string') {
      // Check if it's an ECharts template pattern (e.g., "{value}", "{value} ms")
      if (this.isEChartsTemplate(config.tooltip.formatter)) {
        // Leave ECharts templates as-is
      } else {
        config.tooltip.formatter = this.parseFormatter(config.tooltip.formatter)
        // Store reference so applyColorScheme can restore it after its setOption merge
        this._tooltipFormatter = config.tooltip.formatter
      }
    }

    // Process xAxis formatter
    if (config.xAxis?.axisLabel?.formatter && typeof config.xAxis.axisLabel.formatter === 'string') {
      if (!this.isEChartsTemplate(config.xAxis.axisLabel.formatter)) {
        config.xAxis.axisLabel.formatter = this.parseFormatter(config.xAxis.axisLabel.formatter)
      }
    }

    // Process yAxis formatter
    if (config.yAxis?.axisLabel?.formatter && typeof config.yAxis.axisLabel.formatter === 'string') {
      if (!this.isEChartsTemplate(config.yAxis.axisLabel.formatter)) {
        config.yAxis.axisLabel.formatter = this.parseFormatter(config.yAxis.axisLabel.formatter)
      }
    }
  }

  isEChartsTemplate(formatterString) {
    // ECharts template strings use {variableName} patterns
    // Common patterns: {value}, {a}, {b}, {c}, {seriesName}, etc.
    return /^\{[a-zA-Z0-9_]+\}/.test(formatterString.trim()) ||
           formatterString.includes('{value}') ||
           formatterString.includes('{a}') ||
           formatterString.includes('{b}') ||
           formatterString.includes('{c}')
  }

  parseFormatter(formatterString) {
    // Remove function markers if present
    const cleanString = formatterString.replace(/__FUNCTION_START__|__FUNCTION_END__/g, '')

    // Always use safe formatter registry (handles both function strings and keys like "timestamp_to_date")
    return this.getSafeFormatter(cleanString)
  }

  // Formats in the aggregation zone, not the browser's — SummaryJob fixes a
  // day's boundary at write time, so browser-zone display can flip the date.
  formatDailyDate(date, extraOptions = {}) {
    const timeZone = this.timezoneValue || undefined
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone, ...extraOptions })
  }

  // "Mon D, HH:MM" — the hourly-granularity counterpart to formatDailyDate.
  formatDailyDateTime(date) {
    const timeZone = this.timezoneValue || undefined
    return date.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false, timeZone })
  }

  // "HH:MM" only, same zone as the above.
  formatHourMinute(date) {
    const timeZone = this.timezoneValue || undefined
    return date.toLocaleString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone })
  }

  // Year comparison in the same zone as the label it decorates, so a point
  // near New Year is not tagged with a year the aggregation zone has not
  // reached yet (or has already left).
  isCurrentYear(date) {
    const options = { year: 'numeric', timeZone: this.timezoneValue || undefined }
    return date.toLocaleDateString('en-US', options) === new Date().toLocaleDateString('en-US', options)
  }

  // Hourly vs. daily comes from the formatter key Ruby chose, not ECharts'
  // generated axisValueLabel (unreliable for some axis-pointer/series combos).
  isHourlyAxis() {
    return this.optionsValue?.xAxis?.axisLabel?.formatter === "time"
  }

  // Appends " (Zone)" to a tooltip's date/time string when a zone label is
  // available, so a hover always says which zone the point is in.
  withZoneSuffix(dateString) {
    const zone = this.timezoneLabelValue || ''
    return zone ? `${dateString} (${zone})` : dateString
  }

  /**
   * Returns a safe formatter function based on the formatter string.
   * This prevents arbitrary code execution by using a whitelist approach.
   *
   * Security: Replaces eval() to prevent XSS and code injection attacks.
   */
  getSafeFormatter(formatterString) {
    // Whitelist of safe formatter patterns
    // Each pattern maps to a safe implementation
    const SAFE_FORMATTERS = {
      // Duration formatter (milliseconds)
      'duration_ms': (value) => {
        if (typeof value === 'number') {
          return value.toFixed(2) + ' ms'
        }
        return value
      },

      // Percentage formatter
      'percentage': (value) => {
        if (typeof value === 'number') {
          return value.toFixed(1) + '%'
        }
        return value
      },

      // Number with commas
      'number_delimited': (value) => {
        if (typeof value === 'number') {
          return value.toLocaleString()
        }
        return value
      },

      // Timestamp formatter
      'timestamp': (value) => {
        if (typeof value === 'number' || typeof value === 'string') {
          const date = new Date(value)
          return date.toLocaleString()
        }
        return value
      },

      // Date only (formatted as "Mon DD" to match Rails Pulse formatters)
      'date': (value) => {
        if (typeof value === 'number' || typeof value === 'string') {
          // Convert to number if string
          const numValue = typeof value === 'string' ? parseInt(value) : value
          const date = new Date(numValue)

          if (isNaN(date.getTime())) {
            return value.toString()
          }

          return this.formatDailyDate(date)
        }
        return value
      },

      // Time only (formatted as "HH:00" to match Rails Pulse formatters)
      'time': (value) => {
        if (typeof value === 'number' || typeof value === 'string') {
          const numValue = typeof value === 'string' ? parseInt(value) : value
          const date = new Date(numValue)

          if (isNaN(date.getTime())) {
            return value.toString()
          }

          return this.formatHourMinute(date)
        }
        return value
      },

      // Bytes formatter
      'bytes': (value) => {
        if (typeof value !== 'number') return value

        const units = ['B', 'KB', 'MB', 'GB', 'TB']
        let size = value
        let unitIndex = 0

        while (size >= 1024 && unitIndex < units.length - 1) {
          size /= 1024
          unitIndex++
        }

        return size.toFixed(2) + ' ' + units[unitIndex]
      },

      // Tooltip formatters (these receive params array, not a single value)
      // Tooltip with time (HH:MM) and milliseconds
      'tooltip_time_ms': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        const date = new Date(data.axisValue)
        const dateString = this.withZoneSuffix(this.formatHourMinute(date))
        const value = parseInt(data.data)

        return `${dateString} <br /> ${data.marker} ${value} ms`
      },

      // Tooltip with date (Mon DD) and milliseconds
      'tooltip_date_ms': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        const date = new Date(data.axisValue)
        const dateString = this.withZoneSuffix(this.formatDailyDate(date))
        const value = parseInt(data.data)

        return `${dateString} <br /> ${data.marker} ${value} ms`
      },

      // Tooltip with time (HH:MM) - generic
      'tooltip_time': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        const date = new Date(data.axisValue)
        const dateString = this.withZoneSuffix(this.formatHourMinute(date))

        return `${dateString} <br /> ${data.marker} ${data.data}`
      },

      // Tooltip with date (Mon DD) - generic
      'tooltip_date': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        const date = new Date(data.axisValue)
        const dateString = this.withZoneSuffix(this.formatDailyDate(date))

        return `${dateString} <br /> ${data.marker} ${data.data}`
      },

      // Auto date tooltip - formats timestamp and shows all series
      'auto_date_tooltip': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        // Get the axis value (timestamp) from first series
        const axisValue = params[0].axisValue || params[0].axisValueLabel
        let dateString = axisValue

        // Try to parse as timestamp and format
        if (typeof axisValue === 'number' || (typeof axisValue === 'string' && !isNaN(Number(axisValue)))) {
          const timestamp = Number(axisValue)
          const date = new Date(timestamp)
          if (!isNaN(date.getTime())) {
            dateString = this.formatDailyDate(date, {
              year: this.isCurrentYear(date) ? undefined : 'numeric'
            })
          }
        }
        // Category axis sends an already-formatted label (e.g. "Apr 28")
        // instead of a timestamp — still needs the suffix below.
        dateString = this.withZoneSuffix(dateString)

        // Build tooltip HTML with all series
        let html = `${dateString}<br/>`
        params.forEach(param => {
          // param.value may be [timestamp, value] for time axis or a plain number
          const rawValue = Array.isArray(param.value) ? param.value[1] : param.value
          const value = typeof rawValue === 'number' ? Math.round(rawValue).toLocaleString('en-US') : (rawValue ?? 0)
          html += `${param.marker} ${param.seriesName}: ${value}<br/>`
        })

        return html
      },

      // Timestamp to date formatter for axis labels
      'timestamp_to_date': (value) => {
        // Try to parse as number if it's a numeric string
        const numValue = typeof value === 'string' ? parseFloat(value) : value

        // If it's a timestamp (number > 1 trillion = after year 2001 in ms), format it
        if (typeof numValue === 'number' && !isNaN(numValue) && numValue > 1000000000000) {
          const date = new Date(numValue)
          if (!isNaN(date.getTime())) {
            return this.formatDailyDate(date)
          }
        }

        // If it's already a formatted string (like "Mar 30"), return as-is
        return value
      },

      // Tooltip with timestamp formatting
      'tooltip_with_timestamp': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        // axisValue is the raw value — a ms timestamp for time axis, an
        // already-formatted category string (e.g. "Apr 28") otherwise
        const axisValue = params[0].axisValue
        const ts = Number(axisValue)
        let dateString

        if (!isNaN(ts) && ts > 1000000000000) {
          const date = new Date(ts)
          // Sub-day granularity comes from the formatter Ruby chose for this
          // chart, not from ECharts' own generated axisValueLabel (unreliable
          // for some axis-pointer/series combinations — see isHourlyAxis()).
          dateString = this.isHourlyAxis() ? this.formatDailyDateTime(date) : this.formatDailyDate(date)
        } else {
          // Category axis (daily/weekly/monthly charts send a plain,
          // already-formatted label like "Apr 28" instead of an epoch
          // timestamp) — still needs the zone suffix, same as the time-axis
          // branch above, or daily-grouped charts silently lose it.
          dateString = axisValue
        }
        dateString = this.withZoneSuffix(dateString)

        // Build tooltip HTML with all series
        let html = `${dateString}<br/>`
        params.forEach(param => {
          // param.value may be [timestamp, value] for time axis or a plain number
          const rawValue = Array.isArray(param.value) ? param.value[1] : param.value
          const value = typeof rawValue === 'number' ? Math.round(rawValue).toLocaleString('en-US') : (rawValue ?? 0)
          html += `${param.marker} ${param.seriesName}: ${value}<br/>`
        })

        return html
      },

      // Sparkline tooltip - simpler format for small charts
      'sparkline_tooltip': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        let axisValue = data.axisValue
        const value = typeof data.value === 'number' ? Math.round(data.value).toLocaleString('en-US') : (data.value ?? 0)
        const seriesName = data.seriesName || 'Value'

        // Format timestamp as HH:MM if it's a number (timestamp in milliseconds)
        const numValue = typeof axisValue === 'string' ? parseFloat(axisValue) : axisValue
        if (typeof numValue === 'number' && !isNaN(numValue) && numValue > 1000000000000) {
          const date = new Date(numValue)
          if (!isNaN(date.getTime())) {
            axisValue = this.formatHourMinute(date)
          }
        }
        // Either the hour just computed above, or an already-formatted daily
        // label (like "Apr 5") — both need the suffix, or daily sparklines
        // silently lose it.
        axisValue = this.withZoneSuffix(axisValue)

        // Show marker, series name, and value (e.g., "● P95: 150")
        return `${axisValue}<br/>${data.marker} ${seriesName}: ${value}`
      },

      // Sparkline tooltip for rate metrics - shows value as a percentage
      'sparkline_percentage_tooltip': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const data = params[0]
        let axisValue = data.axisValue
        const rawValue = typeof data.value === 'number' ? data.value : (data.value ?? 0)
        const value = typeof rawValue === 'number' ? rawValue.toFixed(2) + '%' : rawValue
        const seriesName = data.seriesName || 'Value'

        // Format timestamp as HH:MM if it's a number (timestamp in milliseconds)
        const numValue = typeof axisValue === 'string' ? parseFloat(axisValue) : axisValue
        if (typeof numValue === 'number' && !isNaN(numValue) && numValue > 1000000000000) {
          const date = new Date(numValue)
          if (!isNaN(date.getTime())) {
            axisValue = this.formatHourMinute(date)
          }
        }
        axisValue = this.withZoneSuffix(axisValue)

        return `${axisValue}<br/>${data.marker} ${seriesName}: ${value}`
      },

      // Multi-series tooltip for rate/percentage charts (e.g. error rate chart)
      'tooltip_with_timestamp_rate': (params) => {
        if (!Array.isArray(params) || params.length === 0) return ''

        const axisValue = params[0].axisValue
        const ts = Number(axisValue)
        let dateString

        if (!isNaN(ts) && ts > 1000000000000) {
          const date = new Date(ts)
          dateString = this.isHourlyAxis() ? this.formatDailyDateTime(date) : this.formatDailyDate(date)
        } else {
          // Category axis (daily/weekly/monthly) — see tooltip_with_timestamp.
          dateString = axisValue
        }
        dateString = this.withZoneSuffix(dateString)

        let html = `${dateString}<br/>`
        params.forEach(param => {
          const rawValue = Array.isArray(param.value) ? param.value[1] : param.value
          const numericValue = typeof rawValue === 'number' ? rawValue : 0
          const value = numericValue.toFixed(2) + '%'
          html += `${param.marker} ${param.seriesName}: ${value}<br/>`
        })

        return html
      }
    }

    // IMPORTANT: Check for SPECIFIC patterns FIRST before generic keyword matching
    // The order matters! More specific patterns should be checked before generic ones.

    // Check for tooltip formatters first (they have params[0], data.axisValue, data.marker)
    const isTooltipFormatter = formatterString.includes('params') &&
                                formatterString.includes('params[0]') &&
                                formatterString.includes('axisValue')

    if (isTooltipFormatter) {
      // Check if it's time-based (has getHours)
      if (formatterString.includes('getHours')) {
        // Check if it formats milliseconds
        if (formatterString.includes('ms')) {
          return SAFE_FORMATTERS.tooltip_time_ms
        }
        return SAFE_FORMATTERS.tooltip_time
      }

      // Check if it's date-based (has toLocaleDateString)
      if (formatterString.includes('toLocaleDateString')) {
        // Check if it formats milliseconds
        if (formatterString.includes('ms')) {
          return SAFE_FORMATTERS.tooltip_date_ms
        }
        return SAFE_FORMATTERS.tooltip_date
      }

      // Default tooltip formatter (shouldn't reach here normally)
      return SAFE_FORMATTERS.tooltip_date
    }

    // Check for axis label formatters (single value parameter)
    if (formatterString.includes('getHours')) {
      return SAFE_FORMATTERS.time
    }

    if (formatterString.includes('toLocaleDateString')) {
      return SAFE_FORMATTERS.date
    }

    if (formatterString.includes('toLocaleTimeString')) {
      return SAFE_FORMATTERS.time
    }

    if (formatterString.includes('toLocaleString')) {
      return SAFE_FORMATTERS.number_delimited
    }

    if (formatterString.includes('toFixed(2)') && formatterString.includes('ms')) {
      return SAFE_FORMATTERS.duration_ms
    }

    // Try exact match first
    if (SAFE_FORMATTERS[formatterString]) {
      return SAFE_FORMATTERS[formatterString]
    }

    // Try to match the formatter string to a known safe pattern by key name
    // This is less specific and should come after exact match
    for (const [key, formatter] of Object.entries(SAFE_FORMATTERS)) {
      if (formatterString.includes(key) ||
          formatterString.includes(key.replace('_', ''))) {
        return formatter
      }
    }

    // Default: return a safe identity function that just returns the value
    console.warn('[RailsPulse] Unknown formatter pattern, using identity function:', formatterString.substring(0, 100))
    return (value) => value
  }

  findDeploymentCopyHintElement() {
    const scope = this.element.closest('[data-controller~="rails-pulse--index"]') || document
    const hints = Array.from(scope.querySelectorAll('[data-rails-pulse--deployment-markers-toggle-target="message"]'))
    return hints.find(el => el.offsetParent !== null) || null
  }

  showCopiedToast(revision) {
    const toast = document.createElement('div')
    toast.textContent = `Copied ${revision}`

    const hint = this.findDeploymentCopyHintElement()
    if (hint) {
      const rect = hint.getBoundingClientRect()
      toast.style.cssText = `position:fixed;top:${rect.top + (rect.height / 2)}px;left:${rect.right + 8}px;transform:translateY(-50%);background:#22c55e;color:#fff;padding:0.35rem 0.7rem;border-radius:6px;font-size:12px;font-family:monospace;white-space:nowrap;z-index:9999;pointer-events:none;opacity:1;transition:opacity 0.4s ease`
    } else {
      toast.style.cssText = 'position:fixed;bottom:1rem;right:1rem;background:#22c55e;color:#fff;padding:0.4rem 0.8rem;border-radius:6px;font-size:13px;font-family:monospace;z-index:9999;pointer-events:none;opacity:1;transition:opacity 0.4s ease'
    }

    document.body.appendChild(toast)
    setTimeout(() => { toast.style.opacity = '0' }, 1500)
    setTimeout(() => { toast.remove() }, 2000)
  }

  showError() {
    this.element.classList.add('chart-error')
    this.element.innerHTML = '<p class="text-subtle p-4">Chart failed to load</p>'
  }

  // Public accessor for chart instance
  get chartInstance() {
    return this.chart
  }

  disposeChart() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }

    if (this.chart) {
      this.chart.dispose()
      this.chart = null
    }
  }

  // Action for dynamic updates
  update(event) {
    if (event.detail?.data) {
      this.dataValue = event.detail.data
    }
    if (event.detail?.options) {
      this.optionsValue = event.detail.options
    }
    if (this.chart) {
      const config = this.buildChartConfig()
      this.chart.setOption(config, true) // true = not merge
    }
  }

  // Series toggle — dispatched from series_toggle_controller
  // Toggles all series whose name starts with seriesName (e.g. "P95" matches "P95" and "P95 SLO (200ms)")
  onSeriesToggle({ detail: { chartId, seriesName } }) {
    if (chartId !== this.element.id || !this.chart) return

    const allNames = (this.dataValue?.series || []).map(s => s.name).filter(Boolean)
    const matches = allNames.filter(name => name.startsWith(seriesName))
    const namesToToggle = matches.length > 0 ? matches : [seriesName]

    namesToToggle.forEach(name => {
      this.chart.dispatchAction({ type: 'legendToggleSelect', name })
    })
  }

  // Deployment markers toggle — show/hide the dedicated marker series overlay
  onDeploymentMarkersToggle({ detail: { visible } }) {
    if (!this.chart) return
    const markers = this.dataValue?.deployment_markers
    if (!markers?.length || !this._usesTimeAxisData()) return

    this.chart.setOption({
      series: [ this._buildDeploymentMarkerSeries(markers, visible) ]
    })
  }

  // Handle legend toggle to adjust border radius for stacked bars
  handleLegendToggle(params) {
    if (!this.chart) return

    const option = this.chart.getOption()
    const series = option.series || []

    // Only process if we have stacked bar series
    const hasStackedBars = series.some(s => s.type === 'bar' && s.stack)
    if (!hasStackedBars) return

    // Get visibility state from legend
    const selected = params.selected || {}

    // Find visible series (in order)
    const visibleSeriesIndices = []
    series.forEach((s, index) => {
      const isVisible = selected[s.name] !== false
      if (isVisible && s.type === 'bar' && s.stack) {
        visibleSeriesIndices.push(index)
      }
    })

    if (visibleSeriesIndices.length === 0) return

    // Get the topmost visible series (last in the array for stacked bars)
    const topSeriesIndex = visibleSeriesIndices[visibleSeriesIndices.length - 1]

    // Update border radius for each series
    const updatedSeries = series.map((s, index) => {
      if (s.type !== 'bar' || !s.stack) return s

      const isVisible = visibleSeriesIndices.includes(index)
      const isTop = index === topSeriesIndex

      return {
        ...s,
        itemStyle: {
          ...(s.itemStyle || {}),
          borderRadius: (isVisible && isTop) ? [5, 5, 0, 0] : [0, 0, 0, 0]
        }
      }
    })

    // Apply the updated configuration
    this.chart.setOption({ series: updatedSeries })
  }

  // Color scheme management
  onColorSchemeChange() {
    this.applyColorScheme()
  }

  applyColorScheme() {
    if (!this.chart) return

    const scheme = document.documentElement.getAttribute('data-color-scheme')
    const isDark = scheme === 'dark'

    const axisLabelColor = isDark ? 'rgba(255,255,255,0.55)' : '#999999'
    const gridColor      = isDark ? 'rgba(255,255,255,0.07)' : '#eeeeee'
    const tooltipBg      = isDark ? 'rgba(24,24,27,0.95)'    : 'rgba(255,255,255,0.95)'
    const tooltipText    = isDark ? '#e4e4e7'                 : '#18181b'
    const tooltipBorder  = isDark ? 'rgba(255,255,255,0.12)' : '#cccccc'

    // Re-include the tooltip formatter explicitly — ECharts can drop function formatters
    // during option merges, so we preserve the reference and restore it here.
    const tooltipUpdate = {
      backgroundColor: tooltipBg,
      textStyle: { color: tooltipText },
      borderColor: tooltipBorder
    }
    if (this._tooltipFormatter) tooltipUpdate.formatter = this._tooltipFormatter

    this.chart.setOption({
      xAxis: {
        axisLabel: { color: axisLabelColor },
        splitLine: { lineStyle: { color: gridColor } }
      },
      yAxis: {
        axisLabel: { color: axisLabelColor },
        splitLine: { lineStyle: { color: gridColor } }
      },
      tooltip: tooltipUpdate
    })
  }
}
