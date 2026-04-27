/**
 * iClaw Extension Popup
 * Shows connection status, active tab info, and actions.
 */

const { ICLAW_VERSION } = globalThis.iClawProtocol;

const statusEl = document.getElementById("status");
const tabTitleEl = document.getElementById("tab-title");
const tabUrlEl = document.getElementById("tab-url");
const btnSend = document.getElementById("btn-send");
const btnExtract = document.getElementById("btn-extract");
const messageEl = document.getElementById("message");
const versionEl = document.getElementById("version");

versionEl.textContent = `v${ICLAW_VERSION}`;

let activeTabId = null;

// ─── Init ───

async function init() {
  // Get active tab info
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab) {
    activeTabId = tab.id;
    tabTitleEl.textContent = tab.title || "Untitled";
    tabUrlEl.textContent = tab.url || "";
  }

  // Check connection status
  browser.runtime.sendMessage({ source: "popup", action: "getStatus" }, (response) => {
    if (response?.connected) {
      setConnected(true);
    } else {
      // Try to connect
      browser.runtime.sendMessage({ source: "popup", action: "connect" }, (res) => {
        setConnected(res?.connected || false);
      });
    }
  });
}

function setConnected(connected) {
  statusEl.className = `status ${connected ? "connected" : "disconnected"}`;
  btnSend.disabled = !connected || !activeTabId;
  btnExtract.disabled = !connected || !activeTabId;

  if (!connected) {
    showMessage("Not connected to iClaw app", "error");
  }
}

function showMessage(text, type = "") {
  messageEl.textContent = text;
  messageEl.className = `message ${type}`;
  if (type === "success") {
    setTimeout(() => {
      messageEl.textContent = "";
      messageEl.className = "message";
    }, 3000);
  }
}

// ─── Actions ───

btnSend.addEventListener("click", async () => {
  btnSend.disabled = true;
  showMessage("Sending...");

  browser.runtime.sendMessage(
    { source: "popup", action: "sendToIClaw", tabId: activeTabId },
    (response) => {
      if (response?.error) {
        showMessage(response.error, "error");
      } else if (response?.sent) {
        showMessage(`Sent: ${response.title}`, "success");
      }
      btnSend.disabled = false;
    }
  );
});

btnExtract.addEventListener("click", async () => {
  if (!activeTabId) return;
  btnExtract.disabled = true;

  // Get selected text from the active tab
  try {
    const [result] = await browser.scripting.executeScript({
      target: { tabId: activeTabId },
      func: () => window.getSelection()?.toString() || "",
    });

    const selection = result?.result;
    if (selection && selection.trim()) {
      browser.runtime.sendMessage(
        {
          source: "popup",
          action: "sendToIClaw",
          tabId: activeTabId,
          extractType: "selection",
          content: selection.trim(),
        },
        (response) => {
          if (response?.error) {
            showMessage(response.error, "error");
          } else {
            showMessage("Selection sent", "success");
          }
          btnExtract.disabled = false;
        }
      );
    } else {
      showMessage("No text selected on page", "error");
      btnExtract.disabled = false;
    }
  } catch (err) {
    showMessage(err.message, "error");
    btnExtract.disabled = false;
  }
});

// ─── Start ───

init();
