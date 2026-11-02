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
  // The parsed response is discarded afterwards, so its nodes are moved, not cloned
  targetElement.replaceChildren(...sourceElement.childNodes)
}

// In-flight request per target element: { url, controller, promise }
const inFlight = new WeakMap()

/**
 * Fetch HTML and replace a target element's content in one operation.
 * Asking again for the URL already loading into the element returns that request;
 * a different URL aborts it (rejecting with an AbortError), so a slow response can
 * never overwrite a newer one. While loading, the element carries aria-busy="true".
 * @param {string} url - The URL to fetch
 * @param {HTMLElement} targetElement - Element to update
 * @param {Object} options - Additional fetch options
 * @param {string} options.selector - CSS selector to find content in response (defaults to targetElement.id)
 * @returns {Promise<boolean>} - True if content was replaced, false if selector not found in response
 */
export function fetchAndReplace(url, targetElement, options = {}) {
  const current = inFlight.get(targetElement)
  if (current?.url === url) return current.promise

  current?.controller.abort()
  const controller = new AbortController()
  const promise = replaceFrom(url, targetElement, options, controller)
  inFlight.set(targetElement, { url, controller, promise })
  return promise
}

async function replaceFrom(url, targetElement, options, controller) {
  targetElement.setAttribute('aria-busy', 'true')

  try {
    const doc = await fetchPartial(url, { ...options, signal: controller.signal })
    // A response can still settle after abort() if the body was already read
    controller.signal.throwIfAborted()

    // Use provided selector or default to target element's ID
    const selector = options.selector || `#${targetElement.id}`
    const sourceElement = doc.querySelector(selector)

    if (sourceElement) {
      replaceElement(targetElement, sourceElement)
      return true
    }

    // No matching content in response - clear the target
    targetElement.replaceChildren()
    return false
  } finally {
    if (inFlight.get(targetElement)?.controller === controller) {
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
  const { errorMessage = 'Could not load this content.', ...fetchOptions } = options
  try {
    return await fetchAndReplace(url, targetElement, fetchOptions)
  } catch (error) {
    if (error?.name === 'AbortError') return false
    console.error('[RailsPulse] Fetch error:', error)
    showFetchError(targetElement, errorMessage, () => loadInto(url, targetElement, options))
    return false
  }
}

function showFetchError(targetElement, message, retry) {
  const notice = document.createElement('div')
  notice.className = 'alert alert--negative flex items-center justify-between gap'
  notice.setAttribute('role', 'alert')

  const text = document.createElement('span')
  text.textContent = message

  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'btn btn--borderless'
  button.textContent = 'Retry'
  button.addEventListener('click', retry)

  notice.append(text, button)
  targetElement.replaceChildren(notice)
}
