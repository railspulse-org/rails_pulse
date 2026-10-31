/**
 * Shared utilities for fetching partial HTML and replacing DOM content
 * Used across Rails Pulse controllers for in-place updates without full page reloads
 */

/**
 * Get CSRF token from meta tag
 * @returns {string|null} - CSRF token or null
 */
function getCsrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]')
  return meta ? meta.content : null
}

/**
 * Fetch HTML from a URL with partial request headers
 * @param {string} url - The URL to fetch
 * @param {Object} options - Additional fetch options (merged with defaults)
 * @returns {Promise<Document>} - Parsed HTML document
 */
export async function fetchPartial(url, options = {}) {
  const { headers, ...fetchOptions } = options
  const defaultHeaders = {
    'Accept': 'text/html',
    'X-Partial-Request': 'true',
    'X-Requested-With': 'XMLHttpRequest'
  }

  // Add CSRF token for non-GET requests
  const method = options.method || 'GET'
  if (method !== 'GET') {
    const csrfToken = getCsrfToken()
    if (csrfToken) {
      defaultHeaders['X-CSRF-Token'] = csrfToken
    }
  }

  const response = await fetch(url, {
    ...fetchOptions,
    method: method,
    headers: { ...defaultHeaders, ...headers }
  })

  if (!response.ok) {
    throw new Error(`HTTP error! status: ${response.status}`)
  }

  const html = await response.text()
  const parser = new DOMParser()
  return parser.parseFromString(html, 'text/html')
}

/**
 * Replace the content of a target element with content from a source element
 * Uses safe DOM methods (no innerHTML) for CSP compliance
 * @param {HTMLElement} targetElement - Element to update
 * @param {HTMLElement} sourceElement - Element containing new content
 */
export function replaceElement(targetElement, sourceElement) {
  clearElement(targetElement)

  // Clone and append new content
  Array.from(sourceElement.childNodes).forEach(child => {
    targetElement.appendChild(child.cloneNode(true))
  })
}

// In-flight request per target element, so a newer fetch for the same element
// cancels the older one and a slow response can never overwrite a newer one.
const inFlight = new WeakMap()

/**
 * True when a fetch was cancelled because a newer one for the same element started
 * @param {Error} error
 * @returns {boolean}
 */
export function isAbortError(error) {
  return error?.name === 'AbortError'
}

/**
 * Fetch HTML and replace a target element's content in one operation.
 * Starting a new fetch for the same element aborts the previous one, which then
 * rejects with an AbortError (see isAbortError). While loading, the element
 * carries aria-busy="true".
 * @param {string} url - The URL to fetch
 * @param {HTMLElement} targetElement - Element to update
 * @param {Object} options - Additional fetch options
 * @param {string} options.selector - CSS selector to find content in response (defaults to targetElement.id)
 * @returns {Promise<boolean>} - True if content was replaced, false if selector not found in response
 */
export async function fetchAndReplace(url, targetElement, options = {}) {
  inFlight.get(targetElement)?.abort()
  const controller = new AbortController()
  inFlight.set(targetElement, controller)
  targetElement.setAttribute('aria-busy', 'true')

  try {
    const doc = await fetchPartial(url, { ...options, signal: controller.signal })
    // A response can still settle after abort() if the body was already read
    if (controller.signal.aborted) throw supersededError()

    // Use provided selector or default to target element's ID
    const selector = options.selector || `#${targetElement.id}`
    const sourceElement = doc.querySelector(selector)

    if (sourceElement) {
      replaceElement(targetElement, sourceElement)
      return true
    }

    // No matching content in response - clear the target
    clearElement(targetElement)
    return false
  } finally {
    if (inFlight.get(targetElement) === controller) {
      inFlight.delete(targetElement)
      targetElement.removeAttribute('aria-busy')
    }
  }
}

/**
 * Fetch and replace, showing an error notice with a Retry button in the target
 * when the fetch fails. A fetch superseded by a newer one is ignored silently.
 * @param {string} url - The URL to fetch
 * @param {HTMLElement} targetElement - Element to update
 * @param {Object} options - Options for fetchAndReplace, plus:
 * @param {string} options.errorMessage - Text for the error notice
 * @returns {Promise<boolean>} - True if content was replaced; false on failure, abort or missing selector
 */
export async function loadInto(url, targetElement, options = {}) {
  const { errorMessage, ...fetchOptions } = options
  try {
    return await fetchAndReplace(url, targetElement, fetchOptions)
  } catch (error) {
    if (isAbortError(error)) return false
    console.error('[RailsPulse] Fetch error:', error)
    showFetchError(targetElement, errorMessage, () => loadInto(url, targetElement, options))
    return false
  }
}

/**
 * Replace an element's content with an error notice and an optional Retry button
 * @param {HTMLElement} targetElement - Element to update
 * @param {string} message - Text to show
 * @param {Function} [retry] - Called when Retry is clicked; no button when omitted
 */
export function showFetchError(targetElement, message = 'Could not load this content.', retry) {
  const notice = document.createElement('div')
  notice.className = 'alert alert--negative fetch-error'
  notice.setAttribute('role', 'alert')

  const text = document.createElement('span')
  text.textContent = message
  notice.appendChild(text)

  if (retry) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'btn btn--borderless'
    button.textContent = 'Retry'
    button.addEventListener('click', retry)
    notice.appendChild(button)
  }

  clearElement(targetElement)
  targetElement.appendChild(notice)
}

function clearElement(element) {
  while (element.firstChild) {
    element.removeChild(element.firstChild)
  }
}

function supersededError() {
  const error = new Error('Fetch superseded by a newer one for the same element')
  error.name = 'AbortError'
  return error
}
