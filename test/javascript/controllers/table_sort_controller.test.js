import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import TableSortController from '../../../app/javascript/rails_pulse/controllers/table_sort_controller'
import { mountController } from '../setup'

const HTML = `
  <div data-controller="table-sort">
    <div id="index_table" data-table-sort-target="tableFrame"><p>Old rows</p></div>
    <a id="by-path" href="/routes?q[s]=path" data-action="click->table-sort#updateUrl">Path</a>
    <a id="by-method" href="/routes?q[s]=method" data-action="click->table-sort#updateUrl">Method</a>
    <a data-action="click->table-sort#updateUrl">No href</a>
  </div>
`

// A fetch whose responses resolve only when the test says so, and which rejects
// with an AbortError when its signal is aborted, as the browser's fetch does.
function controllableFetch() {
  const pending = {}
  const fetchMock = vi.fn((url, { signal } = {}) => new Promise((resolve, reject) => {
    pending[url] = {
      respond(body, status = 200) {
        resolve({ ok: status < 400, status, text: () => Promise.resolve(body) })
      },
    }
    signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
  }))
  return { fetchMock, pending }
}

function tableHtml(label) {
  return `<div id="index_table"><p>${label} rows</p></div>`
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

describe('TableSortController', () => {
  let app, element, teardown, pending

  beforeEach(async () => {
    vi.spyOn(window.history, 'replaceState').mockImplementation(() => {})
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchControl = controllableFetch()
    pending = fetchControl.pending
    vi.stubGlobal('fetch', fetchControl.fetchMock)
    ;({ app, element, teardown } = await mountController('table-sort', TableSortController, HTML))
  })

  afterEach(() => {
    teardown()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function ctrl() {
    return app.getControllerForElementAndIdentifier(element, 'table-sort')
  }

  function click(selector) {
    ctrl().updateUrl({ preventDefault: vi.fn(), currentTarget: element.querySelector(selector) })
  }

  function table() {
    return element.querySelector('#index_table')
  }

  // # updateUrl

  it('updates the browser URL via history.replaceState', () => {
    click('#by-path')
    expect(window.history.replaceState).toHaveBeenCalledWith({}, '', '/routes?q[s]=path')
  })

  it('fetches the sorted table and replaces the frame', async () => {
    click('#by-path')
    pending['/routes?q[s]=path'].respond(tableHtml('Path'))
    await flush()
    expect(table().textContent).toBe('Path rows')
    expect(table().hasAttribute('aria-busy')).toBe(false)
  })

  it('marks the table busy while the fetch is in flight', () => {
    click('#by-path')
    expect(table().getAttribute('aria-busy')).toBe('true')
  })

  it('does nothing when the link has no href', () => {
    click('a:not([href])')
    expect(window.history.replaceState).not.toHaveBeenCalled()
    expect(fetch).not.toHaveBeenCalled()
  })

  it('prevents default on the event', () => {
    const preventDefault = vi.fn()
    ctrl().updateUrl({ preventDefault, currentTarget: element.querySelector('#by-path') })
    expect(preventDefault).toHaveBeenCalledOnce()
  })

  // # Edge Cases

  it('keeps the newest sort when an older response arrives last', async () => {
    click('#by-path')
    click('#by-method')

    pending['/routes?q[s]=method'].respond(tableHtml('Method'))
    await flush()
    pending['/routes?q[s]=path'].respond(tableHtml('Path'))
    await flush()

    expect(table().textContent).toBe('Method rows')
    expect(console.error).not.toHaveBeenCalled()
  })

  it('replaces the old rows with an error notice when the fetch fails', async () => {
    click('#by-path')
    pending['/routes?q[s]=path'].respond('Server error', 500)
    await flush()

    const notice = table().querySelector('[role="alert"]')
    expect(notice).not.toBeNull()
    expect(notice.textContent).toContain('Could not load the table.')
    expect(table().textContent).not.toContain('Old rows')
    expect(table().hasAttribute('aria-busy')).toBe(false)
  })

  it('retries the failed fetch from the error notice', async () => {
    click('#by-path')
    pending['/routes?q[s]=path'].respond('Server error', 500)
    await flush()

    table().querySelector('[role="alert"] button').click()
    pending['/routes?q[s]=path'].respond(tableHtml('Path'))
    await flush()

    expect(fetch).toHaveBeenCalledTimes(2)
    expect(table().textContent).toBe('Path rows')
  })
})
