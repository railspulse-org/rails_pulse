import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import IndexController from '../../../app/javascript/rails_pulse/controllers/index_controller'
import TableSortController from '../../../app/javascript/rails_pulse/controllers/table_sort_controller'
import { mountController, controllableFetch, nextTick } from '../setup'

const CHART_ID = 'response_time_chart'

function buildHTML() {
  return `
    <div data-controller="index" data-index-chart-id-value="${CHART_ID}">
      <div data-index-target="chart" data-chart-id="${CHART_ID}"></div>
      <div id="index_table" data-index-target="indexTable"></div>
    </div>
  `
}

// Minimal stand-in for an ECharts instance: setupChartEventListeners only needs
// on() and a ZRender handle.
function buildChartStub() {
  const zr = { on: vi.fn(), off: vi.fn(), setCursorStyle: vi.fn() }
  return { on: vi.fn(), off: vi.fn(), getZr: () => zr, getOption: () => ({}) }
}

function countListeners(spy, type) {
  return spy.mock.calls.filter(([ eventType ]) => eventType === type).length
}

describe('IndexController', () => {
  let teardown

  afterEach(() => {
    teardown?.()
    vi.restoreAllMocks()
  })

  // # document-level mouseup listener lifecycle

  it('registers exactly one document mouseup listener on connect', async () => {
    const addSpy = vi.spyOn(document, 'addEventListener')
    ;({ teardown } = await mountController('index', IndexController, buildHTML()))

    expect(countListeners(addSpy, 'mouseup')).toBe(1)
  })

  it('does not stack document mouseup listeners when chart listeners are re-attached', async () => {
    const addSpy = vi.spyOn(document, 'addEventListener')
    const { app, element, teardown: t } = await mountController('index', IndexController, buildHTML())
    teardown = t

    const controller = app.getControllerForElementAndIdentifier(element, 'index')
    controller.chart = buildChartStub()

    // setupChartEventListeners runs again on every chart switch. It used to add a
    // fresh document mouseup listener each time, so every click anywhere on the
    // page re-ran handleZoomChange once per switch.
    controller.setupChartEventListeners()
    controller.setupChartEventListeners()
    controller.setupChartEventListeners()

    expect(countListeners(addSpy, 'mouseup')).toBe(1)
  })

  it('removes the document mouseup listener on disconnect', async () => {
    const removeSpy = vi.spyOn(document, 'removeEventListener')
    const { teardown: t } = await mountController('index', IndexController, buildHTML())
    teardown = t

    // Detaching the element lets Stimulus' MutationObserver run disconnect().
    document.body.innerHTML = ''
    await nextTick()

    expect(countListeners(removeSpy, 'mouseup')).toBe(1)
  })

  it('ignores document mouseup before a chart has rendered', async () => {
    const { app, element, teardown: t } = await mountController('index', IndexController, buildHTML())
    teardown = t

    const controller = app.getControllerForElementAndIdentifier(element, 'index')
    const handleZoomChange = vi.spyOn(controller, 'handleZoomChange')

    document.dispatchEvent(new window.MouseEvent('mouseup'))

    expect(handleZoomChange).not.toHaveBeenCalled()
  })
})

// The index chart and the sort headers both load into the same #index_table
const SHARED_TABLE_HTML = `
  <div data-controller="index" data-index-chart-id-value="${CHART_ID}">
    <div data-index-target="chart" data-chart-id="${CHART_ID}"></div>
    <div data-controller="table-sort">
      <div id="index_table" data-index-target="indexTable" data-table-sort-target="tableFrame"><p>Old rows</p></div>
      <a id="by-method" href="/routes?q[s]=method">Method</a>
    </div>
  </div>
`

function tableHtml(label) {
  return `<div id="index_table"><p>${label} rows</p></div>`
}

describe('IndexController table fetches', () => {
  let app, element, teardown, pending

  beforeEach(async () => {
    vi.spyOn(window.history, 'replaceState').mockImplementation(() => {})
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchControl = controllableFetch()
    pending = fetchControl.pending
    vi.stubGlobal('fetch', fetchControl.fetchMock)
    ;({ app, element, teardown } = await mountController('index', IndexController, SHARED_TABLE_HTML))
    app.register('table-sort', TableSortController)
    await nextTick()
  })

  afterEach(() => {
    teardown()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function ctrl() {
    return app.getControllerForElementAndIdentifier(element, 'index')
  }

  function sortCtrl() {
    return app.getControllerForElementAndIdentifier(element.querySelector('[data-controller="table-sort"]'), 'table-sort')
  }

  function table() {
    return element.querySelector('#index_table')
  }

  function lastFetchedUrl() {
    return fetch.mock.calls.at(-1)[0]
  }

  // # Zoom

  it('loads the zoomed range into the table', async () => {
    ctrl().executeFrameRequest({ xAxis: [ 1000, 2000, 3000 ] })

    const url = new URL(lastFetchedUrl())
    expect(url.searchParams.get('zoom_start_time')).toBe('1000')
    expect(url.searchParams.get('zoom_end_time')).toBe('3000')
    expect(table().getAttribute('aria-busy')).toBe('true')

    pending[lastFetchedUrl()].respond(tableHtml('Zoomed'))
    await nextTick()
    expect(table().textContent).toBe('Zoomed rows')
  })

  it('shows an error notice when the zoom fetch fails', async () => {
    ctrl().executeFrameRequest({ xAxis: [ 1000, 3000 ] })
    pending[lastFetchedUrl()].respond('Server error', 500)
    await nextTick()

    const notice = table().querySelector('[role="alert"]')
    expect(notice.textContent).toContain('Could not load the table.')
    expect(table().textContent).not.toContain('Old rows')
  })

  // # Column selection

  it('loads the selected column into the table', async () => {
    ctrl().chart = { getOption: () => ({ xAxis: [ { data: [ 1000, 2000 ] } ] }) }
    ctrl().sendColumnSelectionRequest(1)

    expect(new URL(lastFetchedUrl()).searchParams.get('selected_column_time')).toBe('2000')
    pending[lastFetchedUrl()].respond(tableHtml('Column'))
    await nextTick()
    expect(table().textContent).toBe('Column rows')
  })

  it('shows an error notice when the column deselection fetch fails', async () => {
    ctrl().sendColumnDeselectionRequest()

    expect(new URL(lastFetchedUrl()).searchParams.has('selected_column_time')).toBe(false)
    pending[lastFetchedUrl()].respond('Server error', 500)
    await nextTick()
    expect(table().querySelector('[role="alert"]').textContent).toContain('Could not load the table.')
  })

  // # Edge Cases

  it('keeps a newer sort when an older zoom response arrives last', async () => {
    ctrl().executeFrameRequest({ xAxis: [ 1000, 3000 ] })
    const zoomUrl = lastFetchedUrl()
    sortCtrl().updateUrl({ preventDefault: vi.fn(), currentTarget: element.querySelector('#by-method') })

    pending['/routes?q[s]=method'].respond(tableHtml('Method'))
    await nextTick()
    pending[zoomUrl].respond(tableHtml('Zoomed'))
    await nextTick()

    expect(table().textContent).toBe('Method rows')
    expect(console.error).not.toHaveBeenCalled()
  })

  it('keeps a newer zoom when an older sort response arrives last', async () => {
    sortCtrl().updateUrl({ preventDefault: vi.fn(), currentTarget: element.querySelector('#by-method') })
    ctrl().executeFrameRequest({ xAxis: [ 1000, 3000 ] })

    pending[lastFetchedUrl()].respond(tableHtml('Zoomed'))
    await nextTick()
    pending['/routes?q[s]=method'].respond(tableHtml('Method'))
    await nextTick()

    expect(table().textContent).toBe('Zoomed rows')
  })
})
