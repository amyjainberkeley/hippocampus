# Architecture

Hippocampus is a local-first "total recall" desktop app. It continuously records what you see on screen and the structured context around it (frontmost app, focused window, active browser tab URL, page text), turns that stream into a private, encrypted, searchable memory, and lets you — or an agent acting for you — recall any past moment by natural-language query: *"what was that pricing page I looked at last Tuesday?"*

This document is for an engineer reading the codebase cold. It describes what the system is, how data flows through it, why the load-bearing decisions were made, and — honestly — what is actually working versus what is built but unproven. The exhaustive design rationale lives in [`docs/DESIGN.md`](docs/DESIGN.md) and the ADRs under [`docs/decisions/`](docs/decisions/); this is the map.

Platform scope: macOS ships first. Windows is a defined-but-unbuilt later phase. The whole architecture exists to make the second one cheap.

---

## The core idea: a portable Rust core behind one capture seam

Screen capture, hardware encode, and OCR are irreducibly OS-specific. The intelligence — dedupe, indexing, embedding, retrieval, encryption, sync — is not. If we wrote the intelligence natively per platform we would write the hard part twice.

So the whole system is split along a single Rust trait, `CaptureSource` (`core/src/capture.rs`):

- **Below the seam** — a thin, native, per-OS *adapter* that knows how to grab frames and read window/app/URL context and hand them across an FFI boundary. On macOS this is a Swift helper.
- **Above the seam** — everything else, written once in Rust: the pipeline, the "brain," crypto, the store, sync, the local query API.

Nothing above `CaptureSource` may contain OS-specific code. Adding Windows later means implementing one adapter, not touching the brain. That is the entire cross-platform bet, and it is the first thing to internalize before reading any module.

One deliberate constraint shapes the FFI: **pixels never cross the seam as an owned buffer.** The adapter hands the core an opaque, borrowed `SurfaceHandle` (a macOS `IOSurface` / Windows D3D texture) with a strict release-timing contract; the core copies-out or encodes from GPU memory and drops it immediately. This keeps an all-day recorder off the CPU, which is the difference between "invisible" and "laptop is hot."

---

## Data flow: capture → OCR → extract/embed → encrypted store → recall

```
 screen + context           Rust core (mci-core)              brain (mci-brain)          recall
┌───────────────┐   frames  ┌────────────────────┐   event   ┌──────────────────┐      ┌─────────┐
│ macOS Swift   │  +events  │ capture pipeline    │  ───────▶ │ segment/summarize│  ◀── │ local   │
│ capture helper│ ────────▶ │  · idle/status gate │           │ embed (Arctic-S) │      │ UI /    │
│ (CaptureSource│           │  · dirty-rect triage│           │ FTS5 + sqlite-vec│      │ agent   │
│  impl)        │           │  · dHash dedupe     │           │ hybrid retrieval │      │ (RAG)   │
└───────────────┘           │  · OCR orchestration│           └────────┬─────────┘      └─────────┘
                            └─────────┬───────────┘                    │
                                      │  one SQLCipher-encrypted SQLite file
                                      ▼           (events · text/FTS5 · vectors · blobs-ref)
                            encrypted delta log ───▶ zero-knowledge sync server (ciphertext only)
```

1. **Capture.** The adapter delivers frames only at *meaningful state transitions*, not at a fixed frame rate. A filter chain — cheapest first — decides what survives: an idle gate (no input → stop), the platform "did anything change" signal, dirty-rect triage, and a 64-bit **dHash** perceptual dedupe to drop scroll jitter and near-duplicates. An 8-hour day collapses to a few thousand events, not millions of frames. This filter chain is the entire energy budget; a mistuned dHash threshold floods everything downstream.

2. **OCR + context join.** For each surviving transition the adapter runs on-device OCR (macOS Vision, `.accurate`, scoped to dirty rects only) and joins the workflow context: app bundle, window title, active browser URL, and — when the optional browser extension is present — clean DOM page text. OCR is the heaviest step; it runs only on transition keyframes and only on changed sub-regions.

3. **Extract + embed.** In the brain, each event is segmented into episodes (time-gap + content-shift, no LLM), optionally key-expanded with an on-device LLM-written summary and entities, then embedded. The retrieval unit is the **event**, not a flat chunk (ADR-0010); over-long events are sub-chunked on semantic boundaries. Embedding and summarization are deferred to idle/charging time — never the hot path.

4. **Store.** Everything lands in **one SQLCipher-encrypted SQLite file**: relational `events`/`episodes`, `event_text` with an FTS5 virtual table, and an `event_vectors` sqlite-vec table (384-d). Keyframe blobs live in a content-addressed on-disk store; the DB holds references. One file, one encryption boundary.

5. **Recall.** A query runs **hybrid retrieval**: FTS5 lexical + vector KNN semantic, fused by a min-max convex combination that also weights recency and source. A query router handles "right before X" (anchor-then-window) and "last Tuesday" (time-range extraction). Results surface through a local UI and an authenticated loopback API so an agent can answer from your memory.

---

## Why these specific choices

- **SQLCipher, one file.** The zero-knowledge invariant requires that the store be a single encryptable unit. A separate vector database would break that. This is why the vector index is **sqlite-vec** (pure C, single file, co-located with the relational + FTS5 data) rather than a standalone ANN service — it is the only option that keeps everything inside one encrypted SQLite file. The DB master key is wrapped by a Secure-Enclave-gated, non-exportable Keychain item; the store is never plaintext on disk.

- **FTS5 + sqlite-vec hybrid.** Screen text is heterogeneous — code, UI fragments, prose, error strings. Lexical search nails exact tokens (a filename, an error code); semantic search nails intent ("that pricing discussion"). On lifelog corpora recall dominates precision, and fusing both beats either alone. Convex combination was chosen over Reciprocal Rank Fusion per the ADR-0010 eval.

- **On-device `snowflake-arctic-embed-s`.** 33M params, 384-d, Apache-2.0, int8-quantized, run through Core ML on the Neural Engine (ADR-0011). It gives a large retrieval-quality lift over the `all-MiniLM-L6-v2` baseline at the same dimension and size class, while staying fully on-device — no embedding call ever leaves the machine, preserving the zero-network privacy thesis. The model card's required query/document prefixes are applied inside the embedder wrapper.

- **Native capture, not Electron.** The footprint budget (steady-state ≤10–15% of one core, ≤2 GB RAM at default settings) is only reachable with hardware encode, zero-copy surfaces, and Neural-Engine OCR. That is the whole reason the capture/encode/OCR layer is a native Swift helper and not a cross-platform GUI runtime.

- **Swift adapter, not pure objc2 FFI.** ScreenCaptureKit / VideoToolbox / Vision are cleanest from Swift. We accept a small Rust↔Swift bridge cost to get one shared brain instead of a second native implementation.

---

## Crate / module map

### Rust workspace (`Cargo.toml`)

| Crate | Responsibility |
|---|---|
| `core/` (`mci-core`) | The portable core: the `CaptureSource` trait/seam, the capture pipeline skeleton, crypto (`crypto/` — DB key + Keychain key-wrap), the SQLite store (`store/` — schema, migrations, open, tombstones), and the IPC layer (`ipc/` — framed wire protocol + fd-passing to the helper). OS-free. |
| `core/brain/` (`mci-brain`) | The memory layer. `sqlcipher_brain_store.rs` (the encrypted store), `hybrid_retriever.rs` (FTS5 + vector fusion), `arctic_embed_s.rs` (embedder wrapper), `episode_segmenter.rs`, `event_chunker.rs`, `consolidator.rs`, `alias_resolver.rs`, `retention_purger.rs`, `extraction/` (Tier-1 regex + Tier-2 NER entity extraction), and `redaction/` (per-source sensitive-content plugins). |
| `core/brief/` | On-device "brief" (per-event summary) authoring: model lifecycle, the Qwen-based author backend, and a security tripwire. |
| `core/brief-eval/` | Offline scoring harness for brief quality (gold fixtures + scorer). |
| `core/mcp-client/` | Pure-Rust MCP client + stdio transport. Foundation for aggregating third-party MCP servers into the recall pipeline. Stdio only = process-local IPC, so the zero-network discipline holds. |

### macOS adapters (`adapters/macos/`)

| Crate | Responsibility |
|---|---|
| `MCICaptureHelper/` | The Swift capture helper — the real `CaptureSource` implementation. ScreenCaptureKit capture, Vision OCR, NSWorkspace/Accessibility/AppleScript context, sensitive-surface suppression, TCC handling, and the IPC bridge back to the Rust core. |
| `mci-embed-coreml/` | Core ML / ANE backend for the Arctic-Embed-S embedder. `cfg`-gated to macOS. |
| `mci-coreml-bridge/` | Generic Core ML model wrapper + per-model shims (Qwen brief generation; NER). |
| `mci-brain-ffi/` | Read-only C-ABI view of the brain, consumed by the SwiftUI recall UI. |
| `mci-mail-reader`, `mci-messages-reader` | Read-only "deep hook" read paths (Mail `.emlx` + Envelope Index; Messages `chat.db`) feeding entity extraction. Paired with `redaction/` plugins on ingest. |
| `mci-calendar-reader`, `mci-notes-reader`, `mci-reminders-reader` | Phase-D deep-hook adapters — **scaffold only**: public types + stubbed reads returning empty. |

### Apps (`apps/`)

| Crate | Responsibility |
|---|---|
| `apps/agent/` | The headless orchestrator/daemon. Owns the ingest pipeline and the background workers (embed, brief, episode, consolidator, Tier-2 NER, mail/messages ingest, retention, MCP aggregation), the supervisor/crash-recovery, health telemetry, and the `v2p1_gate` that gates live capture. |
| `apps/hippocampus/` | The shipping macOS app (Swift): menu-bar shell, launch/update (Sparkle/LoginItems), DMG packaging, model bundling. |
| `apps/recall-ui/` | SwiftUI recall + settings UI. Talks to the brain through `mci-brain-ffi`. |
| `apps/onboarding/` | First-run onboarding + TCC permission flow (Screen Recording / Accessibility / Automation). |
| `apps/hippocampus-native-host/` | Browser-extension native-messaging host; forwards clean page text into the pipeline with a secret filter. |

### Other

| Path | Responsibility |
|---|---|
| `server/` | Zero-knowledge sync server: encrypted delta-log store, device enrollment, crash-report intake. Never sees plaintext. |
| `adapters/windows/` | Windows `CaptureSource` adapter (WGC / Media Foundation / Windows.Media.Ocr / UIA). Scaffold, all methods stubbed. |
| `extensions/` | Optional per-browser page-text extensions (`chromium/` working; `safari/` scaffold). |
| `tools/`, `eval/` | Perf-soak harness, NER bake-off, retrieval eval corpora. |

---

## Component status — honest

| Component | Status |
|---|---|
| **Encrypted store + hybrid recall** | **Working and tested.** The SQLCipher store, FTS5 + sqlite-vec hybrid retriever, episode segmentation, retention, and the read-only FFI to the recall UI are implemented and exercised end-to-end. |
| **On-device semantic search (Arctic-Embed-S)** | **Working.** Core ML embedding pipeline (external Rust tokenization, FP16 weights, CLS-pool + L2-norm in-graph) with a quality regression test asserting cosine parity. |
| **Live screen capture (Swift helper)** | **Built but unverified, and default-OFF.** The full ScreenCaptureKit → filter chain → OCR path exists in `MCICaptureHelper`, but the live V2-P1 pipeline is gated behind the `HIPPOCAMPUS_ENABLE_V2P1` env var and has not passed the interactive on-device soak/smoke test. Shipping builds run with capture disabled. Do not assume the capture path is proven. |
| **Context join (app / window / URL / page text)** | **Implemented.** NSWorkspace + Accessibility + AppleScript URL providers landed; browser extension (Chromium MV3 + native messaging) working, Safari appex scaffold-only. |
| **Privacy controls** | **Mostly landed** (retention purger, denylist/suppression, Keychain-wrapped key, crypto-shred deletion). Real-capture verification with the extension and persistent-grant signing still owed. |
| **On-device brief author (Qwen)** | **Partial.** Rust backend complete; historically blocked on Core ML `.mlpackage` conversion. The shipping DMG bakes in the models (embedder, NER, brief) to make first-run fully offline. |
| **Encrypted cloud sync** | **Skeleton.** Server + client-side crypto + device-enrollment tests exist; cross-device convergence not proven. The zero-knowledge invariant (server holds only a hash-chained ciphertext delta log) is enforced by design and gated by review on any crypto/sync change. |
| **Deep hooks (Mail/Messages)** | **Read paths landed, read-only.** No brain write on the ingest cascade until the per-plugin redaction path is wired. Calendar/Notes/Reminders are scaffold only. |
| **Windows adapter** | **Not built.** Scaffold crate, stubbed methods. |

---

## Invariants a new contributor must not break

- **Nothing above `CaptureSource` may contain OS-specific code.** The seam is the whole cross-platform strategy.
- **One encrypted SQLite file.** Don't add a store that lives outside the SQLCipher boundary.
- **The sync server never sees plaintext.** Any crypto/sync/key change is review-gated.
- **Sensitive-capture controls ship with capture, not after** — source-level suppression (denylist / incognito / pause) is the load-bearing privacy primitive; OCR-time redaction is only defense-in-depth.
- **Nothing leaves the machine by default.** Capture, OCR, embedding, and understanding are all on-device; cloud is opt-in and encrypted.
