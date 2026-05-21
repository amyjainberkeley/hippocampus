// Hippocampus content script — extracts page content and forwards to
// the background service worker for native messaging relay.
//
// CSO INVARIANTS:
// - NEVER reads input.value / textarea.value / contenteditable
// - NEVER runs on data: / chrome: / chrome-extension: / about: URLs
// - Incognito guard in manifest (incognito: "split") + runtime check
// - Text capped at 200,000 characters
// - No local cache — strictly forward-and-forget

"use strict";

const MAX_TEXT_LENGTH = 200000;

const BLOCKED_PROTOCOLS = new Set([
  "data:",
  "chrome:",
  "chrome-extension:",
  "about:",
  "blob:",
  "file:",
  "devtools:",
  "view-source:",
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

  chrome.runtime.sendMessage({
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = { extractPageContent, isBlockedURL, MAX_TEXT_LENGTH };
}
