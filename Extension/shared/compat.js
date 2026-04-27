/**
 * Browser API compatibility layer.
 * Normalizes chrome.* / browser.* namespace differences.
 */

if (typeof globalThis.browser === "undefined") {
  globalThis.browser = globalThis.chrome;
}
