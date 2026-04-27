/**
 * iClaw Background Service Worker
 * Relays messages between the native host (iClaw app) and content scripts.
 *
 * Safari: Uses browser.runtime.sendNativeMessage() for each request (one-shot,
 * routed through SafariWebExtensionHandler).
 * Chrome/Firefox: Uses browser.runtime.connectNative() for a persistent port
 * (routed through the iClawNativeHost binary via stdin/stdout).
 */

// Side-effect imports — these set globalThis.browser and globalThis.iClawProtocol
import "./compat.js";
import "./protocol.js";

const { ICLAW_NATIVE_HOST, ICLAW_VERSION, rpcSuccess, rpcError, ErrorCodes, Methods } =
  globalThis.iClawProtocol;

const isSafari = (typeof browser !== "undefined") &&
  navigator.userAgent.includes("Safari") &&
  !navigator.userAgent.includes("Chrome") &&
  !navigator.userAgent.includes("Firefox");

let nativePort = null; // Chrome/Firefox persistent port
let pendingRequests = new Map(); // id -> { resolve, reject, timer }
let iClawConnected = false; // Tracks whether iClaw is reachable

// ─── Native messaging ───

/**
 * Send a message to iClaw and return the response.
 * Safari: one-shot sendNativeMessage through SafariWebExtensionHandler.
 * Chrome/Firefox: post on the persistent connectNative port.
 */
async function sendToIClaw(message) {
  if (isSafari) {
    return sendNativeMessageSafari(message);
  } else {
    return sendNativeMessagePort(message);
  }
}

/** Safari: one-shot native message via SafariWebExtensionHandler. */
function sendNativeMessageSafari(message) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Native message timeout"));
    }, 15000);

    browser.runtime.sendNativeMessage(ICLAW_NATIVE_HOST, message, (response) => {
      clearTimeout(timeout);
      if (browser.runtime.lastError) {
        iClawConnected = false;
        stopHeartbeat();
        reject(new Error(browser.runtime.lastError.message));
      } else {
        iClawConnected = true;
        startHeartbeat();
        // If iClaw requests full page content, push it on next cycle
        if (response?.result?.requestContent) {
          pushFullPageContent();
        }
        // Piggyback: iClaw included a pending pull request in the response
        if (response?.result?.pendingRequest) {
          executePullRequest(response.result.pendingRequest);
        }
        // Accelerate polling if more requests are queued
        if (response?.result?.hasMorePending) {
          startFastPoll();
        } else if (response?.result?.idle) {
          stopFastPoll();
        }
        resolve(response);
      }
    });
  });
}

/** Push full page content from the active tab (triggered by iClaw request). */
async function pushFullPageContent() {
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id || !tab.url || tab.url.startsWith("about:")) return;

    const content = await sendToContentScript(tab.id, {
      method: Methods.PAGE_GET_CONTENT,
      params: {},
    });

    await sendToIClaw({
      jsonrpc: "2.0",
      method: Methods.BROWSER_PUSH_CONTENT,
      params: { url: tab.url, title: tab.title || "", text: content?.text || "" },
      id: `auto-push-${Date.now()}`,
    });
  } catch {
    // Content script may not be injected on this page
  }
}

/** Chrome/Firefox: persistent port via iClawNativeHost binary. */
function sendNativeMessagePort(message) {
  return new Promise((resolve, reject) => {
    if (!nativePort) {
      connectNativePort();
      if (!nativePort) {
        reject(new Error("Cannot connect to iClaw"));
        return;
      }
    }

    const id = message.id || `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    message.id = id;

    const timer = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error("Request timeout"));
    }, 15000);

    pendingRequests.set(id, { resolve, reject, timer });
    nativePort.postMessage(message);
  });
}

function connectNativePort() {
  if (nativePort) return;

  try {
    nativePort = browser.runtime.connectNative(ICLAW_NATIVE_HOST);
    iClawConnected = true;

    nativePort.onMessage.addListener((message) => {
      if (message.id && pendingRequests.has(message.id)) {
        const pending = pendingRequests.get(message.id);
        pendingRequests.delete(message.id);
        clearTimeout(pending.timer);
        pending.resolve(message);
      } else if (message.method) {
        handleNativeRequest(message);
      }
    });

    nativePort.onDisconnect.addListener(() => {
      console.log("[iClaw] Native host disconnected:", browser.runtime.lastError?.message);
      nativePort = null;
      iClawConnected = false;
      for (const [id, pending] of pendingRequests) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Native host disconnected"));
      }
      pendingRequests.clear();
    });

    // Handshake
    nativePort.postMessage({
      jsonrpc: "2.0",
      method: Methods.HANDSHAKE,
      params: { browser: "chrome", version: ICLAW_VERSION },
      id: "handshake",
    });
  } catch (err) {
    console.error("[iClaw] Failed to connect to native host:", err);
    nativePort = null;
    iClawConnected = false;
  }
}

// ─── Dispatch method (shared by persistent and pull paths) ───

/**
 * Execute a bridge method and return the result.
 * Used by both handleNativeRequest (Chrome/Firefox) and executePullRequest (Safari).
 * Throws on error (caller handles error response formatting).
 */
async function dispatchMethod(method, params = {}) {
  switch (method) {
    case Methods.TABS_LIST: {
      const tabs = await browser.tabs.query({});
      return tabs.map((t) => ({
        id: t.id,
        title: t.title,
        url: t.url,
        active: t.active,
        windowId: t.windowId,
      }));
    }

    case Methods.TABS_GET_ACTIVE: {
      const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
      return tab ? { id: tab.id, title: tab.title, url: tab.url } : null;
    }

    case Methods.PAGE_GET_CONTENT:
    case Methods.PAGE_GET_INFO:
    case Methods.DOM_QUERY_SELECTOR:
    case Methods.DOM_QUERY_SELECTOR_ALL:
    case Methods.DOM_EVALUATE_XPATH:
    case Methods.PAGE_SNAPSHOT:
    case Methods.DOM_CLICK:
    case Methods.DOM_FILL:
    case Methods.DOM_SCROLL:
    case Methods.DOM_SUBMIT: {
      const tabId = params.tabId || (await getActiveTabId());
      if (!tabId) throw new Error("No active tab");
      return await sendToContentScript(tabId, { method, params });
    }

    case Methods.PAGE_NAVIGATE: {
      const tabId = params.tabId || (await getActiveTabId());
      if (!tabId) throw new Error("No active tab");
      await browser.tabs.update(tabId, { url: params.url });
      if (params.wait) {
        await waitForTabLoad(tabId, params.timeout || 15000);
        return await sendToContentScript(tabId, {
          method: Methods.PAGE_GET_CONTENT,
          params: {},
        });
      }
      return { status: "navigating" };
    }

    case Methods.PING:
      return { pong: true, timestamp: Date.now() };

    default:
      throw new Error(`Unknown method: ${method}`);
  }
}

// ─── Handle requests from iClaw (via native host, Chrome/Firefox) ───

async function handleNativeRequest(request) {
  const { method, params = {}, id } = request;
  try {
    const result = await dispatchMethod(method, params);
    sendNativeResponse(rpcSuccess(id, result));
  } catch (err) {
    sendNativeResponse(rpcError(id, ErrorCodes.INTERNAL_ERROR, err.message));
  }
}

// ─── Safari pull flow ───

/**
 * Execute a pull request from iClaw (piggybacked on push response or poll).
 * Sends the result back to iClaw via bridge.pullResponse.
 */
async function executePullRequest(request) {
  const { method, params = {}, id } = request;
  try {
    const result = await dispatchMethod(method, params);
    await sendToIClaw({
      jsonrpc: "2.0",
      method: Methods.BRIDGE_PULL_RESPONSE,
      params: { id, result },
      id: `pull-resp-${Date.now()}`,
    });
  } catch (err) {
    await sendToIClaw({
      jsonrpc: "2.0",
      method: Methods.BRIDGE_PULL_RESPONSE,
      params: { id, error: { code: ErrorCodes.INTERNAL_ERROR, message: err.message } },
      id: `pull-resp-${Date.now()}`,
    });
  }
}

// ─── Safari heartbeat & fast poll ───

let heartbeatTimer = null;
let fastPollTimer = null;
const HEARTBEAT_INTERVAL_MS = 5000;
const FAST_POLL_INTERVAL_MS = 500;
const FAST_POLL_MAX_DURATION_MS = 20000;

/** Slow heartbeat poll — picks up pull requests within 5s. */
function startHeartbeat() {
  if (heartbeatTimer || !isSafari) return;
  heartbeatTimer = setInterval(async () => {
    try {
      const response = await sendToIClaw({
        jsonrpc: "2.0",
        method: Methods.BRIDGE_POLL,
        params: {},
        id: `hb-${Date.now()}`,
      });
      if (response?.result?.pendingRequest) {
        await executePullRequest(response.result.pendingRequest);
        if (response?.result?.hasMorePending) {
          startFastPoll();
        }
      }
    } catch {
      iClawConnected = false;
      stopHeartbeat();
    }
  }, HEARTBEAT_INTERVAL_MS);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
  stopFastPoll();
}

/** Fast poll for draining multiple queued requests (500ms, max 20s). */
function startFastPoll() {
  if (fastPollTimer || !isSafari) return;
  const startTime = Date.now();

  fastPollTimer = setInterval(async () => {
    if (Date.now() - startTime > FAST_POLL_MAX_DURATION_MS) {
      stopFastPoll();
      return;
    }
    try {
      const response = await sendToIClaw({
        jsonrpc: "2.0",
        method: Methods.BRIDGE_POLL,
        params: {},
        id: `fp-${Date.now()}`,
      });
      if (response?.result?.pendingRequest) {
        await executePullRequest(response.result.pendingRequest);
      }
      if (response?.result?.idle) {
        stopFastPoll();
      }
    } catch {
      stopFastPoll();
    }
  }, FAST_POLL_INTERVAL_MS);
}

function stopFastPoll() {
  if (fastPollTimer) {
    clearInterval(fastPollTimer);
    fastPollTimer = null;
  }
}

// ─── Helpers ───

async function getActiveTabId() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

function sendToContentScript(tabId, message) {
  return new Promise((resolve, reject) => {
    browser.tabs.sendMessage(tabId, message, (response) => {
      if (browser.runtime.lastError) {
        reject(new Error(browser.runtime.lastError.message));
      } else if (response?.error) {
        reject(new Error(response.error.message));
      } else {
        resolve(response?.result);
      }
    });
  });
}

function waitForTabLoad(tabId, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      browser.tabs.onUpdated.removeListener(listener);
      resolve();
    }, timeout);

    function listener(updatedTabId, changeInfo) {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        clearTimeout(timer);
        browser.tabs.onUpdated.removeListener(listener);
        setTimeout(resolve, 500);
      }
    }

    browser.tabs.onUpdated.addListener(listener);
  });
}

function sendNativeResponse(message) {
  if (nativePort) {
    nativePort.postMessage(message);
  }
}

// ─── Message handling from popup ───

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.source === "popup") {
    handlePopupMessage(message, sendResponse);
    return true; // Async response
  }
});

async function handlePopupMessage(message, sendResponse) {
  try {
    switch (message.action) {
      case "getStatus": {
        // For Safari, ping iClaw to check connectivity
        if (isSafari && !iClawConnected) {
          try {
            await sendToIClaw({
              jsonrpc: "2.0",
              method: Methods.PING,
              params: {},
              id: `status-${Date.now()}`,
            });
          } catch {
            // iClaw not reachable
          }
        }
        sendResponse({
          connected: isSafari ? iClawConnected : nativePort !== null,
          browser: isSafari ? "safari" : "chrome",
          version: ICLAW_VERSION,
        });
        break;
      }

      case "connect": {
        if (isSafari) {
          try {
            await sendToIClaw({
              jsonrpc: "2.0",
              method: Methods.PING,
              params: {},
              id: `connect-${Date.now()}`,
            });
            sendResponse({ connected: true });
          } catch (err) {
            sendResponse({ connected: false, error: err.message });
          }
        } else {
          connectNativePort();
          sendResponse({ connected: nativePort !== null });
        }
        break;
      }

      case "sendToIClaw": {
        const tabId = message.tabId || (await getActiveTabId());
        if (!tabId) {
          sendResponse({ error: "No active tab" });
          return;
        }
        let pageText = "";
        // Try content script first, fall back to scripting.executeScript
        try {
          const content = await sendToContentScript(tabId, {
            method: Methods.PAGE_GET_CONTENT,
            params: {},
          });
          pageText = content?.text || "";
        } catch {
          // Content script not injected — extract inline via scripting API
          try {
            const [result] = await browser.scripting.executeScript({
              target: { tabId },
              func: () => {
                const el = document.querySelector("article") || document.querySelector("main") || document.body;
                return { text: el?.innerText || "", title: document.title, url: location.href };
              },
            });
            pageText = result?.result?.text || "";
          } catch {
            // scripting API also failed
          }
        }
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        await sendToIClaw({
          jsonrpc: "2.0",
          method: Methods.BROWSER_PUSH_CONTENT,
          params: { url: tab?.url || "", title: tab?.title || "", text: pageText },
          id: `push-${Date.now()}`,
        });
        sendResponse({ sent: true, title: tab?.title || "Page" });
        break;
      }

      case "extractSelection": {
        const tabId = message.tabId || (await getActiveTabId());
        if (!tabId) {
          sendResponse({ error: "No active tab" });
          return;
        }
        const [result] = await browser.scripting.executeScript({
          target: { tabId },
          func: () => window.getSelection()?.toString() || "",
        });
        const selection = result?.result?.trim();
        if (!selection) {
          sendResponse({ error: "No text selected on page" });
          return;
        }
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        await sendToIClaw({
          jsonrpc: "2.0",
          method: Methods.BROWSER_PUSH_CONTENT,
          params: { url: tab?.url || "", title: tab?.title || "", text: selection, selectionOnly: true },
          id: `selection-${Date.now()}`,
        });
        sendResponse({ sent: true, title: "Selection" });
        break;
      }

      default:
        sendResponse({ error: `Unknown action: ${message.action}` });
    }
  } catch (err) {
    sendResponse({ error: err.message });
  }
}

// ─── Lifecycle ───

// Chrome/Firefox: connect on startup
if (!isSafari) {
  browser.runtime.onInstalled.addListener(() => {
    connectNativePort();
  });

  browser.runtime.onStartup.addListener(() => {
    connectNativePort();
  });
}

// ─── Auto-push context on tab switch/navigation (Safari push-first) ───

let lastContextPushTime = 0;
const CONTEXT_PUSH_DEBOUNCE_MS = 2000;

async function pushContextUpdate(tabId) {
  const now = Date.now();
  if (now - lastContextPushTime < CONTEXT_PUSH_DEBOUNCE_MS) return;
  lastContextPushTime = now;

  try {
    const tab = await browser.tabs.get(tabId);
    if (!tab?.url || tab.url.startsWith("about:") || tab.url.startsWith("safari-")) return;

    await sendToIClaw({
      jsonrpc: "2.0",
      method: Methods.BROWSER_CONTEXT_UPDATE,
      params: { url: tab.url, title: tab.title || "" },
      id: `ctx-${now}`,
    });
  } catch {
    // iClaw not running — silently ignore
  }
}

// Tab activated (user switched tabs)
browser.tabs.onActivated.addListener((activeInfo) => {
  pushContextUpdate(activeInfo.tabId);
});

// Tab navigation completed
browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "complete") {
    // Only push for the active tab
    browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
      if (tab && tab.id === tabId) {
        pushContextUpdate(tabId);
      }
    });
  }
});
