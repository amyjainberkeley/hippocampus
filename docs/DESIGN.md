# MCI — Memory Context Interface

**Design Document v0.1**
Status: Draft · Owner: @amyjainberkeley · Last updated: 2026-05-18

---

## 1. Overview

MCI is an always-on desktop agent that continuously records a person's screen **and**, in parallel, captures the structured context of their workflow — the frontmost app, the focused window, the active browser tab's URL, and the full text content of what they are looking at. It turns that stream into a private, searchable **brain**: a long-term memory of everything the person has seen and done, so context is never lost.

The core idea (as deployed internally at Meta): a knowledge worker's real context lives in transient state — the tab they had open, the doc they skimmed, the Slack thread three days ago, the error they saw and fixed. Today that evaporates. MCI persists it, indexes it, and lets the person (or an agent acting for them) recall it instantly: *"what was that pricing page I looked at last Tuesday?"*, *"summarize everything I read about X this week"*, *"what was I doing right before the build broke?"*

This document specifies a **local-first, end-to-end-encrypted** implementation that a person downloads and runs on their own machine. Capture, storage, OCR, embeddings, and recall all run on-device. An optional encrypted cloud layer provides cross-device sync and backup — the cloud never sees plaintext.

The single hardest engineering constraint: **it must be invisible.** It runs all day while the person does their real job. The machine must not get slow, hot, or drained. Every architectural decision below is in service of that.

---

## 2. Goals & Non-Goals

### Goals
- **G1 — Total recall.** Capture screen + workflow context continuously and losslessly *at the level of meaningful state transitions* (not every frame).
- **G2 — Invisible overhead.** Steady-state ≤ low-single-digit % of one CPU core, ~100–250 MB RAM, modest battery/thermal impact. The user should not notice it running.
- **G3 — Local-first & private by construction.** All capture and intelligence run on-device. Cloud is optional, and is **zero-knowledge** (client-side encrypted; server cannot read).
- **G4 — Fast recall.** Hybrid semantic + lexical search over months of memory returns in well under a second.
- **G5 — Cross-platform by design.** Architecture supports macOS and Windows from one shared core. Ship macOS first.
- **G6 — Agent-ready.** The brain is queryable by an LLM/agent via a local API, so other tools can use the memory.

### Non-Goals (v1)
- **NG1 — Not a team/surveillance product.** Single-user, user-owned. No admin dashboards, no employer visibility. (Trust is the product.)
- **NG2 — Not real-time collaboration or streaming.** This is a memory system, not screen-share.
- **NG3 — No cloud LLM inference on raw capture.** Summarization/extraction is on-device. (A user may *opt in* later to send a redacted slice to a model of their choice — explicitly, not by default.)
- **NG4 — Linux** is out of scope for v1 (the abstraction does not preclude it later).
- **NG5 — Mobile** is out of scope.

---

## 3. Product Behavior — A Day In The Life

1. User installs MCI. First-run onboarding explains exactly what is captured and walks through the OS permission prompts (Screen Recording, Accessibility, Automation) with plain-language rationale.
2. MCI lives in the menu bar / system tray. A single glanceable state: **Recording / Paused / Off**. One click to pause (e.g., before entering a password vault or a private call). Configurable auto-pause rules (denylisted apps/URLs).
3. User works normally. They open Chrome, read a pricing page, switch to VS Code, hit an error, Google it, read a Stack Overflow answer, switch to Slack. MCI silently records the screen at meaningful transitions and, for each, attaches: app = Chrome, window title, URL, the page's extracted text; then app = VS Code, file, the error text via OCR; etc.
4. Nothing is felt. Fans stay quiet. Battery is normal.
5. Later, the user opens MCI's recall view (or asks an agent): *"what was the Stack Overflow answer I used to fix the build error on Thursday afternoon?"* MCI returns the moment — a keyframe thumbnail, the extracted text, the URL, timestamp, surrounding context — and a one-line synthesized answer.
6. On a second machine (also running MCI, same account), the encrypted memory has synced; recall works there too. The sync server only ever held ciphertext.

---

## 4. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        MCI Agent (per device)                          │
│                                                                        │
│  ┌────────────────────┐         ┌──────────────────────────────────┐  │
│  │  Platform Capture   │         │     Portable Core (Rust)         │  │
│  │  Adapter (native)   │  frames │                                  │  │
│  │                     │ +events │  Capture Pipeline                │  │
│  │  macOS:             │────────▶│   · smart-capture filter chain   │  │
│  │   ScreenCaptureKit  │         │   · dedupe (dHash)               │  │
│  │   VideoToolbox      │         │   · keyframe/HEVC encode (FFI)   │  │
│  │   Vision OCR        │         │   · OCR orchestration            │  │
│  │   AX / AppleScript  │         │   · context join                 │  │
│  │                     │         │                                  │  │
│  │  Windows:           │         │  Brain                           │  │
│  │   Windows.Graphics. │         │   · chunk → embed → index        │  │
│  │   Capture           │         │   · hybrid retrieval (FTS+vec)   │  │
│  │   Media Foundation  │         │                                  │  │
│  │   Windows.Media.Ocr │         │  Store: one encrypted SQLite     │  │
│  │   UIA               │         │   (events · text · FTS5 ·        │  │
│  │                     │         │    sqlite-vec · blobs ref)       │  │
│  └────────────────────┘         │                                  │  │
│           ▲                      │  Sync: client-side-encrypted     │  │
│           │ trait: CaptureSource │   delta push/pull                │  │
│  ┌────────┴───────────┐         └──────────────┬───────────────────┘  │
│  │ Browser Extension   │ native msg            │ local API (loopback) │
│  │ (optional, per      │──────────────────────▶│  ◀── Recall UI       │
│  │  browser): page text│                       │  ◀── Agents/LLM      │
│  └────────────────────┘                        └──────────┬───────────┘
└────────────────────────────────────────────────────────────┼──────────┘
                                                              │ ciphertext only
                                                   ┌──────────▼───────────┐
                                                   │  Sync Server (cloud)  │
                                                   │  zero-knowledge blob  │
                                                   │  store + delta log    │
                                                   └───────────────────────┘
```

**The central design decision:** a **portable Rust core** owns everything that is not OS-specific (the pipeline, dedupe, OCR orchestration, the brain, encryption, sync). Each OS provides a **thin native capture/context adapter** implementing a common `CaptureSource` trait. This is what makes cross-platform real without writing the brain twice (§11).

---

## 5. Capture Pipeline

### 5.1 Screen capture

- **macOS:** `ScreenCaptureKit` (`SCStream`), one stream per `SCDisplay`. `CGDisplayStream`/`AVCaptureScreenInput` are obsoleted (removed in macOS 15) and higher-overhead — not options.
- **Windows:** `Windows.Graphics.Capture` (`GraphicsCaptureItem` / frame pool), the direct analog — modern, GPU-backed, low-overhead. (Win 10 1903+.)

Both deliver GPU-memory-backed frames (`IOSurface` / `Direct3D` texture), so we never round-trip pixels through the CPU before encode/OCR.

Capture configuration tuned for an all-day daemon:
- Frame ceiling **1–2 fps** baseline (`minimumFrameInterval`), raised briefly during active work, dropped back. This is the single biggest energy lever.
- `queueDepth` = 3 (minimum). Release each surface back to the pool immediately after copy-out — holding longer than `interval × (queueDepth−1)` silently stalls the stream.
- Downscale to ~1440–1920px wide. Native 5K is wasteful for text recognition; downscale slashes encode + OCR cost.
- Cursor off (cursor movement = spurious frame deltas), audio off.
- **Exclude MCI's own UI** from the capture filter (no hall-of-mirrors, no dead work).

### 5.2 Smart-capture filter chain (the overhead killer)

A fixed-FPS all-day recorder is energy suicide. A static screen and an idle user must cost ~zero. Filters, cheapest first — work only advances on a genuine **state transition**:

1. **Idle gate (free, highest impact).** Last-input time (`CGEventSourceSecondsSinceLastEventType` / `GetLastInputInfo`). No input for N s → drop to ~0.1 fps or `stopCapture()`. Most of a knowledge-worker day is reading/thinking; this removes large stretches outright.
2. **Frame-status filter (free).** Use the platform's "did anything change" signal (`SCStreamFrameInfo.status` = `.idle`/`.blank` → discard; WGC frame-arrived semantics). Static screen ⇒ near-zero cost even with the stream "running."
3. **Dirty-rect triage (cheap).** If changed region is empty/tiny (cursor blink, clock tick), skip OCR and skip a keyframe.
4. **Perceptual dedupe (sub-ms).** 64-bit **dHash** on a downscaled grayscale frame; Hamming distance vs last stored. Below threshold ⇒ near-duplicate (scroll jitter), discard. SSIM reserved only for borderline cases (heavier).
5. **Adaptive frame rate.** State machine: active typing/clicking → 2 fps; passive scroll/read → 0.5 fps; idle → paused.

Net: an 8-hour day collapses to on the order of a few thousand meaningful events, not millions of frames. Idle-gate + status filter are essentially free and remove the bulk of the day.

### 5.3 Encoding & storage model

**Do not store continuous video.** Per detected state transition, store:
- **(a)** a sparse keyframe (HEIC/JPEG) — hardware-encoded via `VideoToolbox` (macOS) / `Media Foundation` (Windows), HEVC/H.265, zero-copy from the capture surface. Apple Silicon / GPU media engine ⇒ near-zero CPU.
- **(b)** the extracted OCR text + structured context for that moment.
- **(c)** *optionally* a low-fps scrubbable HEVC segment **only for active-work windows** (long GOP, IDR forced on transitions) — a human-review fallback, not the primary store.

Continuous 1080p all day = tens of GB. Event-keyed keyframe+text = 1–2 orders of magnitude smaller, and is what the brain actually queries. Blobs live in a content-addressed store on disk; the DB holds references.

---

## 6. Context Capture — The Parallel Workflow Signal

This is what makes MCI a *brain* and not a screen recorder. For every state transition we join:

| Signal | macOS | Windows | Cost / friction |
|---|---|---|---|
| Frontmost app | `NSWorkspace.frontmostApplication` (+ activation notifications) | `GetForegroundWindow` + process | Free, event-driven |
| Focused window title/role | Accessibility API (`AXUIElement`) | UI Automation (UIA) | One-time Accessibility grant; poll on change only |
| **Active browser tab URL** | AppleScript/Apple Events (`get URL of active tab`) — Chrome/Safari/Arc/Brave/Edge | UIA address-bar read | macOS: **Automation prompt per browser**. Firefox has no AppleScript path |
| **Full page text** | Browser extension (native messaging) → clean DOM text; OCR fallback | Same | Extension = best fidelity, highest install friction |

**Tiered content strategy:**
- **Best:** an optional companion **browser extension** (`document.body.innerText` / Readability-style extraction) over native messaging — clean text, no OCR cost, even gets off-screen DOM.
- **Universal fallback:** on-screen **OCR** of the captured keyframe (§7). No extra permission beyond Screen Recording, works for *every* app (Slack, Mail, IDEs, PDFs, native apps) not just browsers.
- Accessibility-tree text scrape sits in between (brittle, slow) — fallback only.

**Permission reality (must be designed for, not hidden):** three TCC/consent surfaces on macOS — Screen Recording (mandatory; pre-Sequoia re-prompts on app update; Sequoia adds periodic reminders), Accessibility (one-time), Automation (one prompt **per browser**). Windows is lighter (Graphics Capture consent + standard UIA). Onboarding must front-load and explain these honestly — permission UX is as important as the capture engine.

---

## 7. On-Device OCR & Understanding

- **macOS:** Vision `RecognizeTextRequest` (`.accurate`). Fully on-device, Neural Engine-accelerated, no per-call cost, no network.
- **Windows:** `Windows.Media.Ocr` (built-in, on-device) or a bundled engine (PaddleOCR/Tesseract) where quality demands.

OCR is the heaviest step in the pipeline. Hard rules:
- Run **only on state-transition keyframes**, and **only on the dirty-rect sub-regions**, never full-frame-per-frame. This is the dominant OCR-cost optimization.
- `.accurate` level (a searchable brain needs quality), language-restricted, `minimumTextHeight` set to skip tiny chrome text, serialized on a low-QoS queue (never two OCR passes contending), deferred under thermal/low-power pressure.

**Beyond OCR (opportunistic, batched, idle/charging only — never in the hot path):** on-device document-structure recognition; Natural Language / on-device LLM (Apple Foundation Models on macOS 26; small Core ML / ONNX model on Windows) for per-event summarization, entity extraction, and screen classification ("is this code / email / meeting / browsing").

---

## 8. The Brain — Memory Layer

The brain is what the user (and agents) actually interact with. Pipeline shape:

```
state-transition event
  → keyframe + OCR/extracted text + context join (app, window, URL, page text, timestamp)
  → text cleanup
  → chunk (~200–500 tokens, semantic/paragraph boundaries)
  → batch-embed   (deferred to idle/charging)
  → upsert into one SQLite file (FTS5 + sqlite-vec)
  → retrieve = hybrid lexical (FTS5) + semantic (vector KNN) + recency/app boosting
```

- **Embedding model:** quantized **all-MiniLM-L6-v2** (384-d) via **Core ML** (ANE) on macOS / **ONNX Runtime + DirectML** on Windows. ~6–90 MB depending on quantization, thousands of chunks/sec on modern hardware, negligible energy when batched. `NLEmbedding` only as a no-dependency floor. Larger model (bge-small) only if retrieval eval demands it.
- **Vector store:** **sqlite-vec** — pure C, zero deps, single file, co-located with relational + FTS5 data in **one SQLite file**. Trivial to client-side-encrypt and sync as a unit. ~tens of ms over 1M vectors. (LanceDB is the scale-up option if we ever exceed many millions of vectors; not v1.)
- **Hybrid retrieval:** FTS5 (lexical, catches exact strings/errors/URLs) + vector KNN (semantic) fused with recency and app/source boosting. Hybrid dramatically out-recalls either alone on noisy screen text.
- **Recall interface:**
  - **Local UI** — timeline scrubber + natural-language search; each result = keyframe thumbnail, extracted text, app/URL, timestamp, neighboring events.
  - **Local API** (loopback, authenticated) — so an LLM/agent can query the brain ("answer from my memory"), with results structured for RAG.

---

## 9. Privacy, Security, Encryption & Sync

MCI captures the most sensitive possible data stream. Trust is the product; this section is load-bearing.

### 9.1 Threat model
- The cloud sync server **must never** be able to read user content (zero-knowledge).
- A device-local attacker should not get plaintext memory at rest.
- The user must have hard, obvious controls to **not capture** certain things.

### 9.2 Encryption
- **At rest (device):** the SQLite store + blob store encrypted with a device-held key (SQLCipher / OS keystore-backed key — Keychain on macOS, DPAPI/Credential Manager on Windows). Memory store is never plaintext on disk.
- **Cloud (local + encrypted cloud model):** **client-side encryption before upload.** A user master key (derived from a passphrase + per-device keys; recovery-code backed) encrypts every delta. The server stores opaque ciphertext blobs + a delta log for sync ordering, and **cannot decrypt anything**. End-to-end across the user's own devices.
- Sync is **delta-based** (append-only encrypted change log), so cross-device convergence never requires server-side plaintext.

### 9.3 Sensitive-content controls (not optional)
- **App & URL denylist:** never capture from configured apps (password managers, banking, health, private messaging) — capture is suppressed at the source, frame never enters the pipeline.
- **Incognito / private windows:** detected and excluded.
- **One-click pause** + auto-pause rules (on screen-lock, on denylisted foreground, on call/meeting if configured).
- **On-device redaction pass** (opportunistic): detect and mask secrets/PII patterns (passwords, tokens, card numbers) in OCR text before it is indexed.
- **Full user control:** browse, search, **delete** any memory or time range; "forget last hour"; export; full wipe. Deletion propagates to the encrypted cloud deltas.
- **No telemetry of content.** Crash/usage telemetry (if any) is opt-in and content-free.

---

## 10. Runtime Architecture & Resource Footprint

- **Process model:** a single signed menu-bar / system-tray agent (`LSUIElement` on macOS / tray app on Windows), auto-started per-user (LaunchAgent / Task Scheduler-or-Run-key), crash-relaunched. **Not** a foreground app, **not** a root daemon — per-user TCC/permissions are tied to a GUI app bundle and need a UI for onboarding/consent/pause. A rich recall/settings UI may run as a *separate* process the agent launches on demand.
- **Memory ceiling discipline:** bounded ring buffer for in-flight frames (fixed N surfaces, never an unbounded array); backpressure = **drop frames** if OCR/encode falls behind (a dropped near-duplicate is harmless — dedupe already assumed it); batched, throttled disk flush (SQLite WAL + periodic checkpoint; blobs to content-addressed store, not in the DB); release capture surfaces immediately; OCR/embed at low QoS, deferred on battery, throttled on thermal/low-power state.
- **Realistic footprint (well-built native pipeline, Apple Silicon / modern x86):** static-screen steady state ≈ <1–2% of one core, ~100–250 MB resident (flat, buffer+cache bound); per-event bursts = brief sub-second one-core spikes, smoothed by batching; energy "modest, noticeable only under sustained heavy editing." This is the entire reason the capture/encode/OCR layer is native and the runtime is not Electron.

---

## 11. Cross-Platform Strategy

**Decision: portable Rust core + thin per-OS native capture adapters. Ship macOS first; Windows is a defined later phase that reuses the core unchanged.**

Why not "native Swift, unconditionally" (the single-platform optimum)? Because the capture/context layer is irreducibly OS-specific and cannot be shared across Windows in Swift — and the brain must not be written twice.

- **`CaptureSource` trait (Rust):** `start/stop`, `next_event() -> StateTransition { frame_surface, dirty_rects, timestamp }`, `context_probe() -> WorkflowContext { app, window, url, page_text }`, `permissions_status()`. Everything above this line (pipeline, dedupe, encode orchestration, OCR orchestration, brain, crypto, sync) is **written once** in Rust.
- **macOS adapter:** a small **Swift capture helper** (cleanest path to ScreenCaptureKit/VideoToolbox/Vision; objc2 FFI is possible but Swift helper is pragmatic) bridged to the Rust core. Accepts a modest loss of pure-Swift zero-copy elegance in exchange for one shared brain.
- **Windows adapter:** Rust → `windows-rs` bindings to Windows.Graphics.Capture, Media Foundation, Windows.Media.Ocr, UIA.
- **Shared, platform-agnostic:** the entire brain (chunk/embed/index/retrieve), the encrypted SQLite store, encryption, the sync protocol, the local recall API. ONNX Runtime gives cross-platform embeddings; sqlite-vec/SQLite are already portable.

Adding Windows later = implement one adapter + wire platform encode/OCR. No brain rework, no protocol rework.

---

## 12. Data Model (initial sketch)

One encrypted SQLite database:

- `events` — `id, ts, device_id, app_bundle, window_title, source_type, url, keyframe_blob_ref, dwell_ms, dhash`
- `event_text` — `event_id, text, lang, extraction_method (ext|ocr|ax)` + **FTS5** virtual table over `text`
- `event_vectors` — **sqlite-vec** table: `event_id, chunk_id, embedding(384)`
- `chunks` — `id, event_id, ord, text, token_count`
- `blobs` — content-addressed keyframe/segment store (on disk; row holds hash, path, bytes, codec)
- `sync_log` — append-only encrypted deltas: `seq, device_id, op, ciphertext, nonce`
- `redactions` / `denylist` / `deletions` — user-control + tombstone records
- `meta` — schema version, key wrapping metadata, retention policy

Retention/compaction policy (open, §15): age-out raw keyframes while keeping text+embeddings; tiered (recent = keyframe+text+vec; old = text+vec only; very old = summary only).

---

## 13. Tech Stack Summary

| Concern | Choice |
|---|---|
| Portable core | **Rust** |
| macOS capture/encode/OCR | Swift helper → ScreenCaptureKit · VideoToolbox · Vision |
| macOS context | NSWorkspace · Accessibility API · AppleScript/Apple Events |
| Windows capture/encode/OCR | Rust `windows-rs` → Windows.Graphics.Capture · Media Foundation · Windows.Media.Ocr |
| Windows context | UI Automation |
| Page content | Optional per-browser extension (native messaging); OCR fallback |
| Dedupe | dHash (64-bit), SSIM for borderline |
| Embeddings | quantized all-MiniLM-L6-v2 — Core ML (mac) / ONNX Runtime+DirectML (win) |
| Store / index | one SQLite file: FTS5 + sqlite-vec, SQLCipher-encrypted |
| Crypto | OS keystore-backed device key; client-side E2E for cloud |
| Sync | zero-knowledge encrypted delta log to object storage |
| Recall | local SwiftUI/native UI + authenticated loopback API |

---

## 14. Repository Layout (proposed)

```
mci/
  docs/
    DESIGN.md                ← this file
    decisions/               ← ADRs (one per locked material decision)
  core/                      ← Rust portable core (pipeline, brain, crypto, sync)
  adapters/
    macos/                   ← Swift capture helper + bridge
    windows/                 ← Rust windows-rs adapter (later phase)
  apps/
    agent/                   ← menu-bar/tray agent shell
    recall-ui/               ← recall + settings UI
  extensions/
    chrome/  safari/  ...     ← optional page-content extensions
  server/                    ← zero-knowledge sync server
```

---

## 15. Roadmap / Phases

- **Phase 0 — Foundations.** Repo, Rust core skeleton, `CaptureSource` trait, encrypted SQLite store, ADRs for the locked decisions in this doc.
- **Phase 1 — macOS capture spine.** Swift helper: ScreenCaptureKit → smart-capture filter chain (idle gate, status, dirty-rect, dHash) → HEVC keyframes. Prove the footprint budget (G2) on a real workday.
- **Phase 2 — Context join.** NSWorkspace + Accessibility + AppleScript browser URL. Onboarding/permission flow.
- **Phase 3 — OCR + brain.** Vision OCR (dirty-rect scoped) → chunk → MiniLM embed → SQLite FTS5+sqlite-vec → hybrid recall. Local recall UI v1.
- **Phase 4 — Privacy controls.** Denylists, pause rules, redaction pass, delete/forget/export, at-rest encryption hardened.
- **Phase 5 — Encrypted cloud sync.** Client-side E2E, zero-knowledge server, cross-device convergence.
- **Phase 6 — Agent API + on-device understanding.** Loopback RAG API; opportunistic summarization/classification.
- **Phase 7 — Browser extension** (clean page text) for major browsers.
- **Phase 8 — Windows adapter.** Implement `CaptureSource` on WGC/Media Foundation/Windows.Media.Ocr/UIA. Core unchanged.
- **Phase 9 — Retention/compaction**, scale hardening, polish.

---

## 16. Risks & Open Questions

- **R1 — Permission friction is the top product risk.** macOS Screen Recording re-prompts on update (pre-Sequoia) and nags periodically (Sequoia); Automation prompts per browser. Onboarding UX + stable signing/notarization matter as much as the engine.
- **R2 — Browser coverage uneven.** AppleScript URL works for Chrome/Safari/Arc/Brave/Edge, **not Firefox**; full page text without an extension is OCR-only (lossy, on-screen only). Decide if the extension is in scope earlier than Phase 7.
- **R3 — "Static = free" is documented, not an SLA.** Must empirically verify a truly static screen costs ~0 CPU on both platforms; fall back to explicit `stopCapture()` on idle if not.
- **R4 — OCR + embedding are the real energy cost.** The whole budget rests on the filter chain firing rarely; a mis-tuned dHash threshold floods OCR. Needs real-workload tuning + a guardrail.
- **R5 — Sensitive capture is indiscriminate by default.** Denylist + redaction must ship with capture, not after. Privacy is a launch blocker, not a Phase 4 nicety — revisit ordering.
- **R6 — Disk growth over months/years** with keyframes+text is unmodeled. Needs a retention policy and projected-size model before GA.
- **R7 — Embedding quality on heterogeneous screen text** (code, UI fragments, tables) is unproven. Needs a retrieval eval; may force a larger model.
- **R8 — Surface-pool stalls.** Holding capture surfaces too long silently drops frames; the encode/copy-out path must be measured under load.
- **R9 — Rust ↔ Swift bridge** for the macOS adapter adds integration complexity vs pure Swift; validate the boundary early (Phase 1).

---

## 17. Glossary

- **State transition** — a meaningful change in what the user is seeing/doing (new page, app switch, significant content change), as opposed to a raw frame. The unit MCI stores.
- **dHash** — difference hash; a fast perceptual image fingerprint used to drop near-duplicate frames.
- **TCC** — macOS Transparency, Consent & Control (the permission system: Screen Recording / Accessibility / Automation).
- **WGC** — Windows.Graphics.Capture, the modern Windows screen-capture API.
- **Zero-knowledge sync** — the cloud server stores only ciphertext and cannot decrypt user content.
- **`CaptureSource`** — the Rust trait every per-OS capture adapter implements; the seam that makes the core platform-agnostic.
