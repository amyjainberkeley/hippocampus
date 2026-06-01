# Hippocampus — Chromium Extension

Captures full page text from Chrome / Arc / Brave / Edge and forwards
it via native messaging to the local Hippocampus brain. All data stays
on the user's device.

## `all_frames: true` — iframe content capture

The `content_scripts` entry sets `all_frames: true`. Without it the
content script only runs in the top-level frame, which silently drops
the entire payment / message / video / ad-embed of any cross-origin
iframe — i.e. the parts of the page the user is actually working with:

- **Stripe checkout** amount/items/payment form (rendered in
  `js.stripe.com/v3/...` iframes)
- **Sandboxed Gmail** message body (rendered in
  `mail.google.com/...?ui=2&view=...` iframes)
- **Vimeo / Loom** video title + description (rendered in
  `player.vimeo.com/video/...` iframes)
- **Ad-network embedded content** (rendered in `*.doubleclick.net`
  and similar iframes)

This closes the slot identified in
`docs/research/orchestrator-ratification-state-2026-05-31.md` §SH Fork E
(ratified 2026-05-31 — CEO override of CRS rec E3 joint structural
review; CSO sign-off required on the implementing PR per
`docs/AGENT_PROTOCOL.md` §5).

### Trade-off

`all_frames: true` expands the content-script attack surface from one
frame per tab to N frames per tab. The trade-off was documented in
`docs/research/browser-extension-audit.md` §"P1 — privacy parity" and
accepted by the CEO. Mitigations that keep the surface bounded:

1. **No origin broadening.** `matches: ["<all_urls>"]` is unchanged —
   we only enable injection into iframes whose top-level page is
   already covered. We do NOT set `match_origin_as_fallback` (which
   would also inject into `about:blank` / `data:` / `blob:` frames
   inheriting their origin). Those remain off the content script's
   reach.
2. **`BLOCKED_PROTOCOLS` is re-checked per frame.** Each frame runs
   its own copy of `content.js` and its own `isBlockedURL` against
   `window.location.href`. A `data:` / `chrome-extension:` /
   `about:` iframe self-terminates and never `sendMessage`s.
3. **Incognito exclusion is per-context.**
   `chrome.extension.inIncognitoContext` is true in every frame of a
   split-incognito tab — every frame bails before extracting. Backed
   up by the `sender.tab.incognito` early-return in `background.js`
   and the `incognito: true` early-return in `apps/hippocampus-native-host/src/main.rs`.
4. **Denylist applies per-frame.** `is_denied_url` in the native host
   runs on the frame's own URL AND the parent (top-level) URL — if
   either matches, the event is dropped before secret-filter and
   before the page-content socket write.
5. **Secret filter applies per-frame.** The §6 secret-pattern filter
   runs on the iframe's own `text` payload before the wire write.
6. **`MAX_TEXT_LENGTH = 200000`** is applied per-frame; an iframe
   with a runaway DOM cannot blow the budget for the tab.

### Event shape (background.js → native host JSON wire)

Each frame sends one `page_content` message to the background service
worker. Background.js forwards one native-messaging frame per content
event with these fields (additive — older native hosts that don't
recognise the new fields fall through their `#[serde(default)]`):

| Field | Type | Meaning |
|---|---|---|
| `url` | string | The top-level tab URL (for top frame, equals the page URL) — preserves the brain's per-page attribution |
| `frame_url` | string | The frame's own URL (equals `url` for top frame) |
| `is_top_frame` | bool | `true` if `sender.frameId === 0`; `false` for any sub-frame |
| `frame_id` | u32 | Chromium frame ID (`0` for top, non-zero per sub-frame) |
| `title` | string | `document.title` of the frame |
| `text` | string | `document.body.innerText` of the frame, capped at 200 K chars |
| `ts_us` | u64 | wall-clock timestamp |
| `tab_id` | u32 | Chrome tab ID |
| `source_browser` | string | `"chrome"` / `"arc"` / `"brave"` / `"edge"` |
| `incognito` | bool | `sender.tab.incognito` (propagated for the CSO defense-in-depth check) |

The downstream binary wire (`core/src/ipc/wire.rs::PageContentEvent`,
discriminant `0x0050`) is **unchanged** — the native host emits one
`PageContentEvent` per frame using `url = frame_url`, and prefixes
the `title` with `[iframe of <parent-url>] ` for sub-frames so the
brain can attribute the iframe content to its parent page without
needing a schema bump. The wire format stays at the current FRAME
versions (`0x06` / `0x07` / `0x08`).

## Files Chromium loads

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest |
| `background.js` | Service worker — relays content.js messages to the native host |
| `content.js` | Per-frame DOM text extractor |
| `icons/*.png` | Toolbar icons |

Files in this directory NOT loaded by Chromium (kept for development
only): `package.json`, `package-lock.json`, `node_modules/`,
`__tests__/`, this `README.md`. The `build-app.sh` Chromium bundle
block (`apps/hippocampus/Resources/build-app.sh:285`) only copies the
four loaded entries into the shipped `.app`.

## Running the tests

```
cd extensions/chromium
npm install
npx vitest run
```
