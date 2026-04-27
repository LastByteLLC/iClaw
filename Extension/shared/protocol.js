/**
 * iClaw Browser Bridge Protocol
 * JSON-RPC 2.0 message format shared between content scripts, background, and native host.
 */

const ICLAW_NATIVE_HOST = "com.geticlaw.nativehost";
const ICLAW_VERSION = "1.0";

/** Create a JSON-RPC request. */
function rpcRequest(method, params = {}, id = null) {
  return {
    jsonrpc: "2.0",
    method,
    params,
    id: id || `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
  };
}

/** Create a JSON-RPC success response. */
function rpcSuccess(id, result) {
  return { jsonrpc: "2.0", id, result };
}

/** Create a JSON-RPC error response. */
function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

// Standard error codes
const ErrorCodes = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
  // Custom codes
  TAB_NOT_FOUND: -32001,
  PERMISSION_DENIED: -32002,
  EXTRACTION_FAILED: -32003,
  TIMEOUT: -32004,
};

// Available methods
const Methods = {
  // Handshake
  HANDSHAKE: "handshake",

  // Page content
  PAGE_GET_CONTENT: "page.getContent",
  PAGE_NAVIGATE: "page.navigate",
  PAGE_GET_INFO: "page.getInfo",

  // DOM queries
  DOM_QUERY_SELECTOR: "dom.querySelector",
  DOM_QUERY_SELECTOR_ALL: "dom.querySelectorAll",
  DOM_EVALUATE_XPATH: "dom.evaluateXPath",

  // Interactive actions
  PAGE_SNAPSHOT: "page.snapshot",
  DOM_CLICK: "dom.click",
  DOM_FILL: "dom.fill",
  DOM_SCROLL: "dom.scroll",
  DOM_SUBMIT: "dom.submit",
  DOM_PICK_ELEMENT: "dom.pickElement",

  // Tab management
  TABS_LIST: "tabs.list",
  TABS_GET_ACTIVE: "tabs.getActive",

  // Safari pull flow
  BRIDGE_POLL: "bridge.poll",
  BRIDGE_PULL_RESPONSE: "bridge.pullResponse",

  // Push events
  BROWSER_CONTEXT_UPDATE: "browser.contextUpdate",
  BROWSER_PUSH_CONTENT: "browser.pushContent",

  // Status
  PING: "ping",
};

// Export for both module and script contexts
if (typeof globalThis !== "undefined") {
  globalThis.iClawProtocol = {
    ICLAW_NATIVE_HOST,
    ICLAW_VERSION,
    rpcRequest,
    rpcSuccess,
    rpcError,
    ErrorCodes,
    Methods,
  };
}
