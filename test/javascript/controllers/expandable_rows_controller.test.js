import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import ExpandableRowsController from '../../../app/javascript/rails_pulse/controllers/expandable_rows_controller'
import { mountController } from '../setup'

const HTML = `
  <table>
    <tbody data-controller="expandable-rows" data-action="click->expandable-rows#toggle">
      <tr id="trigger"><td>sql</td><td>Actions</td></tr>
      <tr class="operation-details-row hidden">
        <td colspan="2">
          <div id="operation_1_details" data-operation-url="/operations/1"></div>
        </td>
      </tr>
    </tbody>
  </table>
`

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

describe('ExpandableRowsController', () => {
  let teardown, respond

  beforeEach(async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.stubGlobal('fetch', vi.fn(() => new Promise(resolve => {
      respond = (body, status = 200) =>
        resolve({ ok: status < 400, status, text: () => Promise.resolve(body) })
    })))
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

  function expand() {
    document.querySelector('#trigger td').click()
  }

  // # Structure Tests

  it('shows a loading message while the details load', () => {
    expand()
    expect(details().textContent).toContain('Loading operation details')
    expect(details().getAttribute('aria-busy')).toBe('true')
  })

  it('replaces the loading message with the fetched details', async () => {
    expand()
    respond('<div id="operation_1_details"><p>SELECT 1</p></div>')
    await flush()
    expect(details().textContent).toBe('SELECT 1')
    expect(details().dataset.loaded).toBe('true')
  })

  // # Edge Cases

  it('shows an error notice when the details fail to load', async () => {
    expand()
    respond('Server error', 500)
    await flush()

    const notice = details().querySelector('[role="alert"]')
    expect(notice.textContent).toContain('Could not load operation details.')
    expect(details().dataset.loaded).toBeUndefined()
  })
})
