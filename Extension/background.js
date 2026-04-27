/**
 * iClaw Background Service Worker
 * Relays messages between the native host (iClaw app) and content scripts.
 * Maintains a persistent native messaging connection.
 */

importScripts("shared/compat.js", "shared/protocol.js");

const { ICLAW_NATIVE_HOST, ICLAW_VERSION, rpcSuccess, rpcError, ErrorCodes, Methods } =
  globalThis.iClawProtocol;

let nativePort = null;
let pendingRequests = new Map(); // id -> { resolve, reject, timer }

// ─── Native messaging connection ───

function connectNative() {
  if (nativePort) return;

  try {
    nativePort = browser.runtime.connectNative(ICLAW_NATIVE_HOST);

    nativePort.onMessage.addListener((message) => {
      handleNativeMessage(message);
    });

    nativePort.onDisconnect.addListener(() => {
      console.log("[iClaw] Native host disconnected:", browser.runtime.lastError?.message);
      nativePort = null;
      // Reject all pending requests
      for (const [id, pending] of pendingRequests) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Native host disconnected"));
      }
      pendingRequests.clear();
    });

    // Send handshake
    nativePort.postMessage({
      jsonrpc: "2.0",
      method: Methods.HANDSHAKE,
      params: { browser: detectBrowser(), version: ICLAW_VERSION },
      id: "handshake",
    });
  } catch (err) {
    console.error("[iClaw] Failed to connect to native host:", err);
    nativePort = null;
  }
}

function detectBrowser() {
  if (typeof chrome !== "undefined" && chrome.runtime?.getURL) {
    if (navigator.userAgent.includes("Firefox")) return "firefox";
    if (navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome"))
      return "safari";
    return "chrome";
  }
  return "unknown";
}

/** Handle messages coming from the native host (iClaw app). */
function handleNativeMessage(message) {
  // If it's a response to a pending request
  if (message.id && pendingRequests.has(message.id)) {
    const pending = pendingRequests.get(message.id);
    pendingRequests.delete(message.id);
    clearTimeout(pending.timer);
    pending.resolve(message);
    return;
  }

  // If it's a request from the native host (iClaw asking the browser to do something)
  if (message.method) {
    handleNativeRequest(message);
  }
}

/** Handle requests initiated by the native host. */
async function handleNativeRequest(request) {
  const { method, params = {}, id } = request;

  try {
    let result;

    switch (method) {
      case Methods.TABS_LIST: {
        const tabs = await browser.tabs.query({});
        result = tabs.map((t) => ({
          id: t.id,
          title: t.title,
          url: t.url,
          active: t.active,
          windowId: t.windowId,
        }));
        break;
      }

      case Methods.TABS_GET_ACTIVE: {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        result = tab
          ? { id: tab.id, title: tab.title, url: tab.url }
          : null;
        break;
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
        // Forward to content script in the specified or active tab
        const tabId = params.tabId || (await getActiveTabId());
        if (!tabId) {
          sendNativeResponse(rpcError(id, ErrorCodes.TAB_NOT_FOUND, "No active tab"));
          return;
        }
        result = await sendToContentScript(tabId, { method, params });
        break;
      }

      case Methods.PAGE_NAVIGATE: {
        const tabId = params.tabId || (await getActiveTabId());
        if (!tabId) {
          sendNativeResponse(rpcError(id, ErrorCodes.TAB_NOT_FOUND, "No active tab"));
          return;
        }
        await browser.tabs.update(tabId, { url: params.url });
        // Wait for page load if requested
        if (params.wait) {
          await waitForTabLoad(tabId, params.timeout || 15000);
          result = await sendToContentScript(tabId, {
            method: Methods.PAGE_GET_CONTENT,
            params: {},
          });
        } else {
          result = { status: "navigating" };
        }
        break;
      }

      case Methods.PING:
        result = { pong: true, timestamp: Date.now() };
        break;

      default:
        sendNativeResponse(rpcError(id, ErrorCodes.METHOD_NOT_FOUND, `Unknown method: ${method}`));
        return;
    }

    sendNativeResponse(rpcSuccess(id, result));
  } catch (err) {
    sendNativeResponse(rpcError(id, ErrorCodes.INTERNAL_ERROR, err.message));
  }
}

// ─── Helpers ───

async function getActiveTabId() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

/** Send a message to a content script and return the result. */
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

/** Wait for a tab to finish loading. */
function waitForTabLoad(tabId, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      browser.tabs.onUpdated.removeListener(listener);
      resolve(); // Resolve anyway on timeout — partial content is better than nothing
    }, timeout);

    function listener(updatedTabId, changeInfo) {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        clearTimeout(timer);
        browser.tabs.onUpdated.removeListener(listener);
        // Small delay for JS rendering
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
      case "getStatus":
        sendResponse({
          connected: nativePort !== null,
          browser: detectBrowser(),
          version: ICLAW_VERSION,
        });
        break;

      case "connect":
        connectNative();
        sendResponse({ connected: nativePort !== null });
        break;

      case "sendToIClaw": {
        if (!nativePort) {
          connectNative();
          if (!nativePort) {
            sendResponse({ error: "Cannot connect to iClaw" });
            return;
          }
        }
        const tabId = message.tabId || (await getActiveTabId());
        if (!tabId) {
          sendResponse({ error: "No active tab" });
          return;
        }
        // Extract page content and send to iClaw
        const content = await sendToContentScript(tabId, {
          method: Methods.PAGE_GET_CONTENT,
          params: {},
        });
        nativePort.postMessage({
          jsonrpc: "2.0",
          method: Methods.PAGE_GET_CONTENT,
          params: { ...content, tabId },
          id: `popup-${Date.now()}`,
        });
        sendResponse({ sent: true, title: content.title });
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

// Connect on install/startup
browser.runtime.onInstalled.addListener(() => {
  connectNative();
});

browser.runtime.onStartup.addListener(() => {
  connectNative();
});
