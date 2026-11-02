import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import ExpandableRowsController from '../../../app/javascript/rails_pulse/controllers/expandable_rows_controller'
import { mountController, controllableFetch, nextTick } from '../setup'

const HTML = `
  <table>
    <tbody data-controller="expandable-rows" data-action="click->expandable-rows#toggle">
      <tr id="trigger"><td>sql</td><td>Actions</td></tr>
      <tr class="operation-details-row hidden">
        <td colspan="2">
          <div id="operation_1_details" data-operation-url="/operations/1">
            <p>Loading operation details…</p>
          </div>
        </td>
      </tr>
    </tbody>
  </table>
`

describe('ExpandableRowsController', () => {
  let teardown, pending

  beforeEach(async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchControl = controllableFetch()
    pending = fetchControl.pending
    vi.stubGlobal('fetch', fetchControl.fetchMock)
    ;({ teardown } = await mountController('expandable-rows', ExpandableRowsController, HTML))
  })

  afterEach(() => {
    teardown()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function details() {
    return document.getElementById('operation_1_details')
  }

  function toggle() {
    document.querySelector('#trigger td').click()
  }

  // # Structure Tests

  it('marks the details busy while they load', () => {
    toggle()
    expect(details().getAttribute('aria-busy')).toBe('true')
  })

  it('replaces the loading message with the fetched details', async () => {
    toggle()
    pending['/operations/1'].respond('<div id="operation_1_details"><p>SELECT 1</p></div>')
    await nextTick()
    expect(details().textContent).toBe('SELECT 1')
    expect(details().dataset.loaded).toBe('true')
  })

  // # Edge Cases

  it('shows an error notice when the details fail to load', async () => {
    toggle()
    pending['/operations/1'].respond('Server error', 500)
    await nextTick()

    const notice = details().querySelector('[role="alert"]')
    expect(notice.textContent).toContain('Could not load operation details.')
    expect(details().dataset.loaded).toBeUndefined()
  })

  it('does not restart the load when the row is reopened mid-load', async () => {
    toggle()
    toggle()
    toggle()
    pending['/operations/1'].respond('<div id="operation_1_details"><p>SELECT 1</p></div>')
    await nextTick()

    expect(fetch).toHaveBeenCalledOnce()
    expect(details().textContent).toBe('SELECT 1')
  })
})
