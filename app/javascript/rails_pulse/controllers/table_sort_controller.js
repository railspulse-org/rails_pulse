import { Controller } from "@hotwired/stimulus"
import { loadInto } from "../utils/fetch_helpers"

export default class extends Controller {
  static targets = ["tableFrame"]

  updateUrl(event) {
    event.preventDefault()
    const link = event.currentTarget
    const href = link.getAttribute('href')

    if (href) {
      window.history.replaceState({}, '', href)
      this.fetchAndUpdateTable(href)
    }
  }

  fetchAndUpdateTable(url) {
    return loadInto(url, this.tableFrameTarget, { errorMessage: 'Could not load the table.' })
  }
}
