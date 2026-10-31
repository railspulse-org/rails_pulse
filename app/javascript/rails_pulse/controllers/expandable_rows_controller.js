import { Controller } from "@hotwired/stimulus"
import { loadInto } from "../utils/fetch_helpers"

export default class extends Controller {
  toggle(event) {
    // Delegate clicks from tbody to the nearest row
    const triggerRow = event.target.closest('tr')
    if (!triggerRow || triggerRow.closest('tbody') !== this.element) return

    // Ignore clicks on the details row itself
    if (triggerRow.classList.contains('operation-details-row')) return

    // Do not toggle when clicking the final Actions column
    const clickedCell = event.target.closest('td,th')
    if (clickedCell && clickedCell.parentElement === triggerRow) {
      const isLastCell = clickedCell.cellIndex === (triggerRow.cells.length - 1)
      if (isLastCell) return
    }

    event.preventDefault()
    event.stopPropagation()

    const detailsRow = triggerRow.nextElementSibling
    if (!detailsRow || detailsRow.tagName !== 'TR' || !detailsRow.classList.contains('operation-details-row')) return

    const isHidden = detailsRow.classList.contains('hidden')
    if (isHidden) {
      this.expand(triggerRow, detailsRow)
    } else {
      this.collapse(triggerRow, detailsRow)
    }
  }

  expand(triggerRow, detailsRow) {
    detailsRow.classList.remove('hidden')

    // Rotate chevron to point down
    const chevron = triggerRow.querySelector('.chevron')
    if (chevron) chevron.style.transform = 'rotate(90deg)'

    triggerRow.classList.add('expanded')

    // Lazy load operation details once
    const targetDiv = detailsRow.querySelector('[data-operation-url]')
    if (targetDiv && !targetDiv.dataset.loaded) {
      const url = targetDiv.dataset.operationUrl
      if (url) this.loadOperationDetails(url, targetDiv)
    }
  }

  async loadOperationDetails(url, targetDiv) {
    if (targetDiv.getAttribute('aria-busy') === 'true') return

    if (!targetDiv.firstElementChild) {
      const loading = document.createElement('p')
      loading.className = 'text-subtle'
      loading.textContent = 'Loading operation details…'
      targetDiv.appendChild(loading)
    }

    const loaded = await loadInto(url, targetDiv, { errorMessage: 'Could not load operation details.' })
    if (loaded) targetDiv.dataset.loaded = 'true'
  }

  collapse(triggerRow, detailsRow) {
    detailsRow.classList.add('hidden')

    const chevron = triggerRow.querySelector('.chevron')
    if (chevron) chevron.style.transform = 'rotate(0deg)'

    triggerRow.classList.remove('expanded')
  }
}
