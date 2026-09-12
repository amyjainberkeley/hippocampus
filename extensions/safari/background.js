// Hippocampus Safari Web Extension background script.
// Relays page content to the native messaging host.
// Safari Web Extensions use browser.runtime.sendNativeMessage() for
// one-shot native messaging (no persistent port).

"use strict";

const NATIVE_HOST_NAME = "ai.hippocampus.native_messaging";

const api = typeof browser !== "undefined" ? browser : chrome;

function isPersistableTab(tab) {
  // `undefined` is not evidence that a tab is non-private. Safari users can
  // grant extensions access in Private Browsing, so require an explicit false.
  return Boolean(tab) && tab.incognito === false;
}

api.runtime.onMessage.addListener((message, sender, _sendResponse) => {
  if (message.type === "capture_authorization") {
    if (!isPersistableTab(sender.tab)) {
      return Promise.resolve({ authorized: false });
    }
    return api.runtime.sendNativeMessage(NATIVE_HOST_NAME, {
      type: "capture_authorization",
      incognito: false,
    }).then(
      (response) => ({ authorized: response && response.status === "authorized" }),
      () => ({ authorized: false }),
    );
  }
  if (message.type !== "page_content") return;
  if (!isPersistableTab(sender.tab)) return;

  const nativeMessage = {
    url: message.payload.url,
    title: message.payload.title,
    text: message.payload.text,
    ts_us: message.payload.ts_us,
    tab_id: sender.tab.id || 0,
    source_browser: "safari",
    incognito: false,
  };

  api.runtime.sendNativeMessage(NATIVE_HOST_NAME, nativeMessage)
    .catch(() => {});
});

if (typeof module !== "undefined" && module.exports) {
  module.exports = { isPersistableTab };
}
