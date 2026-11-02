import { Controller } from "@hotwired/stimulus"
import { loadInto } from "../utils/fetch_helpers"

export default class extends Controller {
  static targets = ["chart", "paginationLimit", "indexTable"]

  static values = {
    chartId: String        // The ID of the chart to be monitored
  }

  // Add properties for improved debouncing
  lastFrameRequestAt = 0;
  pendingRequestTimeout = null;
  pendingRequestData = null;
  selectedColumnIndex = null;
  zrClickHandler = null;
  highlightBarName = '__rp_col_bg__';
  deploymentMarkerSeriesId = 'rails-pulse-deployment-markers';
  charts = {};          // all chart instances keyed by container ID
  chartControllers = {}; // chart Stimulus controllers keyed by container ID
  chartSetup = {};      // tracks which charts have been fully set up
  activeChartId = null; // ID of the currently active chart

  connect() {
    // Respect chart_type URL param so the active chart's listeners are set up correctly on load
    const urlParams = new URLSearchParams(window.location.search)
    const chartType = urlParams.get('chart_type')
    const chartTypeMap = {
      response_time: 'response_time_percentiles_chart',
      request_rate: 'request_rate_chart',
      error_rate: 'error_rate_chart',
      query_performance: 'query_performance_chart',
      execution_volume: 'execution_volume_chart',
      database_load: 'database_load_chart'
    }
    this.activeChartId = chartTypeMap[chartType] || this.chartIdValue

    // Listen for the custom event 'stimulus:echarts:rendered' to set up the chart.
    // This event is dispatched by the chart controller when the chart is ready.
    this.handleChartInitialized = this.onChartInitialized.bind(this);

    document.addEventListener('stimulus:echarts:rendered', this.handleChartInitialized);

    // Releasing the mouse outside the chart still ends a drag-zoom. This is not
    // chart-specific, so it is bound once per controller rather than in
    // setupChartEventListeners — that runs again on every chart switch and used
    // to stack a new document listener each time.
    this.handleDocumentMouseUp = () => {
      if (!this.chart || !this.visibleData) return;
      this.handleZoomChange();
    };
    document.addEventListener('mouseup', this.handleDocumentMouseUp);
  }

  disconnect() {
    // Remove the event listener when the controller is disconnected
    document.removeEventListener('stimulus:echarts:rendered', this.handleChartInitialized);

    // Remove chart event listeners if they exist
    const activeContainer = this.getActiveChartContainer()
    if (activeContainer) {
      activeContainer.removeEventListener('mousedown', this.handleChartMouseDown);
      activeContainer.removeEventListener('mouseup', this.handleChartMouseUp);
    }
    document.removeEventListener('mouseup', this.handleDocumentMouseUp);

    // Remove ZRender handlers
    try {
      if (this.chart && this.zrClickHandler) {
        this.chart.getZr().off('click', this.zrClickHandler)
      }
      if (this.chart && this.zrMouseMoveHandler) {
        this.chart.getZr().off('mousemove', this.zrMouseMoveHandler)
      }
    } catch { /* chart may already be disposed */ }

    // Clear any pending timeout
    if (this.pendingRequestTimeout) {
      clearTimeout(this.pendingRequestTimeout);
    }
  }

  // After the chart is initialized, set up the event listeners and data tracking
  onChartInitialized(event) {
    const { containerId, chart, controller } = event.detail

    // Store every chart instance as it renders
    this.charts[containerId] = chart
    this.chartControllers[containerId] = controller

    // Only fully set up the initially active chart
    if (containerId === this.activeChartId) {
      this.chart = chart;
      this.setup();
    }
  }

  // Called when the chart switcher changes the active chart
  handleChartSwitched(event) {
    const { toId } = event.detail
    if (!toId || toId === this.activeChartId) return

    // Capture current zoom state before switching
    const zoomState = this.captureZoomState()

    // Tear down listeners from the outgoing chart
    this.teardownActiveChartListeners()

    // Clear cached bar styles so they get re-read from the incoming chart's data.
    // Keep selectedColumnIndex — initializeColumnSelectionFromUrl will resolve the
    // correct index for the new chart from the URL's selected_column_time param.
    this.originalBarItemStyles = null

    // Switch active chart
    this.activeChartId = toId
    this.chart = this.charts[toId]

    if (!this.chart) return // chart not initialized yet (shouldn't happen with zoom: false on hidden charts)

    // Charts initialized in hidden tab panels can have a 0x0 canvas until explicitly resized.
    // Re-apply the chart config after the new panel becomes visible so ECharts can fully lay out.
    requestAnimationFrame(() => {
      const controller = this.chartControllers[toId]
      if (this.chart) this.chart.resize()
      if (controller?.chart) {
        controller.chart.setOption(controller.buildChartConfig(), true)
      }
      setTimeout(() => {
        if (this.chart) this.chart.resize()
      }, 0)
    })

    // Apply the same zoom to the new chart
    if (zoomState) {
      this.applyZoomState(zoomState)
    }

    if (!this.chartSetup[toId]) {
      // First visit — full setup including highlight series and column restore
      this.setup()
    } else {
      // Returning to a previously-set-up chart — re-attach listeners and restore column
      this.visibleData = this.getVisibleData()
      this.setupChartEventListeners()
      this.initializeColumnSelectionFromUrl()
    }
  }

  captureZoomState() {
    if (!this.chart) return null
    try {
      const option = this.chart.getOption()
      const dataZoom = option.dataZoom?.[1] || option.dataZoom?.[0]
      if (!dataZoom) return null
      return { startValue: dataZoom.startValue, endValue: dataZoom.endValue }
    } catch {
      return null
    }
  }

  applyZoomState(zoomState) {
    if (!this.chart || zoomState.startValue === undefined || zoomState.endValue === undefined) return
    try {
      this.chart.dispatchAction({ type: 'dataZoom', startValue: zoomState.startValue, endValue: zoomState.endValue })
      this.visibleData = this.getVisibleData()
    } catch { /* ignore */ }
  }

  teardownActiveChartListeners() {
    const container = this.getActiveChartContainer()
    if (container) {
      container.removeEventListener('mousedown', this.handleChartMouseDown)
      container.removeEventListener('mouseup', this.handleChartMouseUp)
    }
    try {
      if (this.chart) {
        this.chart.off('datazoom')
        if (this.zrClickHandler) this.chart.getZr().off('click', this.zrClickHandler)
        if (this.zrMouseMoveHandler) this.chart.getZr().off('mousemove', this.zrMouseMoveHandler)
      }
    } catch { /* chart may already be disposed */ }
    this.zrClickHandler = null
    this.zrMouseMoveHandler = null
  }

  getActiveChartContainer() {
    return this.chartTargets.find(el => el.dataset.chartId === this.activeChartId) || null
  }

  setup() {
    if (this.chartSetup[this.activeChartId]) {
      return; // Prevent multiple setups for the same chart
    }

    // We need both the chart container in DOM and the chart object
    const container = this.getActiveChartContainer()
    if (!container || !this.chart) {
      return;
    }

    this.visibleData = this.getVisibleData();

    // Add the dedicated background-highlight bar series before setting up listeners
    this.setupHighlightSeries();

    this.setupChartEventListeners();
    this.chartSetup[this.activeChartId] = true;

    // Mark the chart as fully rendered for testing
    document.getElementById(this.activeChartId)?.setAttribute('data-chart-rendered', 'true');

    // Initialize zoom and column selection from URL parameters after chart is fully ready
    // This must come AFTER storing the original option to avoid storing modified state
    this.initializeZoomFromUrl();
    this.initializeColumnSelectionFromUrl();
  }

  // Add some event listeners to the chart so we can track the zoom changes
  setupChartEventListeners() {
    const container = this.getActiveChartContainer()

    // When clicking on the chart, we want to store the current visible data so we can compare it later
    this.handleChartMouseDown = () => {
      this.visibleData = this.getVisibleData();
    };
    container.addEventListener('mousedown', this.handleChartMouseDown);

    // When releasing the mouse button, we want to check if the visible data has changed
    this.handleChartMouseUp = () => {
      this.handleZoomChange();
    };
    container.addEventListener('mouseup', this.handleChartMouseUp);

    // When the chart is zoomed, we want to check if the visible data has changed
    this.chart.on('datazoom', () => {
      this.handleZoomChange();
    });

    // Use ZRender (the underlying canvas renderer) to catch clicks anywhere in the
    // chart grid — not just on data point markers — then map the pixel position back
    // to the nearest x-axis bucket so any click in a column triggers filtering.
    this.zrClickHandler = (params) => {
      if (this.isClickOnDeploymentMarker(params)) return

      const dataIndex = this.getDataIndexFromPixel(params)
      if (dataIndex == null) return
      this.handleColumnClick({ dataIndex })
    }
    this.chart.getZr().on('click', this.zrClickHandler)

    // Show a pointer cursor when hovering over the clickable grid area.
    this.zrMouseMoveHandler = (params) => {
      const dataIndex = this.getDataIndexFromPixel(params)
      this.chart.getZr().setCursorStyle(dataIndex == null ? 'default' : 'pointer')
    }
    this.chart.getZr().on('mousemove', this.zrMouseMoveHandler)
  }

  getPrimaryDataSeries(option = this.chart?.getOption()) {
    return (option?.series || []).find(series =>
      series?.name !== this.highlightBarName &&
      series?.id !== this.deploymentMarkerSeriesId &&
      Array.isArray(series?.data) &&
      series.data.length > 0
    ) || null
  }

  getPrimaryDataSeriesIndex(option = this.chart?.getOption()) {
    return (option?.series || []).findIndex(series =>
      series?.name !== this.highlightBarName &&
      series?.id !== this.deploymentMarkerSeriesId &&
      Array.isArray(series?.data) &&
      series.data.length > 0
    )
  }

  getXAxisValues(option = this.chart?.getOption()) {
    const axisData = option?.xAxis?.[0]?.data
    if (Array.isArray(axisData) && axisData.length > 0) return axisData

    const series = this.getPrimaryDataSeries(option)
    if (!series) return []

    return series.data
      .map(point => {
        if (Array.isArray(point)) return point[0]
        if (Array.isArray(point?.value)) return point.value[0]
        return null
      })
      .filter(value => value !== null && value !== undefined)
  }

  getAxisType(option = this.chart?.getOption()) {
    return option?.xAxis?.[0]?.type || 'category'
  }

  getDataIndexFromPixel(params) {
    if (!this.chart) return null

    const option = this.chart.getOption()
    const axisType = this.getAxisType(option)
    const xAxisValues = this.getXAxisValues(option)
    const primarySeriesIndex = this.getPrimaryDataSeriesIndex(option)
    const pixel = [ params.offsetX, params.offsetY ]

    if (xAxisValues.length === 0) return null

    if (!this.chart.containPixel({ gridIndex: 0 }, pixel)) return null

    const gridCoord = this.chart.convertFromPixel({ gridIndex: 0 }, pixel)

    if (axisType === 'time') {
      let axisValue = Array.isArray(gridCoord) ? Number(gridCoord[0]) : Number(gridCoord)

      if (Number.isNaN(axisValue) && primarySeriesIndex >= 0) {
        const seriesCoord = this.chart.convertFromPixel({ seriesIndex: primarySeriesIndex }, pixel)
        axisValue = Array.isArray(seriesCoord) ? Number(seriesCoord[0]) : Number(seriesCoord)
      }

      if (Number.isNaN(axisValue)) return null

      let closestIndex = 0
      let closestDistance = Infinity
      xAxisValues.forEach((value, index) => {
        const distance = Math.abs(Number(value) - axisValue)
        if (distance < closestDistance) {
          closestDistance = distance
          closestIndex = index
        }
      })

      return closestIndex
    }

    const dataCoord = Array.isArray(gridCoord) ? gridCoord : this.chart.convertFromPixel(
      { seriesIndex: primarySeriesIndex >= 0 ? primarySeriesIndex : 0 },
      pixel
    )

    if (!dataCoord) return null

    const dataIndex = Math.round(dataCoord[0])
    if (dataIndex < 0 || dataIndex >= xAxisValues.length) return null

    return dataIndex
  }

  getTimeBucketRange(xAxisValues, index) {
    const current = Number(xAxisValues[index])
    const previous = index > 0 ? Number(xAxisValues[index - 1]) : null
    const next = index < xAxisValues.length - 1 ? Number(xAxisValues[index + 1]) : null

    const fallbackStep = previous != null ? current - previous : (next != null ? next - current : 3600000)
    const leftStep = previous != null ? current - previous : fallbackStep
    const rightStep = next != null ? next - current : fallbackStep

    return {
      start: current - (leftStep / 2),
      end: current + (rightStep / 2)
    }
  }

  isClickOnDeploymentMarker(params) {
    if (!this.chart) return false

    const option = this.chart.getOption()
    const markerSeries = (option?.series || []).find(series => series?.id === this.deploymentMarkerSeriesId)
    const markerData = markerSeries?.markLine?.data || []
    if (markerData.length === 0) return false

    const pixel = [ params.offsetX, params.offsetY ]
    if (!this.chart.containPixel({ gridIndex: 0 }, pixel)) return false

    const thresholdPx = 8
    return markerData.some(marker => {
      const x = this.chart.convertToPixel({ xAxisIndex: 0 }, marker.xAxis)
      const markerX = Array.isArray(x) ? x[0] : x
      return typeof markerX === 'number' && !Number.isNaN(markerX) && Math.abs(markerX - params.offsetX) <= thresholdPx
    })
  }

  // This returns the visible data from the chart based on the current zoom level.
  // The xAxis data and series data are sliced based on the start and end values of the dataZoom component.
  // The series data will contain the actual data points that are visible in the chart.
  getVisibleData() {
    try {
      const currentOption = this.chart.getOption();

      if (!currentOption.dataZoom || currentOption.dataZoom.length === 0) {
        return { xAxis: [], series: [] };
      }

      // Try to find the correct dataZoom component
      let dataZoom = currentOption.dataZoom[1] || currentOption.dataZoom[0];

      const xAxisData = this.getXAxisValues(currentOption);
      const primarySeries = this.getPrimaryDataSeries(currentOption);
      const seriesData = primarySeries?.data || [];

      if (xAxisData.length === 0 || seriesData.length === 0) {
        return { xAxis: [], series: [] };
      }

      if (this.getAxisType(currentOption) === 'time') {
        const startValue = dataZoom.startValue ?? xAxisData[0];
        const endValue = dataZoom.endValue ?? xAxisData[xAxisData.length - 1];

        return {
          xAxis: xAxisData.filter(value => value >= startValue && value <= endValue),
          series: seriesData.filter(point => {
            const xValue = Array.isArray(point) ? point[0] : point?.value?.[0]
            return xValue >= startValue && xValue <= endValue
          })
        };
      }

      // ?? not ||: index 0 is a valid category position, and `0 || fallback`
      // silently widens the range back to the full axis.
      const startValue = dataZoom.startValue ?? 0;
      const endValue = dataZoom.endValue ?? xAxisData.length - 1;

      return {
        xAxis: xAxisData.slice(startValue, endValue + 1),
        series: seriesData.slice(startValue, endValue + 1)
      };
    } catch {
      return { xAxis: [], series: [] };
    }
  }

  // When the zoom level changes, we want to check if the visible data has changed
  // If it has, we want to send a request to the server with the new visible data so
  // we can update the table with the new data that is visible in the chart.
  handleZoomChange() {
    const newVisibleData = this.getVisibleData();
    const newDataString = newVisibleData.xAxis.join();
    const currentDataString = this.visibleData.xAxis.join();

    if (newDataString !== currentDataString) {
      this.visibleData = newVisibleData;
      this.updateUrlWithZoomParams(newVisibleData);
      this.sendFrameRequest(newVisibleData);
    }
  }

  // Update the browser URL with zoom parameters so they persist on page refresh
  updateUrlWithZoomParams(data) {
    const url = new URL(window.location.href);
    const currentParams = new URLSearchParams(url.search);

    const startTimestamp = data.xAxis[0];
    const endTimestamp = data.xAxis[data.xAxis.length - 1];

    // Update zoom parameters in URL while preserving all other parameters including sort
    currentParams.set('zoom_start_time', startTimestamp);
    currentParams.set('zoom_end_time', endTimestamp);

    url.search = currentParams.toString();
    window.history.replaceState({}, '', url);
  }

  updatePaginationLimit() {
      // Update or set the limit param in the browser so if the user refreshes the page,
      // the limit will be preserved.
      if (!this.hasPaginationLimitTarget) return;

      const url = new URL(window.location.href);
      const currentParams = new URLSearchParams(url.search);
      const limit = this.paginationLimitTarget.value;
      currentParams.set('limit', limit);
      url.search = currentParams.toString();
      window.history.replaceState({}, '', url);
    }

  // Improved debouncing with guaranteed final request
  sendFrameRequest(data) {
    const now = Date.now();
    const timeSinceLastRequest = now - this.lastFrameRequestAt;

    // Store the latest data for potential delayed execution
    this.pendingRequestData = data;

    // Clear any existing timeout
    if (this.pendingRequestTimeout) {
      clearTimeout(this.pendingRequestTimeout);
    }

    // If enough time has passed since last request, execute immediately
    if (timeSinceLastRequest >= 1000) {
      this.executeFrameRequest(data);
    } else {
      // Otherwise, schedule execution for later to ensure final request goes through
      const remainingTime = 1000 - timeSinceLastRequest;
      this.pendingRequestTimeout = setTimeout(() => {
        this.executeFrameRequest(this.pendingRequestData);
        this.pendingRequestTimeout = null;
      }, remainingTime);
    }
  }

  // Execute the actual AJAX request
  executeFrameRequest(data) {
    this.lastFrameRequestAt = Date.now();

    // Start with the current page's URL to preserve all existing parameters including sort
    const url = new URL(window.location.href);

    // Preserve existing URL parameters (including sort parameters like q[s])
    const currentParams = new URLSearchParams(url.search);

    const startTimestamp = data.xAxis[0];
    const endTimestamp = data.xAxis[data.xAxis.length - 1];

    // Add or update the zoom occurred_at parameters for table filtering
    currentParams.set('zoom_start_time', startTimestamp);
    currentParams.set('zoom_end_time', endTimestamp);

    // Set the limit param based on the value in the pagination selector
    if (this.hasPaginationLimitTarget) {
      currentParams.set('limit', this.paginationLimitTarget.value);
    }

    // Update the URL's search parameters
    url.search = currentParams.toString();

    // Fetch and replace the index table
    this.loadTable(url);
  }

  handleColumnClick(params) {
    const clickedIndex = params.dataIndex;

    // If clicking the same column that's already selected, deselect all
    if (this.selectedColumnIndex === clickedIndex) {
      this.resetColumnColors();
      this.selectedColumnIndex = null;
      this.sendColumnDeselectionRequest();
    } else {
      // Select the clicked column and gray out others
      this.highlightColumn(clickedIndex);
      this.selectedColumnIndex = clickedIndex;
      this.sendColumnSelectionRequest(clickedIndex);
    }
  }

  // Add a bar series on a hidden secondary y-axis (range 0–1) to use as a column
  // background highlight. markArea on a category axis with timestamp data is
  // unreliable — it looks up values rather than treating integers as indices, so a
  // dedicated bar series is the only dependable approach.
  setupHighlightSeries() {
    try {
      const option = this.chart.getOption()

      // Bar charts don't use the highlight overlay series — adding a second bar series
      // causes ECharts to shrink all bars. Bar charts have inherent column distinction.
      const primaryType = option.series?.[0]?.type
      if (primaryType === 'bar') return

      const axisType = option.xAxis?.[0]?.type
      if (axisType === 'time') {
        this.chart.setOption({
          series: [
            ...(option.series || []),
            {
              name: this.highlightBarName,
              type: 'line',
              data: [],
              showSymbol: false,
              silent: true,
              z: 0,
              animation: false,
              legendHoverLink: false,
              lineStyle: { opacity: 0 },
              itemStyle: { opacity: 0 },
              tooltip: { show: false },
              markArea: {
                silent: true,
                itemStyle: { color: 'rgba(128, 128, 128, 0.2)' },
                data: []
              }
            }
          ]
        })
        return
      }

      const xAxisLength = option.xAxis?.[0]?.data?.length || 0
      const existingYAxes = Array.isArray(option.yAxis) ? option.yAxis : [option.yAxis || {}]

      this.chart.setOption({
        yAxis: [
          ...existingYAxes,
          // Hidden secondary axis: bar value of 1 = full chart height
          { show: false, position: 'right', min: 0, max: 1 }
        ],
        series: [
          ...(option.series || []),
          {
            name: this.highlightBarName,
            type: 'bar',
            yAxisIndex: existingYAxes.length,
            barWidth: '100%',
            itemStyle: { color: 'rgba(0, 0, 0, 0)', borderWidth: 0 },
            data: Array(xAxisLength).fill(null),
            silent: true,
            z: 0,
            animation: false,
            legendHoverLink: false,
            tooltip: { show: false }
          }
        ]
      })
    } catch (error) {
      console.error('Error setting up highlight series:', error)
    }
  }

  highlightColumn(selectedIndex) {
    try {
      const option = this.chart.getOption()
      const xAxisValues = this.getXAxisValues(option)
      if (!xAxisValues.length || selectedIndex < 0 || selectedIndex >= xAxisValues.length) return

      const isPrimaryBar = option.series?.[0]?.type === 'bar'

      if (this.getAxisType(option) === 'time' && !isPrimaryBar) {
        const range = this.getTimeBucketRange(xAxisValues, selectedIndex)

        this.chart.setOption({
          series: option.series.map(s =>
            s.name === this.highlightBarName
              ? {
                markArea: {
                  silent: true,
                  itemStyle: { color: 'rgba(128, 128, 128, 0.2)' },
                  data: [[ { xAxis: range.start }, { xAxis: range.end } ]]
                }
              }
              : {}
          )
        })
        return
      }

      const xAxisLength = option.xAxis?.[0]?.data?.length

      if (isPrimaryBar) {
        // Cache original item styles before first modification so we can restore colors on reset
        if (!this.originalBarItemStyles) {
          const seriesData = option.series?.[0]?.data || []
          this.originalBarItemStyles = seriesData.map(val =>
            typeof val === 'object' ? (val.itemStyle || {}) : {}
          )
        }

        // For bar charts: dim non-selected bars by updating per-bar itemStyle opacity
        this.chart.setOption({
          series: option.series.slice(0, 1).map(s => ({
            data: (s.data || []).map((val, i) => ({
              value: (val && typeof val === 'object' && !Array.isArray(val)) ? val.value : val,
              itemStyle: { ...(this.originalBarItemStyles[i] || {}), opacity: i === selectedIndex ? 1 : 0.25 }
            }))
          }))
        })
      } else {
        // For line charts: use the hidden background bar series
        const barData = Array(xAxisLength).fill(null)
        barData[selectedIndex] = 1

        this.chart.setOption({
          series: option.series.map(s =>
            s.name === this.highlightBarName
              ? { itemStyle: { color: 'rgba(128, 128, 128, 0.2)', borderWidth: 0 }, data: barData }
              : {}
          )
        })
      }
    } catch (error) {
      console.error('Error highlighting column:', error)
    }
  }

  resetColumnColors() {
    try {
      const option = this.chart.getOption()
      const xAxisLength = option.xAxis?.[0]?.data?.length || 0
      const isPrimaryBar = option.series?.[0]?.type === 'bar'

      if (this.getAxisType(option) === 'time' && !isPrimaryBar) {
        this.chart.setOption({
          series: option.series.map(s =>
            s.name === this.highlightBarName
              ? { markArea: { data: [] } }
              : {}
          )
        })
        return
      }

      if (isPrimaryBar) {
        // Restore full opacity on all bars, preserving original per-bar colors
        const originalStyles = this.originalBarItemStyles || []
        this.originalBarItemStyles = null
        this.chart.setOption({
          series: option.series.slice(0, 1).map(s => ({
            data: (s.data || []).map((val, i) => ({
              value: (val && typeof val === 'object' && !Array.isArray(val)) ? val.value : val,
              itemStyle: { ...(originalStyles[i] || {}), opacity: 1 }
            }))
          }))
        })
      } else {
        this.chart.setOption({
          series: option.series.map(s =>
            s.name === this.highlightBarName
              ? { itemStyle: { color: 'rgba(0, 0, 0, 0)', borderWidth: 0 }, data: Array(xAxisLength).fill(null) }
              : {}
          )
        })
      }
    } catch (error) {
      console.error('Error resetting column highlight:', error)
    }
  }

  sendColumnSelectionRequest(columnIndex) {
    // Get the timestamp for the selected column
    const option = this.chart.getOption();
    const xAxisData = this.getXAxisValues(option);
    const selectedTimestamp = xAxisData[columnIndex];

    if (!selectedTimestamp) {
      console.error('Could not find timestamp for column index:', columnIndex);
      return;
    }

    // Build the request URL with column selection parameter, preserving all existing params including sort
    const url = new URL(window.location.href);
    const currentParams = new URLSearchParams(url.search);

    // Keep all existing parameters (including sort like q[s]) and add column selection parameter
    currentParams.set('selected_column_time', selectedTimestamp);

    // Preserve pagination limit
    if (this.hasPaginationLimitTarget) {
      currentParams.set('limit', this.paginationLimitTarget.value);
    }

    url.search = currentParams.toString();

    // Update browser URL to persist column selection
    window.history.replaceState({}, '', url);

    // Send the partial request
    this.loadTable(url);
  }

  sendColumnDeselectionRequest() {
    // Build the request URL without column selection parameter, preserving all other params including sort
    const url = new URL(window.location.href);
    const currentParams = new URLSearchParams(url.search);

    // Remove only the column selection parameter, keep all others (including sort like q[s])
    currentParams.delete('selected_column_time');

    // Preserve pagination limit
    if (this.hasPaginationLimitTarget) {
      currentParams.set('limit', this.paginationLimitTarget.value);
    }

    url.search = currentParams.toString();

    // Update browser URL to remove column selection
    window.history.replaceState({}, '', url);

    // Send the partial request to restore default/zoom view
    this.loadTable(url);
  }

  loadTable(url) {
    return loadInto(url.toString(), this.indexTableTarget, { errorMessage: 'Could not load the table.' });
  }

  initializeZoomFromUrl() {
    const urlParams = new URLSearchParams(window.location.search)
    const zoomStartTime = urlParams.get('zoom_start_time')
    const zoomEndTime = urlParams.get('zoom_end_time')
    if (!zoomStartTime || !zoomEndTime) return

    const option = this.chart.getOption()
    const xAxisData = this.getXAxisValues(option)
    if (xAxisData.length === 0) return

    const startMs = parseInt(zoomStartTime)
    const endMs = parseInt(zoomEndTime)

    if (this.getAxisType(option) === 'time') {
      this.chart.dispatchAction({ type: 'dataZoom', startValue: startMs, endValue: endMs })
    } else {
      const startIndex = xAxisData.reduce((best, ts, i) =>
        Math.abs(parseInt(ts) - startMs) < Math.abs(parseInt(xAxisData[best]) - startMs) ? i : best, 0)
      const endIndex = xAxisData.reduce((best, ts, i) =>
        Math.abs(parseInt(ts) - endMs) < Math.abs(parseInt(xAxisData[best]) - endMs) ? i : best, 0)

      this.chart.dispatchAction({ type: 'dataZoom', startValue: startIndex, endValue: endIndex })
    }
    this.visibleData = this.getVisibleData()
  }

  initializeColumnSelectionFromUrl() {
    // Check if there's a selected_column_time parameter in the URL
    const urlParams = new URLSearchParams(window.location.search);
    const selectedColumnTime = urlParams.get('selected_column_time');

    if (selectedColumnTime) {
      // Find the column index that matches this timestamp
      const option = this.chart.getOption();
      const xAxisData = this.getXAxisValues(option);
      if (xAxisData.length === 0) {
        return;
      }

      // Try exact match first
      let columnIndex = xAxisData.findIndex(timestamp => timestamp.toString() === selectedColumnTime);

      // If no exact match, try converting to numbers and comparing
      if (columnIndex === -1) {
        const selectedTimeNumber = parseInt(selectedColumnTime);
        columnIndex = xAxisData.findIndex(timestamp => parseInt(timestamp) === selectedTimeNumber);
      }

      if (columnIndex !== -1) {
        // Set the selected column index and apply visual styling
        this.selectedColumnIndex = columnIndex;
        // Use requestAnimationFrame to ensure ECharts is ready
        requestAnimationFrame(() => {
          this.highlightColumn(columnIndex);
        });
      }
    }
  }
}
