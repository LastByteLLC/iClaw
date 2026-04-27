/**
 * iClaw Extension Popup
 * Shows connection status, active tab info, and send action.
 */

const iClawProto = globalThis.iClawProtocol;

const statusEl = document.getElementById("status");
const tabTitleEl = document.getElementById("tab-title");
const tabUrlEl = document.getElementById("tab-url");
const btnSend = document.getElementById("btn-send");
const messageEl = document.getElementById("message");
const versionEl = document.getElementById("version");
const helpEl = document.getElementById("help");

versionEl.textContent = `v${iClawProto.ICLAW_VERSION}`;

let activeTabId = null;

// ─── Init ───

async function init() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab) {
    activeTabId = tab.id;
    tabTitleEl.textContent = tab.title || "Untitled";
    tabUrlEl.textContent = tab.url || "";
  }

  // Check connection
  browser.runtime.sendMessage({ source: "popup", action: "getStatus" }, (response) => {
    if (response?.connected) {
      setConnected(true);
    } else {
      browser.runtime.sendMessage({ source: "popup", action: "connect" }, (res) => {
        setConnected(res?.connected || false);
      });
    }
  });
}

function setConnected(connected) {
  if (connected) {
    statusEl.textContent = "✅";
    statusEl.title = "Connected to iClaw";
    helpEl.classList.add("hidden");
  } else {
    statusEl.textContent = "⚠️";
    statusEl.title = "Disconnected — click for help";
  }
  btnSend.disabled = !connected || !activeTabId;
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

// ─── Status click → toggle help ───

statusEl.addEventListener("click", () => {
  if (statusEl.textContent === "⚠️") {
    helpEl.classList.toggle("hidden");
  }
});

// ─── Send Page ───

btnSend.addEventListener("click", () => {
  btnSend.disabled = true;
  showMessage("Sending...");

  browser.runtime.sendMessage(
    { source: "popup", action: "sendToIClaw", tabId: activeTabId },
    (response) => {
      if (response?.error) {
        showMessage(response.error, "error");
      } else if (response?.sent) {
        showMessage(`✓ Sent: ${response.title}`, "success");
      }
      btnSend.disabled = false;
    }
  );
});

// ─── Start ───

init();
