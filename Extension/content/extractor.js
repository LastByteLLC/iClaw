/**
 * iClaw Content Extractor
 * Runs as a content script on every page. Extracts text, resolves selectors/XPaths,
 * and responds to messages from the background script.
 */

(() => {
  // Prevent double-injection
  if (window.__iclawExtractorLoaded) return;
  window.__iclawExtractorLoaded = true;

  /** Extract readable text from the page, preferring semantic content containers. */
  function extractPageContent() {
    const el =
      document.querySelector("article") ||
      document.querySelector("main") ||
      document.querySelector('[role="main"]') ||
      document.querySelector("#content") ||
      document.querySelector(".content") ||
      document.body;

    if (!el) return { title: document.title, text: "", url: location.href };

    // Clone to avoid mutating the live DOM
    const clone = el.cloneNode(true);

    // Remove noise elements
    const noiseSelectors = [
      "nav", "header", "footer", "aside", "script", "style", "noscript",
      "iframe", "svg", ".sidebar", ".ad", ".advertisement", ".cookie-banner",
      ".cookie-notice", '[role="navigation"]', '[role="banner"]',
      '[role="contentinfo"]',
    ];
    for (const sel of noiseSelectors) {
      for (const node of clone.querySelectorAll(sel)) {
        node.remove();
      }
    }

    let text = clone.innerText || clone.textContent || "";
    text = compactText(text);

    return {
      title: document.title,
      text,
      url: location.href,
    };
  }

  /** Run a CSS selector and return matching elements' text. */
  function querySelector(selector) {
    const elements = document.querySelectorAll(selector);
    return Array.from(elements).map((el, i) => ({
      index: i,
      tag: el.tagName.toLowerCase(),
      text: compactText(el.innerText || el.textContent || ""),
      html: el.outerHTML.slice(0, 500),
    }));
  }

  /** Evaluate an XPath expression and return matching nodes' text. */
  function evaluateXPath(xpath) {
    const result = document.evaluate(
      xpath,
      document,
      null,
      XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
      null
    );
    const nodes = [];
    for (let i = 0; i < result.snapshotLength && i < 100; i++) {
      const node = result.snapshotItem(i);
      nodes.push({
        index: i,
        tag: node.nodeName?.toLowerCase() || "#text",
        text: compactText(node.innerText || node.textContent || ""),
      });
    }
    return nodes;
  }

  /** Compact text: collapse whitespace, remove invisible chars, trim. */
  function compactText(text) {
    return text
      .replace(/[\u200B\u200C\u200D\uFEFF\u00AD\u200E\u200F]/g, "")
      .replace(/\t/g, " ")
      .replace(/ {2,}/g, " ")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  /** Get basic page info without full extraction. */
  function getPageInfo() {
    return {
      title: document.title,
      url: location.href,
      favicon: document.querySelector('link[rel*="icon"]')?.href || "",
      readyState: document.readyState,
    };
  }

  // ---- Interactive Actions & Accessibility Snapshot ----

  /**
   * Build a compact accessibility-tree snapshot of interactive elements.
   * Returns element refs like @e1, @e2 that can be targeted by click/type actions.
   * Token-efficient: ~200-500 tokens for a typical page vs 1000+ for full DOM.
   */
  function buildSnapshot() {
    const refs = [];
    let refIndex = 0;

    // Interactive element selectors — covers forms, buttons, links, and ARIA widgets
    const interactiveSelectors = [
      'a[href]', 'button', 'input', 'select', 'textarea',
      '[role="button"]', '[role="link"]', '[role="tab"]',
      '[role="menuitem"]', '[role="option"]', '[role="checkbox"]',
      '[role="radio"]', '[role="switch"]', '[role="textbox"]',
      '[role="combobox"]', '[role="searchbox"]',
      '[contenteditable="true"]',
    ];

    const elements = document.querySelectorAll(interactiveSelectors.join(", "));

    for (const el of elements) {
      // Skip hidden/invisible elements
      if (el.offsetParent === null && el.tagName !== "BODY") continue;
      const style = window.getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") continue;

      const ref = `@e${refIndex}`;
      // Tag element for later retrieval
      el.setAttribute("data-iclaw-ref", ref);

      const tag = el.tagName.toLowerCase();
      const role = el.getAttribute("role") || "";
      const ariaLabel = el.getAttribute("aria-label") || "";
      const label = ariaLabel
        || el.getAttribute("title")
        || el.getAttribute("placeholder")
        || compactText(el.innerText || el.textContent || "").slice(0, 60);
      const type = el.getAttribute("type") || "";
      const disabled = el.disabled || el.getAttribute("aria-disabled") === "true";
      const value = (tag === "input" || tag === "textarea" || tag === "select")
        ? (el.value || "").slice(0, 40)
        : "";

      // Build compact descriptor
      let desc = `${ref}: `;
      if (role) {
        desc += `[${role}]`;
      } else if (tag === "a") {
        desc += "[link]";
      } else if (tag === "button") {
        desc += "[button]";
      } else if (tag === "input") {
        desc += `[input:${type || "text"}]`;
      } else if (tag === "select") {
        desc += "[select]";
      } else if (tag === "textarea") {
        desc += "[textarea]";
      } else {
        desc += `[${tag}]`;
      }
      desc += ` "${label}"`;
      if (value) desc += ` val="${value}"`;
      if (disabled) desc += " (disabled)";

      refs.push({ ref, desc, tag, role, type, disabled });
      refIndex++;

      // Cap at 100 elements to stay within token budget
      if (refIndex >= 100) break;
    }

    return {
      url: location.href,
      title: document.title,
      elementCount: refs.length,
      snapshot: refs.map(r => r.desc).join("\n"),
      refs,
    };
  }

  /** Resolve an element ref (@e0, @e1, ...) to a live DOM element. */
  function resolveRef(ref) {
    return document.querySelector(`[data-iclaw-ref="${ref}"]`);
  }

  /** Click an element by ref or CSS selector. */
  function clickElement(params) {
    let el;
    if (params.ref) {
      el = resolveRef(params.ref);
    } else if (params.selector) {
      const matches = document.querySelectorAll(params.selector);
      el = matches[params.index || 0];
    }
    if (!el) return { success: false, error: "Element not found" };
    if (el.disabled) return { success: false, error: "Element is disabled" };

    el.focus();
    el.click();
    return { success: true, tag: el.tagName.toLowerCase(), text: compactText(el.innerText || "").slice(0, 60) };
  }

  /** Type text into an input/textarea by ref or CSS selector. */
  function fillElement(params) {
    let el;
    if (params.ref) {
      el = resolveRef(params.ref);
    } else if (params.selector) {
      const matches = document.querySelectorAll(params.selector);
      el = matches[params.index || 0];
    }
    if (!el) return { success: false, error: "Element not found" };

    const tag = el.tagName.toLowerCase();
    if (tag !== "input" && tag !== "textarea" && tag !== "select" && !el.isContentEditable) {
      return { success: false, error: `Cannot type into <${tag}> element` };
    }

    el.focus();
    if (params.clear !== false) {
      el.value = "";
    }

    // Use InputEvent for React/Vue/Angular compatibility
    const text = params.text || "";
    el.value = text;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));

    return { success: true, tag, value: el.value.slice(0, 40) };
  }

  /** Scroll the page or a specific element. */
  function scrollPage(params) {
    const direction = params.direction || "down";
    const amount = params.amount || 400;

    let target = document;
    if (params.ref) {
      target = resolveRef(params.ref);
      if (!target) return { success: false, error: "Element not found" };
    }

    const scrollEl = (target === document) ? window : target;
    switch (direction) {
      case "down":  scrollEl.scrollBy(0, amount); break;
      case "up":    scrollEl.scrollBy(0, -amount); break;
      case "left":  scrollEl.scrollBy(-amount, 0); break;
      case "right": scrollEl.scrollBy(amount, 0); break;
      case "top":   scrollEl.scrollTo(0, 0); break;
      case "bottom": scrollEl.scrollTo(0, document.body.scrollHeight); break;
    }
    return { success: true, scrollY: window.scrollY, scrollX: window.scrollX };
  }

  /** Submit a form by ref/selector or find the nearest form to an element. */
  function submitForm(params) {
    let el;
    if (params.ref) {
      el = resolveRef(params.ref);
    } else if (params.selector) {
      el = document.querySelector(params.selector);
    }
    if (!el) return { success: false, error: "Element not found" };

    const form = el.closest("form") || (el.tagName === "FORM" ? el : null);
    if (!form) return { success: false, error: "No form found" };

    form.requestSubmit();
    return { success: true, action: form.action || location.href };
  }

  // Listen for messages from the background script
  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    try {
      switch (message.method) {
        case "page.getContent":
          sendResponse({ result: extractPageContent() });
          break;

        case "page.getInfo":
          sendResponse({ result: getPageInfo() });
          break;

        case "dom.querySelector":
          sendResponse({ result: querySelector(message.params.selector) });
          break;

        case "dom.querySelectorAll":
          sendResponse({ result: querySelector(message.params.selector) });
          break;

        case "dom.evaluateXPath":
          sendResponse({ result: evaluateXPath(message.params.xpath) });
          break;

        case "page.snapshot":
          sendResponse({ result: buildSnapshot() });
          break;

        case "dom.click":
          sendResponse({ result: clickElement(message.params || {}) });
          break;

        case "dom.fill":
          sendResponse({ result: fillElement(message.params || {}) });
          break;

        case "dom.scroll":
          sendResponse({ result: scrollPage(message.params || {}) });
          break;

        case "dom.submit":
          sendResponse({ result: submitForm(message.params || {}) });
          break;

        default:
          sendResponse({ error: { code: -32601, message: `Unknown method: ${message.method}` } });
      }
    } catch (err) {
      sendResponse({ error: { code: -32603, message: err.message } });
    }
    return true; // Keep message channel open for async response
  });
})();
