// Hippocampus Safari Web Extension background script.
// Relays page content to the native messaging host.
// Safari Web Extensions use browser.runtime.sendNativeMessage() for
// one-shot native messaging (no persistent port).

"use strict";

const NATIVE_HOST_NAME = "ai.hippocampus.native_messaging";

const api = typeof browser !== "undefined" ? browser : chrome;

api.runtime.onMessage.addListener((message, sender, _sendResponse) => {
  if (message.type !== "page_content") return;
  if (!sender.tab) return;

  // Defense-in-depth: Safari disables extensions in Private Browsing by
  // default, but guard at runtime too (parity with Chromium extension).
  if (sender.tab.incognito) return;

  const nativeMessage = {
    url: message.payload.url,
    title: message.payload.title,
    text: message.payload.text,
    ts_us: message.payload.ts_us,
    tab_id: sender.tab.id || 0,
    source_browser: "safari",
  };

  api.runtime.sendNativeMessage(NATIVE_HOST_NAME, nativeMessage)
    .catch(() => {});
});
