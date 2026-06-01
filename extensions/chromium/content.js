// Hippocampus content script — extracts page content and forwards to
// the background service worker for native messaging relay.
//
// With `all_frames: true` in manifest.json (SH Fork E1, ratified
// 2026-05-31), this script runs once PER FRAME — top-level page AND
// every cross-origin iframe whose top-level page matches `<all_urls>`.
// Each frame extracts its own DOM independently. The `is_top_frame`
// flag (computed below) lets background.js + the native host
// distinguish a sub-frame so the brain can attribute the iframe
// content to its parent page without a binary-wire schema bump.
//
// CSO INVARIANTS:
// - NEVER reads input.value / textarea.value / contenteditable
// - NEVER runs on data: / chrome: / chrome-extension: / about: URLs
//   (re-checked PER FRAME in `isBlockedURL` — a blocked iframe URL
//   bails before the message ever leaves the content script)
// - Incognito exclusion is defense-in-depth at FOUR layers:
//     1. manifest "incognito": "split" (sibling-context isolation)
//     2. content.js `chrome.extension.inIncognitoContext` early-return (this file)
//     3. background.js `sender.tab.incognito` early-return
//     4. native-host `incognito: true` early-return (Rust side)
//   Any one layer should be sufficient. All four ship together so a JS
//   regression cannot reach the brain. The incognito check fires
//   independently in every iframe — `chrome.extension.inIncognitoContext`
//   is true in every frame of a split-incognito tab. Per docs/DESIGN.md,
//   incognito exclusion is a launch-blocker — it ships WITH capture.
// - Text capped at 200,000 characters PER FRAME — a runaway iframe DOM
//   cannot blow the tab's budget.
// - No local cache — strictly forward-and-forget

"use strict";

// CSO invariant #1: never observe an incognito tab from the content
// script, even if the user has flipped "Allow in Incognito" on. Manifest
// is `incognito: "split"`, which runs us in a separate context where
// this flag is true — bail before extracting or sending.
function isIncognitoContext() {
  return typeof chrome !== "undefined" &&
    chrome.extension &&
    chrome.extension.inIncognitoContext === true;
}

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

// True when this content-script instance is running in the top-level
// frame of the tab. With `all_frames: true`, every iframe ALSO runs
// content.js — `window.top` is the outermost window; `window === window.top`
// only in the top frame. Wrapped in try/catch because cross-origin
// iframe contexts can throw a SecurityError on `window.top` access in
// older Chromium builds; fail-closed (treat as sub-frame) on error.
function isTopFrame() {
  try {
    return window === window.top;
  } catch (_e) {
    return false;
  }
}

function extractPageContent() {
  if (isIncognitoContext()) return null;
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
    is_top_frame: isTopFrame(),
  };
}

function sendContent() {
  if (isIncognitoContext()) return;
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
  module.exports = {
    extractPageContent,
    isBlockedURL,
    isIncognitoContext,
    isTopFrame,
    MAX_TEXT_LENGTH,
  };
}
