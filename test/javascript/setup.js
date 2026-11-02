import { vi } from 'vitest'
import { Application } from '@hotwired/stimulus'

// Polyfill browser APIs not implemented in JSDOM
globalThis.IntersectionObserver = vi.fn(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}))

globalThis.ResizeObserver = vi.fn(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}))

// Wait for Stimulus MutationObserver to process DOM changes
export const nextTick = () => new Promise(resolve => setTimeout(resolve, 0))

// A fetch stub whose responses resolve only when the test calls
// pending[url].respond(body, status), and which rejects with an AbortError when
// its signal is aborted, as the browser's fetch does.
// Install with vi.stubGlobal('fetch', fetchMock).
export function controllableFetch() {
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

// Mount a single controller in a fresh Stimulus app.
// Returns { app, element } and sets document.body.innerHTML to the given HTML.
// Call teardown() in afterEach to stop the app and reset the DOM.
export async function mountController(identifier, ControllerClass, html) {
  document.body.innerHTML = html
  const app = Application.start()
  app.register(identifier, ControllerClass)
  await nextTick()
  return {
    app,
    element: document.querySelector(`[data-controller="${identifier}"]`),
    teardown() {
      app.stop()
      document.body.innerHTML = ''
    },
  }
}
