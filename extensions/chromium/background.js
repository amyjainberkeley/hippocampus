// Hippocampus background service worker — relays page content from
// content scripts to the native messaging host.
//
// The native messaging host is identified as "ai.hippocampus.native_messaging".
// It reads the native messaging protocol (4-byte length prefix + JSON)
// from stdin, applies secret filtering + denylist, and forwards to the
// MCI agent process.

"use strict";

const NATIVE_HOST_NAME = "ai.hippocampus.native_messaging";

let port = null;

function connectNativeHost() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    port.onDisconnect.addListener(() => {
      port = null;
    });
  } catch (_e) {
    port = null;
  }
  return port;
}

chrome.runtime.onMessage.addListener((message, sender, _sendResponse) => {
  if (message.type !== "page_content") return;
  if (!sender.tab) return;

  if (sender.tab.incognito) return;

  const nativePort = connectNativeHost();
  if (!nativePort) return;

  try {
    nativePort.postMessage({
      url: message.payload.url,
      title: message.payload.title,
      text: message.payload.text,
      ts_us: message.payload.ts_us,
      tab_id: sender.tab.id || 0,
      source_browser: detectBrowser(),
    });
  } catch (_e) {
    port = null;
  }
});

function detectBrowser() {
  const ua = navigator.userAgent || "";
  if (ua.includes("Edg/")) return "edge";
  if (ua.includes("Brave")) return "brave";
  if (ua.includes("Arc")) return "arc";
  if (ua.includes("Chrome/")) return "chrome";
  return "chrome";
}
