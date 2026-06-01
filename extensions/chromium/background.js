// Hippocampus background service worker — relays page content from
// content scripts to the native messaging host.
//
// The native messaging host is identified as "ai.hippocampus.native_messaging".
// It reads the native messaging protocol (4-byte length prefix + JSON)
// from stdin, applies secret filtering + denylist, and forwards to the
// MCI agent process.
//
// With `all_frames: true` (SH Fork E1, ratified 2026-05-31), content.js
// runs once per frame; this worker receives ONE `page_content` message
// per frame. The forwarded native-host JSON carries `frame_url`,
// `parent_url`, `is_top_frame`, and `frame_id` so the native host can
// (a) apply denylist to BOTH the frame URL and the parent (top) URL —
// drop if either matches; and (b) prefix sub-frame titles with the
// parent URL for downstream attribution. The fields are additive — an
// older native host without the new fields still works correctly via
// `#[serde(default)]` on the Rust side.

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

  // CSO invariant: drop the message here, AND forward an `incognito`
  // flag to the native host so a JS regression cannot silently leak
  // content. Both layers are defense-in-depth; the early-return is the
  // primary block, the flag is the belt-and-suspenders fallback.
  if (sender.tab.incognito) return;

  const nativePort = connectNativeHost();
  if (!nativePort) return;

  // Per-frame attribution. `sender.frameId === 0` is the top frame;
  // any non-zero value is a sub-frame. `sender.url` is the frame's
  // own URL; `sender.tab.url` is the top-level tab URL — equal for
  // the top frame, different for cross-origin iframes. The content
  // script also self-reports `is_top_frame`; we trust `sender.frameId`
  // because the browser sets it, but pass content.js's value through
  // as well so the native host can sanity-check (mismatch → treat as
  // sub-frame, fail-closed).
  const frameId = typeof sender.frameId === "number" ? sender.frameId : 0;
  const senderIsTopFrame = frameId === 0;
  const payloadIsTopFrame =
    typeof message.payload.is_top_frame === "boolean"
      ? message.payload.is_top_frame
      : senderIsTopFrame;
  const isTopFrame = senderIsTopFrame && payloadIsTopFrame;

  // For top frames, `frame_url` and the top-level `url` are the same.
  // For sub-frames, `url` is the parent (top-level) tab URL — chosen
  // so the brain's per-page index keys on the page the user is
  // actually looking at; `frame_url` carries the iframe's own URL for
  // attribution + per-frame denylist matching in the native host.
  const frameUrl = message.payload.url || (sender.url || "");
  const parentUrl =
    (sender.tab && sender.tab.url) ? sender.tab.url : frameUrl;
  const topLevelUrl = isTopFrame ? frameUrl : parentUrl;

  try {
    nativePort.postMessage({
      url: topLevelUrl,
      frame_url: frameUrl,
      parent_url: parentUrl,
      is_top_frame: isTopFrame,
      frame_id: frameId,
      title: message.payload.title,
      text: message.payload.text,
      ts_us: message.payload.ts_us,
      tab_id: sender.tab.id || 0,
      source_browser: detectBrowser(),
      incognito: sender.tab.incognito === true,
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
