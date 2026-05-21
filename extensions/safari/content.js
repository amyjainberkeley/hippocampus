// Hippocampus Safari Web Extension content script.
// Same logic as the Chromium version but uses browser.* API namespace.
// Safari Web Extensions support both chrome.* and browser.* — we use
// browser.* for consistency with the WebExtension standard.
//
// CSO INVARIANTS: identical to extensions/chromium/content.js.

"use strict";

const MAX_TEXT_LENGTH = 200000;

const BLOCKED_PROTOCOLS = new Set([
  "data:",
  "safari-extension:",
  "about:",
  "blob:",
  "file:",
]);

function isBlockedURL(url) {
  if (!url) return true;
  for (const proto of BLOCKED_PROTOCOLS) {
    if (url.startsWith(proto)) return true;
  }
  return false;
}

function extractPageContent() {
  if (isBlockedURL(window.location.href)) return null;

  const text = (document.body && document.body.innerText) || "";
  const truncated = text.length > MAX_TEXT_LENGTH
    ? text.slice(0, MAX_TEXT_LENGTH)
    : text;

  const metaDesc = document.querySelector('meta[name="description"]');
  const ogTitle = document.querySelector('meta[property="og:title"]');

  return {
    url: window.location.href,
    title: document.title || "",
    text: truncated,
    meta_description: metaDesc ? metaDesc.content : "",
    og_title: ogTitle ? ogTitle.content : "",
    ts_us: Math.floor(Date.now() * 1000),
  };
}

function sendContent() {
  const content = extractPageContent();
  if (!content) return;
  if (!content.text && !content.title) return;

  const api = typeof browser !== "undefined" ? browser : chrome;
  api.runtime.sendMessage({
    type: "page_content",
    payload: content,
  });
}

let lastURL = window.location.href;
let debounceTimer = null;

function debouncedSend() {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(sendContent, 500);
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    debouncedSend();
  }
});

const origPushState = history.pushState;
history.pushState = function () {
  origPushState.apply(this, arguments);
  if (window.location.href !== lastURL) {
    lastURL = window.location.href;
    debouncedSend();
  }
};

const origReplaceState = history.replaceState;
history.replaceState = function () {
  origReplaceState.apply(this, arguments);
  if (window.location.href !== lastURL) {
    lastURL = window.location.href;
    debouncedSend();
  }
};

window.addEventListener("popstate", () => {
  if (window.location.href !== lastURL) {
    lastURL = window.location.href;
    debouncedSend();
  }
});

debouncedSend();
