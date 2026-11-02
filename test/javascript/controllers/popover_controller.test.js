import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import PopoverController from '../../../app/javascript/rails_pulse/controllers/popover_controller'
import { mountController, controllableFetch, nextTick } from '../setup'

vi.mock('@floating-ui/dom', () => ({
  autoUpdate: vi.fn(() => vi.fn()),
  computePosition: vi.fn(() => Promise.resolve({ x: 0, y: 0 })),
  flip: vi.fn(),
  shift: vi.fn(),
  offset: vi.fn(),
}))

const HTML = `
  <div data-controller="popover">
    <button data-popover-target="button">Details</button>
    <div data-popover-target="menu" data-operation-url="/operations/1">
      <div id="operation_1_details" data-operation-url="/operations/1">
        <p>Loading operation details…</p>
      </div>
    </div>
  </div>
`

describe('PopoverController', () => {
  let app, element, teardown, pending

  beforeEach(async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchControl = controllableFetch()
    pending = fetchControl.pending
    vi.stubGlobal('fetch', fetchControl.fetchMock)
    ;({ app, element, teardown } = await mountController('popover', PopoverController, HTML))
  })

  afterEach(() => {
    teardown()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function ctrl() {
    return app.getControllerForElementAndIdentifier(element, 'popover')
  }

  function details() {
    return document.getElementById('operation_1_details')
  }

  // # loadOperationDetailsIfNeeded

  it('loads operation details into the popover', async () => {
    ctrl().loadOperationDetailsIfNeeded()
    expect(details().getAttribute('aria-busy')).toBe('true')

    pending['/operations/1'].respond('<div id="operation_1_details"><p>SELECT 1</p></div>')
    await nextTick()
    expect(details().textContent).toBe('SELECT 1')
    expect(details().dataset.loaded).toBe('true')
  })

  // # Edge Cases

  it('shows an error notice when the details fail to load', async () => {
    ctrl().loadOperationDetailsIfNeeded()
    pending['/operations/1'].respond('Server error', 500)
    await nextTick()

    expect(details().querySelector('[role="alert"]').textContent).toContain('Could not load operation details.')
    expect(details().dataset.loaded).toBeUndefined()
  })

  it('sends one request when opened again while loading', () => {
    ctrl().loadOperationDetailsIfNeeded()
    ctrl().loadOperationDetailsIfNeeded()
    expect(fetch).toHaveBeenCalledOnce()
  })
})
