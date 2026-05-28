# ADR-0016 — Phase 3 OCR + Brain (Vision OCR · event chunking · arctic-embed-s · FTS5+sqlite-vec hybrid · recall UI + agent API)

- Status: Proposed (2026-05-20; CEO+CTO draft pending human CEO ratification). Protected-set authoring (AGENT_PROTOCOL §5) because the OCR'd text + embeddings + chunked events are USER CONTENT; the cascade §6 (OCR-time secret/PII regex) becomes operationally meaningful for the first time; the `0x03 → 0x04` IPC wire bump adds an `ocr_text` event payload that MUST flow through the cascade.
- Owners: **Director-Brain** (Chunker / Embedder / Retriever / Recall-UI / Agent-API; Phase 3 PRs P3.1–P3.4 + P3.7–P3.10) + **Director-Recording** (Apple Vision OCR pipeline in the Swift helper; P3.5) + **Director-Sync-Core** (`mci-brain` crate seam + SQLCipher/FTS5/sqlite-vec wiring + the `0x04` wire bump; P3.1 scaffold + P3.2 store impl + P3.6 wire bump)
- Reviewers: **CSO** (binding — every protected-set PR carries a sign-off block asserting the §4 invariants below; cascade §6 OCR-time secret/PII regex; embedding/vector storage invariants; the `0x04` wire bump payload contract); **CTO** (sequencing + cross-Director arbitration; the `mci-brain` ↔ `mci-core` ↔ `MCICaptureHelper` seams); CEO (ratification gate); CRS (telemetry-gap analyst — OCR footprint, recall quality, false-suppress / false-allow rates; arxiv/OSS scout for embedder + retrieval delta tracking)
- Phase: 3 (between Phase 2 close — context join wired into the cascade per ADR-0015 P2.5 — and Phase 4 privacy controls + the recall UI / agent API user-facing maturation)
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: OCR'd text is the **first time user-readable content reaches durable storage** in MCI. Every PR below MUST carry a CSO sign-off block asserting the §4 invariants in this ADR.
- Relationship: makes the ADR-0013 cascade §6 (OCR-time secret/PII regex) operationally meaningful for the first time (currently inert because `WorkflowContext.pageText` is always nil — ADR-0015 §1.4 explicitly defers `pageText` here); consumes the `appBundleId` + `windowTitle` + `url` populated by ADR-0015 P2.5 (Phase 2 wiring) to anchor each event; produces the events + chunks + embeddings stored in the SQLCipher+FTS5+sqlite-vec file ADR-0008 specified; implements the **event-level retrieval unit + min-max Convex Combination fusion** ADR-0010 ratified; uses the **`snowflake-arctic-embed-s` 384-d** embedder ADR-0011 ratified.

## Context

Phase 1 closes on Step 3 G2 footprint. Phase 2 lands the per-app context (`appBundleId`, `windowTitle`, `url`) into the cascade — at which point cascade §1 (source-level denylist) starts firing and `PrivacyTombstone.appBundleId` carries real values. **Phase 3 is where MCI becomes a brain.** Without it, MCI is a privacy-respecting screen recorder with a structurally-empty recall index. The "actual product" — natural-language search over everything you've done — lives entirely here.

The component decisions that drive Phase 3 are already locked by prior ADRs:

- **ADR-0008** — SQLCipher + bundled FTS5 + runtime-loaded sqlite-vec; one encrypted file `mci.sqlite`; SE-gated, biometric-controlled, non-exportable Keychain-wrapped DB key. Phase 3 is the first phase that puts **real content** into this store; Phase 0–2 only put cascade decisions / privacy tombstones / wire-protocol heartbeat data.
- **ADR-0009** — vector column pinned at 384 dimensions. arctic-embed-s and any future MRL-capable swap-in are also 384-d, so the schema is unchanged.
- **ADR-0010** — the **event** is the retrieval & index unit, not the 200–500-token chunk. Each event carries a `summary` + `entities` column (cheap idle-batch generated). Episodes group contiguous events by time-gap + content-shift. The fusion is **min-max Convex Combination** `score = w_sem·sem̂ + w_lex·lex̂ + w_rec·0.99^Δt_h + w_src·src` (start 0.5/0.3/0.15/0.05, tuned on eval). A query router chooses anchor-then-window vs LLM time-range extraction vs plain recall.
- **ADR-0011** — embedder is `snowflake-arctic-embed-s` (33M, 384-d, Apache-2.0, int8). Query and document prefixes per the model card are binding on the wrapper. Runtime: **Core ML / ANE on macOS, ONNX on Windows; MLX rejected** because it has no ANE access (energy cost on an all-day daemon is the hard constraint).
- **ADR-0013** — the cascade. §6 OCR-time secret/PII regex is the first cascade §-layer that operates on OCR'd text instead of pixels. Defense-in-depth — SecretBench shows best detectors at ~52–88% recall, so §6 is a backstop after §1–§5, never the primary guarantee. ADR-0015 §4 invariants extend: OCR'd text is content; it flows through the cascade BEFORE storage; **`.suppress`-decided events never reach the embedder or the vector store**.
- **ADR-0015** — Phase 2 populates the `WorkflowContext` fields the cascade and the brain both consume. The brain uses `appBundleId` + `windowTitle` + `url` to build the **embedding-time context header** (`[app=… | title=… | url=… | ts=…]\n<text>`) per ADR-0010 §1.3 "key expansion."

This ADR does NOT re-decide any of the above. It locks four things prior ADRs left open:

1. **The OCR pipeline.** Apple Vision Framework — which API, what concurrency model, how it pairs with the existing `CapturedSampleExtractor`/dirty-rect plumbing, how OCR'd text reaches Rust core, what the budget is.
2. **The trait shape inside `mci-brain`.** Director-Sync-Core is dispatching the scaffold today; this ADR is the contract the scaffold and every later P3.x PR honor.
3. **The PR sequence.** Eleven units, sequenced across three Directors so the `core/` ↔ `mci-brain` ↔ `MCICaptureHelper` seams converge without conflict.
4. **The privacy invariants that bind every P3.x PR** — the LOAD-BEARING set, CSO veto-gate. Because OCR'd text + chunks + embeddings are USER CONTENT, and Phase 3 is the first phase that puts user-content into durable encrypted storage, these invariants set the trust-boundary contract for the entire rest of the product.

Strategic note (per `docs/STATE.md` 2026-05-20 FIRE ALARM): screenpipe shipped at-rest encryption + bolt-on ZK sync 2026-05-02; MCI's primary remaining wedge is the **§7 corpus** (sensitive-surface suppression at capture time, Phase 1) **plus** the brain itself being **measurably higher-quality recall** than screenpipe's. Phase 3 ships the brain that has to win on quality, not just hygiene. ADR-0010's event/episode-over-flat-chunk + min-max CC fusion buys us ~15 points (MIRIX Table 1, 44.10% → 59.50%) over the naive baseline screenpipe-class systems use. ADR-0011's arctic-embed-s buys ~+24% relative MTEB-R vs the MiniLM baseline. Phase 3 has to actually ship those gains — not just describe them. This ADR is the contract.

## Decision

### 1. Per-component design — APIs, alternatives, rejection reasons

#### 1.1 OCR engine — Apple Vision Framework (`VNRecognizeTextRequest`)

- **Chosen API:** `VNRecognizeTextRequest` from Apple Vision Framework, invoked from the **Swift helper** (same process that owns the SCStream callback — no IPC for pixel buffers). Specifically: each `.allow` decision from the cascade hands the retained `CVPixelBuffer` to a `VisionOCRWorker` actor, which constructs a `VNImageRequestHandler` with `.cgImagePropertyOrientation(.up)` and submits one `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, language hints `["en-US"]` by default (configurable via per-user setting), and `automaticallyDetectsLanguage = true`. Result: `[VNRecognizedTextObservation]` — per-line text + bounding box + confidence. Output crosses the IPC seam as a structured `OCREvent` payload (see §1.6 wire bump below); raw pixels never cross IPC.
  - Apple ref: <https://developer.apple.com/documentation/vision/vnrecognizetextrequest> · <https://developer.apple.com/documentation/vision/recognizing_text_in_images>
- **Dirty-rect scoping (LOAD-BEARING for footprint).** The existing `SCStreamFrameInfo.dirtyRects` extraction in `CapturedSampleExtractor.extractSynchronously(...)` already gives us the per-frame changed regions. **Phase 3 OCR runs on the dirty-rect bounding rect (the smallest rect containing every dirty rect on that frame), not the full frame.** Apple Vision accepts a `regionOfInterest` (in normalized 0..1 coordinates) on `VNRecognizeTextRequest`. The worker computes the bounding-rect ROI, sets `request.regionOfInterest = bboxNormalized`, submits. **Static portions of the screen are never re-OCR'd.** Empty dirty-rect set ⇒ no OCR call ⇒ near-zero OCR cost on static screens — same shape as the smart-capture filter ladder.
- **Concurrency model.** Single `VisionOCRWorker` actor per session, holding a bounded MPSC channel of pending OCR jobs (default capacity = 4). The SCStream callback drops the oldest pending job if the queue is full and increments a content-free `ocr_dropped_count` on `HelperHealthCounters` (mirrors the `frames_redacted_by_failsafe` pattern from PR #47). Apple Vision under the hood uses GCD; the actor wraps `request.perform` in a `Task` that awaits its completion. Each job has a wall-clock timeout (default 1000 ms — way more than on-device Vision text-OCR needs for a single dirty-rect in practice on M-series hardware, but a real ceiling). Timeout ⇒ drop + count.
- **Why Apple Vision and not Tesseract / PaddleOCR / etc.** Vision is on-device hardware-accelerated on M-series Macs — observed latency on M-series is sub-100ms per dirty-rect for normal UI text (Apple does not publicly document whether `VNRecognizeTextRequest` uses ANE specifically; we treat ANE eligibility as plausible-but-unverified per RESEARCH_DIGEST 2026-05-18 Verification pass, and the decision rests on observed latency + on-device-no-network rather than a literal ANE claim). Tesseract is CPU-only, ~5–10× slower at comparable quality on screenshot fonts. PaddleOCR + on-device ONNX is heavier (~150 MB model) and adds a license/provenance burden. Apple Vision is already on the OS, no model to bundle, no additional license — and it has Apple's text-line-grouping heuristics tuned for UI screenshots specifically (WWDC 2019 session 234, varied-font / dense-layout handling). **No third-party OCR engine ships in Phase 3.** Windows OCR (Phase 8, `adapters/windows/`) will use `Windows.Media.Ocr.OcrEngine` — equivalent OS-bundled choice on the equivalent rationale.
- **Why not OCR in Rust core via FFI binding.** Vision is a Swift / Objective-C API; no native Rust binding exists that doesn't go through `objc2` / `swift-bridge`. ADR-0003 + ADR-0007 already keep OS code in the Swift helper. Crossing pixels back to Rust just to call OCR-via-FFI would be wasted work; sending OCR'd text TEXT (not pixels) over the existing IPC seam is the right boundary.
- **Why not pre-LLM "OCR + layout-segmentation" pipelines (SCAN arXiv:2505.14381, ScreenAI 2402.04615, Ferret-UI 2404.05719 / 2410.18967).** These are full-VLM stacks (≥1 B parameters), wrong size class for an on-device always-on daemon. They're for offline batch processing of documents, not real-time screen capture. RESEARCH_DIGEST 2026-05-18 Stream B explicitly settled this: Apple Vision (or Windows.Media.Ocr) is the right tier; the VLM stacks are out of scope until ≥Phase 6 (agent API + on-device understanding).

#### 1.2 Chunker — event-level per ADR-0010

- **Chosen design:** the **`EventChunker` production impl** of the `Chunker` trait (scaffolded by `core/mci-brain` per P3.1) implements ADR-0010 §1 in full. The unit of retrieval is the **event** (one state-transition moment per the cascade-passed frame). Each event carries the OCR'd text concatenated across the dirty-rect ROI plus the **context header prefix** `[app=… | title=… | url=… | ts=…]\n<text>` per ADR-0010 §1.3 (the LongMemEval-validated "key expansion" pattern). Sub-chunking only triggers when `event.text` exceeds the embedder's effective context (~1500 tokens for arctic-embed-s; the runtime wrapper exposes the exact ceiling); sub-chunks split on paragraph / semantic-line boundaries and inherit the parent event's context header.
- **Why event-level and not 200–500-token flat chunks.** Already decided in ADR-0010 / fork #6 / MIRIX Table 1 (44.10% flat → 59.50% structured = ~+15 points on a screenshot-memory benchmark that is the closest analog to MCI's workload). This ADR does not re-litigate it.
- **Why context-header prefix in the embedded string (and not just metadata-filtered after).** LongMemEval arXiv:2410.10813 reports +9.4% recall@5 from key expansion. The header is part of what the embedder sees, so app/title/url co-vector with the OCR text; queries like "what was that 1Password vault I had open yesterday afternoon" project onto the header's `app=com.1password.app` token, not just the body text. Already in ADR-0010, restated here so the P3.4 Chunker PR cannot quietly drop it.
- **Privacy invariant on the Chunker.** The Chunker is invoked only on `.allow`-decided events. The cascade's `.suppress` branch dead-ends the frame before any OCR'd text reaches the Chunker. The OCR worker only runs on `.allow` paths (§1.1 above); the Chunker only runs on the OCR worker's output. Cascade-before-Chunker is structural, mirrors ADR-0013 §2 redaction-before-store.

#### 1.3 Embedder — `snowflake-arctic-embed-s` per ADR-0011

- **Chosen design:** the **`ArcticEmbedSEmbedder` production impl** of the `Embedder` trait (scaffolded by `core/mci-brain` per P3.1) loads the int8-quantized arctic-embed-s model at process startup. Runtime is **Core ML on macOS** (ANE-eligible for the matmul/attention ops; the Apple Core ML conversion pipeline emits an `.mlpackage` that the daemon mmaps and runs via `MLModel`); **ONNX Runtime on Windows** (Phase 8 lands the windows-rs / ONNX-rt integration). The wrapper prepends the model-card-mandated **query/document prefixes** to every embed call: `"Represent this sentence for searching relevant passages: "` for queries; the document-side prefix for events. Output is **L2-normalized** before being written to `sqlite-vec` (ADR-0011 §3 mandate; enables the cheap-cosine-via-dot-product retrieval; preserves Matryoshka-readiness for any future swap to an MRL-capable model).
- **Why the model weights live in the signed app bundle, not downloaded at runtime.** Zero-network thesis (CLAUDE.md, DESIGN.md §9, ADR-0001). The model is ~33 M parameters int8 ⇒ ~35 MB asset; bundled in the signed `.app` (macOS) / installer payload (Windows). The supply-chain trust boundary is the signed bundle, not a remote download. Notarization (Phase 5) signs the bundle including the model — a tampered embed model is a notarization-break, not a runtime exploit window.
- **Embedding-time threading.** Embedder runs on a dedicated single-thread `BlockingPool` inside `mci-brain` (Tokio's `task::spawn_blocking` semantics; arctic-embed-s inference at int8 with batch 1 is ~5–15 ms on M2 per WWDC-Core-ML perf docs, which is small but synchronous; pulling it off the async pool prevents head-of-line blocking on the tokio runtime). The Retriever's query-time embed is on the same pool, with priority-queue ordering: interactive queries jump ahead of background idle-batch summary/entity embeds.
- **Idle-batch summary/entity embedding** (per ADR-0010 §2): a separate `IdleBatchWorker` runs on a low-priority thread, processes batches of newly-stored events when the system is idle (no recent user input + no recent SCStream callback), produces `summary` + `entities` columns, embeds the summary alongside the event. This is the lift LongMemEval validates; it does not run synchronously with capture.
- **Why not larger embedders** (arctic-embed-m-v2 768-d Matryoshka; bge-m3; gte-large): already rejected in ADR-0011 §1.2 / fork #7. 3–5× the RAM under a 250 MB ceiling for ~6% more retention.
- **Why not online-LLM embedders** (OpenAI text-embedding-3, Voyage, Cohere): zero-network thesis. Not negotiable. This is one of the things that **structurally separates MCI from screenpipe** post-FIRE-ALARM — they have at-rest encryption; we have at-rest encryption AND no remote calls for any pipeline step. The brain never phones home.

#### 1.4 Brain store — SQLCipher + FTS5 + sqlite-vec per ADR-0008

- **Chosen design:** the **`SqlCipherBrainStore` production impl** of the `BrainStore` trait (scaffolded by `core/mci-brain` per P3.1) wraps the existing `mci-core::store::open()` SQLCipher handle (PR #15) and exposes: `put_event(...)` (writes to `events` + `chunks` + `event_vectors` atomically in a single tx), `fts5_search(query, limit)` → `[(EventId, bm25)]`, `vec_search(query_emb, limit)` → `[(EventId, cosine)]`, `get_event(...)` / `get_chunk(...)` / `get_episode(...)`.
- **Schema** (consolidating ADR-0008 §3 + ADR-0010 §2 + ADR-0009 §1):
  ```sql
  CREATE TABLE events (
    id              INTEGER PRIMARY KEY,
    ts_us           INTEGER NOT NULL,            -- microsecond unix epoch
    app_bundle_id   TEXT,                        -- nullable; populated post-ADR-0015
    window_title    TEXT,                        -- nullable; populated post-ADR-0015
    url             TEXT,                        -- nullable; populated post-ADR-0015
    text            TEXT NOT NULL,               -- OCR'd text (post-cascade-.allow only)
    summary         TEXT,                        -- idle-batch generated
    entities        TEXT,                        -- JSON array; idle-batch generated
    episode_id      INTEGER,                     -- nullable; episode segmenter backfill
    cascade_reason  INTEGER NOT NULL DEFAULT 0,  -- always 0 in events table (suppressed paths never reach here; tombstones live elsewhere)
    keyframe_blob   TEXT,                        -- content-addressed blob path; nullable for text-only events
    FOREIGN KEY (episode_id) REFERENCES episodes(id)
  );
  CREATE INDEX events_ts ON events(ts_us);
  CREATE INDEX events_app ON events(app_bundle_id);
  CREATE INDEX events_episode ON events(episode_id);

  CREATE VIRTUAL TABLE events_fts USING fts5(
    text, summary, window_title, url,
    content='events', content_rowid='id',
    tokenize = "porter unicode61 remove_diacritics 2"
  );
  -- triggers keep events_fts in sync with events; standard FTS5 contentless-rowid pattern.

  CREATE TABLE event_vectors (
    event_id        INTEGER PRIMARY KEY,
    embedding       BLOB NOT NULL,               -- 384 × float32 OR 384 / 8 × byte (binary-quantized), header byte indicates
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
  );
  -- The sqlite-vec virtual table is built dynamically over event_vectors via
  -- `CREATE VIRTUAL TABLE vec_events USING vec0(embedding float32[384])`
  -- or the equivalent binary-quantized variant. Phase 3 P3.2 picks one;
  -- the scaling ladder (ADR-0011 §3) escalates from float32 to binary-q + recency pre-filter past ~10^6 events.

  CREATE TABLE chunks (
    id              INTEGER PRIMARY KEY,
    event_id        INTEGER NOT NULL,
    text            TEXT NOT NULL,
    embedding       BLOB,                        -- only filled if sub-chunked (long-event path)
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
  );

  CREATE TABLE episodes (
    id              INTEGER PRIMARY KEY,
    ts_start        INTEGER NOT NULL,
    ts_end          INTEGER NOT NULL,
    app_bundle_id   TEXT,
    summary         TEXT,
    entities        TEXT
  );
  ```
- **Blob store (keyframes).** Per ADR-0008 §1.5 the keyframe binary lives in a content-addressed encrypted blob file under the user's app-support dir; `events.keyframe_blob` is the relative path. Per-blob key derived HKDF(master, content_hash). Phase 3 P3.5 (OCR pipeline) writes the keyframe only when the cascade `.allow`s — never for `.suppress` paths.
- **One file, one writer** discipline preserved (ADR-0008 §1.4 + CLAUDE.md "PGLite is single-writer" note for the gbrain analogy). The agent process owns the single write connection; recall UI + agent API loopback use read-only connections.

#### 1.5 Retriever — hybrid FTS5 + sqlite-vec + min-max CC fusion + query router per ADR-0010

- **Chosen design:** the **`HybridRetriever` production impl** of the `Retriever` trait (scaffolded by `core/mci-brain` per P3.1) implements ADR-0010 §3 in full. Per query:
  1. **Query router decides the retrieval shape:**
     - Plain recall (default): semantic + lexical hybrid.
     - Anchor-then-window ("what was I looking at right before X"): first retrieve top-1 hit by semantic similarity, then a time-window expansion ±5 minutes around its `ts_us` and re-rank.
     - LLM time-range extraction ("show me last Tuesday afternoon"): the agent shell calls a tiny on-device classifier or a regex-based date-phrase extractor (Phase 3 P3.7 picks one; favor regex first, classifier second) to produce a `TimeRange`; pre-filter events to the range, then run plain recall inside it.
  2. **Lexical:** FTS5 `MATCH` over `events_fts` with the BM25-ranked top-`k_lex` (default 200).
  3. **Semantic:** embed the query (with the query prefix per ADR-0011), `sqlite-vec` cosine over `event_vectors` for the top-`k_sem` (default 200).
  4. **Min-max normalization** of both score lists (Bruch et al. TOIS 2023; arXiv:2210.11934): rescale each list to [0,1] inside the response set.
  5. **Fuse** per ADR-0010 §3: `score = w_sem·sem̂ + w_lex·lex̂ + w_rec·0.99^Δt_h + w_src·src` with default weights `0.5 / 0.3 / 0.15 / 0.05`. Source weight reserved for downstream features (browser-extension page-text Phase 7; manual user-tag).
  6. **Time-decay** is a multiplier inside the fusion, not a hard filter. Old events still surface when content is a very strong match; recency tips ties.
  7. **App / source filter** is a hard pre-filter (SQL `WHERE app_bundle_id = …`).
  8. **Return** top-`limit` `RetrievalHit { event_id, score_lexical, score_semantic, score_recency, score_combined }`. Recall UI + agent API consume the same shape.
- **Why not pure-semantic.** Bruch et al. (TOIS 2023, primary-source verified in RESEARCH_DIGEST Verification pass) shows hybrid beats pure-semantic on out-of-domain queries. Screenshot text is heterogeneous (code, UI, OCR errors); lexical BM25 robust to those. Hybrid is binding.
- **Why min-max CC and not RRF.** Already in ADR-0010 §3 / Bruch et al. "RRF sensitive to parameters; CC outperforms RRF in- and out-of-domain." This ADR does not re-litigate.
- **Why the query router and not a single fused retriever.** Workload split: "right before X" / "last Tuesday" are temporally-anchored queries where pure-similarity fails (the anchor is a content match but the answer is a time-window expansion); plain recall handles the bulk. ADR-0010 §3 already specifies the router; this ADR locks the per-route decisions.

#### 1.6 IPC wire bump `0x03 → 0x04` — new `OCREvent` message type

- **Chosen design:** the existing `HelperHealth` (`0x01`), `PrivacyTombstone` (`0x02`), and the wire-frame header all stay. Phase 3 adds `OCREvent` (`0x03` for the message type — distinct from the wire-frame-version byte which goes `0x03 → 0x04`). Payload:
  ```rust
  // core/src/ipc/wire.rs (Phase 3 P3.6 extension)
  pub const OCR_EVENT_MSG_TYPE: u16 = 0x0020;  // distinct slot from HelperHealth (0x0001) etc.
  pub struct OCREventPayload {
      pub seq:               u64,
      pub ts_us:             u64,
      pub app_bundle_id:     [u8; 64],    // bounded, null-padded; mirror PrivacyTombstone discipline
      pub window_title_len:  u16,
      pub url_len:           u16,
      pub ocr_text_len:      u32,         // capped per-event (default 64 KB; helper-side enforced)
      // followed by:
      //   window_title bytes (window_title_len)
      //   url bytes          (url_len)
      //   ocr_text bytes     (ocr_text_len, UTF-8)
      //   keyframe_hash      ([u8; 32], blake3 of the keyframe blob)
  }
  ```
- **Lock-step bump across Swift / Rust / Python tooling** — mirrors PR #44's 0x02→0x03 discipline exactly. Wire-frame-version goes `0x03 → 0x04`; all three of `Wire.swift`, `core/src/ipc/wire.rs`, and `tools/wire_decode.py` bump in the same PR (P3.6). Byte-exact cross-side fixture (`ocr_event_cross_side_fixture` Rust ≡ `testOCREventCrossSideFixture` Swift) pins the layout. Decode tripwires reject old-`0x03` frames at the new layout AND reject malformed/truncated `OCREventPayload`s.
- **Privacy invariants on the wire.** The `ocr_text` field is **post-cascade**. The helper-side P3.6 logic is: cascade decides `.allow` → OCR worker runs → cascade §6 (OCR-time secret/PII regex; SecretBench-tuned, ADR-0013 §6) is **re-run against the OCR'd text** because OCR'd text is a new input the cascade didn't have at frame time → if §6 fires, the event becomes `.suppress(reason=6)` and emits a `PrivacyTombstone(reason=6)` instead of an `OCREvent`. **`OCREvent` is only emitted for events that cleared the cascade twice — once on pixels, once on OCR'd text.** This is the load-bearing trust boundary for Phase 3.
- **No raw pixels cross IPC.** The blob is written by the Swift helper directly to disk via `mci-core::store::open_blob_writer(...)` (the encryption boundary is in `mci-core`; the helper hands cleartext bytes for the keyframe to that writer, which encrypts + writes; the helper never touches the master key). The hash crosses the wire; the bytes don't.

### 2. `mci-brain` traits — OS-free protocol, headless testability

Director-Sync-Core is dispatching the **P3.1 scaffold PR** today (Terminal 3 in this orchestrator's morning sprint). This ADR is its contract. The traits below are what the scaffold ships:

```rust
// core/brain/src/lib.rs (P3.1 scaffold; P3.2–P3.4 fill the impls)

pub trait Chunker: Send + Sync {
    fn chunk(&self, event_text: &str) -> Result<Vec<String>, ChunkerError>;
}

pub trait Embedder: Send + Sync {
    fn dimension(&self) -> usize;
    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError>;
    fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, EmbedError> { /* default: loop embed_one */ }
}

pub trait BrainStore: Send + Sync {
    fn put_event(&self, event: &Event) -> Result<EventId, StoreError>;
    fn get_event(&self, id: EventId) -> Result<Option<Event>, StoreError>;
    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(EventId, f32)>, StoreError>;
    fn vec_search(&self, query_embedding: &[f32], limit: usize) -> Result<Vec<(EventId, f32)>, StoreError>;
    // chunks + episodes + idle-batch summary/entity writers added in P3.2/P3.4/P3.8
}

pub trait Retriever: Send + Sync {
    fn retrieve(&self, query: &RetrievalQuery) -> Result<Vec<RetrievalHit>, RetrieveError>;
}
```

Production impls live in `core/brain/src/{event_chunker.rs, arctic_embed_s.rs, sqlcipher_brain_store.rs, hybrid_retriever.rs}`. Each is matched by a stub impl in `core/brain/src/stubs.rs` (`NoopChunker`, `FixedDimEmbedder`, `InMemoryBrainStore`, `StubRetriever`) for headless testing — same pattern as ADR-0015's `StubContextProvider`. The `core/` crate is OS-free; OS-bound bits (Core ML embedder runtime, Apple Vision OCR) live in `adapters/macos/` and call across the existing seam.

### 3. Footprint budget — per-component caps

The Phase-1 SLO (`≤1–2% one CPU core, ≤250 MB RAM` over an all-day session) must hold through Phase 3. The Phase-1 G2 footprint baseline is the helper at 3.6 MB / 0% CPU idle (Step-2 v6, pre-read). Phase 3 adds:

| Component | RAM ceiling (incremental) | CPU ceiling (steady-state) | Notes |
|---|---|---|---|
| Apple Vision OCR worker | +20 MB working set (Apple-managed accelerator path) | estimated 1–5% on `.allow` frames, ~0% on `.suppress`/static (measure at P3.5 + P3.11) | hardware-accelerated on M-series Macs; Intel Macs likely CPU-only with higher spikes — Phase 8 cross-platform consideration |
| arctic-embed-s in-process | +40 MB (model + Core ML runtime) | ~5–15 ms per embed call | model mmap'd, shared between query + idle-batch embed |
| SQLCipher write connection | +5 MB | ~0% steady-state; spikes on commit | already accounted for in the Phase 0 baseline |
| sqlite-vec brute-force | scales with corpus | scales with corpus | scaling ladder per ADR-0011 §3 |
| Idle-batch summary/entity worker | +10 MB | runs only when idle | priority-throttled |
| Recall-UI separate process | +50 MB | only when UI open | not part of always-on daemon |
| Agent-API loopback | +5 MB | ~0% idle | only active under request |
| **Total Phase 3 incremental** | **~+80 MB worst case** | **~5–15% transient on `.allow`, ~0% idle** | Headroom against 250 MB total budget: ~170 MB |

CRS Telemetry-Gap analyst monitors. **Any Phase 3 PR that breaks the per-component cap by >20% is auto-flagged for CSO + CEO review.** Real-Mac measurement on a workday is owed at P3.11 (live-Mac audit doc).

### 4. Privacy invariants — LOAD-BEARING (CSO veto-gate per ADR-0013 §5 + ADR-0015 §4 + this ADR)

These invariants are why this ADR is protected-set. Any future PR that weakens any of them requires a fresh CSO amending ADR.

1. **OCR'd text is USER CONTENT.** It crosses the cascade BEFORE storage, same as ADR-0015 §4.1's framing for `windowTitle` / `url`. The helper never persists OCR'd text ahead of a cascade decision.
2. **Cascade-twice for OCR.** The cascade runs on pixels at frame time (§1–§5 + §7); on `.allow` the OCR worker runs; **the cascade §6 (OCR-time secret/PII regex; SecretBench-tuned per ADR-0013 §6) re-runs against the OCR'd text**. Only events that clear BOTH cascades become `OCREvent` payloads on the wire and reach the store. Events that clear pixels but fail §6 on text become `PrivacyTombstone(reason=6)` instead — no OCR'd text bytes cross the wire, no embedding is computed, no event row is inserted. **OCR-emit is NOT gated on encode-success.** A VideoToolbox HEVC failure on the `.allow` branch must not silently mute the OCR emitter: the cascade is the structural gate, and the encoder's role is to produce an HEVC blob for the recall timeline (post-§7-corpus / post-key-plumbing) — never to authorize OCR. Encoder failures are absorbed into the content-free `frames_encode_failed` HelperHealth counter (wire `0x06 → 0x07`) and the cascade-twice emitter still runs. Pin: `docs/research/ocr-emit-silence-2026-05-28.md` + the PR that closed it. The structural test is `SCStreamPipelineTests.test_throwing_encoder_returns_encoded_and_increments_counter`.
3. **Embeddings of suppressed events MUST NOT be stored.** The Chunker / Embedder / BrainStore path is invoked ONLY on the `OCREvent` (twice-cleared) wire arm. The IPC seam structurally cannot deliver a `PrivacyTombstone` to the brain — the consumer enum match in `mci-core::ipc::receive` dispatches `PrivacyTombstone` to the tombstone-log writer and `OCREvent` to the brain ingestor; there is no path from the former to the latter.
4. **No network calls in any Phase 3 component.** The embedder runs locally (Core ML / ONNX, bundled weights). The Chunker is pure Rust. The Retriever is pure Rust. The OCR worker is Apple Vision (on-device). The recall UI + agent API are loopback-only. **MCI's brain never phones home, structurally.** This is one of the two things that separate MCI from screenpipe post-FIRE-ALARM (the other is the §7 corpus). Allowlisting any network call from a Phase 3 component requires a fresh CSO + CEO ADR.
5. **Recall-UI privacy moments are opaque.** When the user browses the timeline, suppressed events surface as redacted cards (`"MCI redacted this — app X — reason Y"`) — never the OCR'd text, never the keyframe, never the embedding. The PrivacyTombstone row carries `appBundleId` + `reason` (post-ADR-0015) and that's it. Same trust-by-audit posture as F-STRAT-001b.
6. **The idle-batch summary/entity worker runs only on `.allow`-stored events.** Its input is the `events.text` column for events already in the store. It can never see a suppressed event because suppressed events don't have rows in `events`. CSO veto-gate on any change to the idle-batch worker's input query.
7. **No telemetry payload may include OCR'd text or embedding bytes.** The CRS Telemetry-Gap analyst gets counts only — `ocr_dropped_count`, `ocr_text_secret_match_count`, `vec_search_latency_us`, `fts5_search_latency_us`. Mirrors the ADR-0015 §4.6 invariant. This is the same `HelperHealthSnapshot` discipline (wire 0x03 → 0x04, payload-strict-consumption tripwires preserved).
8. **Keyframe blob writes are post-cascade-twice as well.** A keyframe blob exists on disk only for events that produced an `OCREvent` (cleared both cascades). Suppressed events have no blob path written. CSO veto-gate on any change to the keyframe-blob-write trigger.
9. **OCR'd text is capped per-event (default 64 KB).** Bounded payload — defense-in-depth against an OCR run pathologically producing megabytes of text from a frame, and against a malicious app constructing a frame full of garbage to balloon the store. Helper-side enforced; an over-cap OCR result triggers `PrivacyTombstone(reason=7 /* catchall */)` instead of an `OCREvent`. (Per ADR-0013 §7 fail-closed default.)

### 5. How this unlocks Phase 3 capabilities

- **Natural-language search over everything you've seen** (the product). For the first time after Phase 3, `mci-agent search "the contract clause about indemnification we reviewed last Tuesday"` returns event hits with context (app, title, url, keyframe thumbnail, OCR snippet). Today no recall surface exists; Phase 3 ships it.
- **The cascade §6 (OCR-time secret/PII regex) becomes operationally meaningful.** Currently inert (ADR-0013 §6 was structurally untestable in Phase 1 — no OCR pipeline). Phase 3 makes it the second cascade pass on every event, defense-in-depth against secrets that pixel-side §1–§5 missed.
- **The agent API loopback** (P3.10) gives any local agent (Claude Code, Cursor, Codex, etc.) read access to the brain over a localhost socket. MCP-compatible; the agent can call `mci/recall?q=...&limit=10` and get back the same `RetrievalHit` shape the recall UI uses. **This is the line where MCI becomes useful to other agents, not just the human user.**
- **`known-safe-apps.toml` allowlist** (ADR-0013 §3 + ADR-0015 §5) becomes operationally testable for the first time. Once we know an app is safe for capture (CSO-gated per-bundle entry), its events flow through the full pipeline and surface in recall. The Phase-1 cascade gate's strict default-OFF for `--capture` flips per-app on CSO sign-off + a Phase-3 audit doc showing zero §6 false-negatives on that app's representative content.

### 6. PR sequence — Director-Sync-Core + Director-Recording + Director-Brain own per their scope; CSO gates each

Phase 3 lands as an 11-PR sequence. Each PR carries a CSO sign-off block asserting the §4 invariants above. **The 3-PRs-per-night-run cap (AGENT_PROTOCOL §1) means Phase 3 takes ≥ 4 attended sprints end-to-end** — comparable to Phase 1's actual delivered cadence (cycles 1 / 1.5 / 2 / 3 across two weeks). CEO-attended cycles can compress this; the sequence is the same.

- **P3.1 — `core/mci-brain` crate scaffold + traits + stubs + tests.** Director-Sync-Core. **In flight today** (Terminal 3 dispatch in this orchestrator session). 1 cycle. NO production impls; sets the seam. Already specified in the Terminal 3 prompt.
- **P3.2 — `SqlCipherBrainStore` production impl.** Director-Sync-Core. Wraps `mci-core::store::open()` (PR #15) with the schema in §1.4 above. Migrations live in `core/brain/migrations/`. Loads `sqlite-vec` extension at connection-open (signed-bundle-path-only per ADR-0008 §1.3). Tests cover put → get round-trip, FTS5 BM25 ranking, sqlite-vec cosine ranking, ON DELETE CASCADE, transaction atomicity. 1 cycle.
- **P3.3 — `ArcticEmbedSEmbedder` Core ML runtime.** Director-Brain. Bundles the int8 arctic-embed-s `.mlpackage` in the macOS helper bundle (ADR-0011 §1 + §3). Wraps the model with the query/document prefix discipline (ADR-0011 §3). L2-normalize before return (ADR-0011 §3). Tests cover dimension=384, prefix-applied, output-L2-norm. 1 cycle. **macOS-first**; ONNX/Windows lands at Phase 8.
- **P3.4 — `EventChunker` production impl** per ADR-0010 §1. Director-Brain. Context-header prefix, sub-chunking only for long events, paragraph/semantic boundary splitter. Tests cover the §1.2 invariants. 1 cycle.
- **P3.5 — Apple Vision OCR pipeline in `MCICaptureHelper`.** Director-Recording. `VisionOCRWorker` actor, dirty-rect ROI scoping, bounded MPSC channel, content-free `ocr_dropped_count` counter. **Does NOT cross the IPC seam yet** — the OCR output is logged stderr-only for first-pass live verification. P3.6 wires it to the wire. 1 cycle. Protected-set; CSO sign-off asserts the dirty-rect ROI scoping is in place and the OCR worker only runs on `.allow` paths.
- **P3.6 — Wire schema `0x03 → 0x04` + `OCREvent` payload + cascade-twice plumbing.** Director-Sync-Core for the `core/` side + Director-Recording for the Swift side. Helper-side cascade §6 re-runs over OCR'd text per §1.6 above; only events that clear BOTH cascades emit `OCREvent`. Lock-step bump across Swift + Rust + Python tooling, byte-exact cross-side fixture pinning the 72-byte (or whatever-N-byte) payload. 1 cycle. **Trust-boundary moment** — context bytes reach the wire for real. Same gravity as PR P2.5 in ADR-0015.
- **P3.7 — `HybridRetriever` production impl + query router.** Director-Brain. Implements §1.5 in full: query-prefix embed → FTS5 + sqlite-vec parallel → min-max CC fusion → time-decay → top-k return. Query router: plain / anchor-then-window / time-range extraction (regex-based first; classifier follow-on). Tests cover the fusion math, the router decision matrix, time-window expansion, app-pre-filter. 1 cycle.
- **P3.8 — Idle-batch summary + entity worker.** Director-Brain. Low-priority background thread; processes newly-stored events when system idle; populates `summary` + `entities` columns; embeds the summary alongside the event. Uses a small on-device LLM for summary (the candidate is `Llama-3.2-1B-Instruct` int4 or smaller; final pick at P3.8 cycle); regex+dictionary for entities (the LLM is overkill for NER on screenshot text — start with the cheap thing). 1 cycle.
- **P3.9 — Recall UI v1.** Director-Brain (owns the brain UX; could route to Director-Context if separate). SwiftUI app `apps/recall-ui/` (does not exist yet); read-only SQLCipher connection; timeline + search; privacy-moment cards for tombstones. Lives in `apps/recall-ui/`. 1 cycle.
- **P3.10 — Agent API loopback (localhost MCP).** Director-Brain. `apps/agent/` exposes a localhost MCP server (existing tokio stack); routes are `recall` (semantic + lexical query), `event` (id lookup), `episode` (id lookup), `timeline` (range query). Read-only — no mutation. Auth: shared-secret rotated per-launch (the `mci-agent` daemon writes it to `~/Library/Application Support/MCI/agent_secret`; clients read it). 1 cycle.
- **P3.11 — Live-Mac audit doc + Phase 3 close.** Human-in-the-loop, on the real machine. Reuses the Step-1/Step-2 audit-harness pattern. Verifies: OCR fires on `.allow`-decided frames within bounded latency; secret-regex catches a representative SecretBench corpus on the OCR side; embeddings are within retrieval-quality tolerance vs the pre-recorded eval set; footprint deltas per §3 above hold on a real workday; no PII leaks above what tombstone payloads document; recall queries return correctly-ranked hits. Output: `docs/audit/2026-XX-XX-phase3-ocr-brain.md`. 1 cycle. **Phase 3 → Phase 4 gate flips on this audit.**

### 7. Test discipline (binding on every PR in §6)

- **Headless unit tests.** Trait stubs cover the decision matrices; same pattern as ADR-0015's `StubContextProvider`. Mirrors PR #36/#37/#38's `Stub*Probe` discipline.
- **Integration test — cascade-twice fail-closed.** A test asserts: for any synthetic OCR text matching the SecretBench-tuned regex, the helper produces a `PrivacyTombstone(reason=6)` AND does NOT produce an `OCREvent`. The test runs against the production `SuppressionCascade` + a stub OCR worker that injects canned text. Pins §4.2.
- **Privacy tripwire test (CSO-protected).** A test asserts that for any cascade decision that resolves to `.suppress` at frame time, no `OCREvent` is emitted regardless of what the OCR worker would have produced. Today this is structurally guaranteed by the order-of-operations (cascade-before-OCR-worker); the test documents it so future refactors cannot accidentally re-order.
- **Embedding-side tripwire.** A test asserts that `BrainStore.put_event` is never called on a `PrivacyTombstone`-typed message (the IPC dispatch is enum-matched; mis-routing breaks the type system). Cargo trybuild-style negative compilation check is ideal here.
- **Retrieval-quality eval (binding before P3.7 merges).** Per ADR-0010 §4 + the RESEARCH_DIGEST plan, build a LongMemEval / ScreenshotVQA-style fixture on consented synthetic capture (NOT user data — we have none yet); measure Recall@k / NDCG@k for the hybrid retriever vs the lexical-only and semantic-only baselines; gate P3.7 merge on hybrid winning. Eval fixtures live in `core/brain/eval/`; results PR'd as `docs/audit/2026-XX-XX-phase3-retrieval-eval.md`.
- **Footprint measurement on every Phase-3 PR that touches the hot path** (P3.3, P3.5, P3.6, P3.7, P3.8). Helper RSS / CPU samples (same `tools/footprint_measure.sh` from PR #42) before and after the PR's incremental load. Per-component cap from §3 above is binding.
- **Live verification (P3.11 only, human-in-the-loop).** Audit doc captures real-machine observations. Not faked. Per AGENT_PROTOCOL §9 hard-stops, footprint claims on Phase 3 are HUMAN-ONLY measurements — never auto-passed by the loop.

### 8. Material-choice trade-offs called out explicitly

- **Apple Vision vs Tesseract vs PaddleOCR.** Vision won on observed on-device latency + Apple's screenshot-tuned text-line heuristics + no model to bundle + no extra license. Specific accelerator path (ANE / GPU / CPU) is Apple-managed and not publicly documented; the decision rests on observed latency, not a literal ANE claim. Tesseract was the fallback floor; Paddle was rejected for size + license. Re-consider only on Windows (Phase 8 picks Windows.Media.Ocr equivalently).
- **OCR in Swift helper vs OCR in Rust core.** Swift helper. Pixel buffers stay in-process with the SCStream callback; OCR text crosses IPC (small payload) instead of pixels (large). Already an ADR-0003/0007 boundary; this ADR restates it for OCR specifically.
- **Cascade-twice vs cascade-once-on-pixels.** Cascade-twice. The §6 OCR-time secret/PII regex catches things pixel-side §1–§5 cannot (a password that wasn't in a secure field, a PII string in a window-title regex that didn't match the AX subrole signal). Defense-in-depth, mandated by ADR-0013 §6.
- **Bundle the embedder model in the signed `.app` vs download at first launch.** Bundle. Zero-network thesis; supply-chain trust = notarization signature on the bundle. Cost: +35 MB installer; acceptable.
- **Idle-batch summary via on-device LLM vs cheap regex + dictionary NER.** Both. NER is regex+dictionary (cheap, deterministic; runs synchronously with the event-write). Summary is a small on-device LLM (the candidate is Llama-3.2-1B-Instruct int4 or smaller; final pick at P3.8 cycle) running in idle batches; never on the hot path.
- **Recall UI as a separate SwiftUI app vs embedded in `mci-agent`.** Separate. `mci-agent` is an always-on background daemon; the recall UI is a user-facing app launched on demand. Crash isolation; clean privilege separation (recall UI gets a read-only SQLCipher connection). Mirrors the ADR-0007 helper-vs-agent split.
- **Agent API at localhost MCP vs a custom REST.** MCP. Compatible with the broader local-AI-tool ecosystem (Claude Code, Cursor, Codex, etc., all already speak MCP). Custom REST is reinventing the wheel; loses ecosystem leverage.
- **Per-event OCR vs per-frame OCR.** Per-event (an event already aggregates dirty-rects from one or more frames; OCR is invoked once per accepted event). Per-frame OCR would 10×–60× the OCR cost for zero quality lift; events are already the unit of state-transition.
- **Dirty-rect ROI vs full-frame OCR.** Dirty-rect. Same rationale as the smart-capture filter ladder — never re-process static content.

### 9. Out of scope (explicitly deferred)

- **Browser-extension page text** — Phase 7. The OCR pipeline ships first; the WebExtension's clean-page-text path is a quality lift on top of (not replacement for) OCR.
- **VLM-based OCR / layout-segmentation** (ScreenAI, Ferret-UI, OmniParser) — out of scope until ≥Phase 6. Wrong size class for an always-on daemon today.
- **Windows OCR adapter** — Phase 8. Equivalent ADR owed at Phase 8 (`Windows.Media.Ocr.OcrEngine` instead of Apple Vision; ONNX instead of Core ML; UIA instead of AX for window-title); the trait seams here are OS-free and will hold.
- **Multi-language OCR tuning** — Phase 3 ships with `["en-US"]` default + `automaticallyDetectsLanguage = true`. Per-user language list configuration is Phase 4 (privacy/onboarding UX) territory.
- **Cross-device retrieval merging** — Phase 5 (zero-knowledge encrypted sync). Phase 3's recall is single-device.
- **Embedder fine-tuning on user's own corpus** — out of scope. arctic-embed-s zero-shot is the baseline; fine-tuning a per-user model breaks the zero-network thesis (model gradients are content-derived). Re-consider only with a CSO-signed ADR.
- **Auto-flip of `--capture` default-ON globally** — still ADR-0013 Amendment 1 §4 / CSO-gated, per-app via the allowlist. Phase 3 unlocks the **mechanism** (twice-cleared events surface in recall); the **policy** (which apps go in `known-safe-apps.toml`) is CSO + CEO per app.
- **Retention/compaction policy** — Phase 9. Phase 3 stores keyframes + text + embeddings indefinitely; the age-out ladder (DESIGN.md §11) lands later.
- **Recall-UI search-result UX polish** — Phase 4. P3.9 ships a functional v1; Phase 4 makes it good.

## Consequences

- Positive: MCI becomes a brain for the first time. Natural-language recall over everything captured. The `known-safe-apps.toml` allowlist becomes operationally testable (post-P3.11, per-app); `--capture` can start flipping default-ON per app under CSO sign-off. The agent-API loopback opens MCI to other local agents — distribution leverage beyond just the human user.
- Positive: cascade §6 (OCR-time secret/PII regex) becomes a real defense layer for the first time. The §7-corpus wedge (the post-FIRE-ALARM primary remaining wedge) gains a second pass on text content that screenpipe cannot match without redesigning their stack.
- Positive: every per-component trait is OS-free; Phase 8 (Windows adapter) inherits the seam unchanged. ONNX-runtime swap for Core ML + Windows.Media.Ocr swap for Apple Vision are the only OS-bound replacements.
- Positive: the eval discipline (§7 binding-before-P3.7) means recall quality is provably better than baselines BEFORE we claim it. Not retrofit; baked into the merge gate.
- Negative / tradeoff: Phase 3 adds the largest incremental footprint MCI has taken on yet (~+80 MB worst case). G2 footprint baseline from Phase 1 must hold AFTER Phase 3 lands; P3.11 audit measures this and is the gate.
- Negative / tradeoff: 11 PRs in sequence is a long phase. CRS Telemetry-Gap analyst owns "Phase 3 PR cadence health" — any PR sitting open >5 days surfaces a status flag in the daily digest.
- Negative / tradeoff: bundling a 35 MB embedder model + a 500 MB small-LLM-int4 (Llama-3.2-1B; pick TBD) is a non-trivial installer size jump. Distribution implication for the Phase 5 packaging work — direct-download is fine, but a Mac App Store path would need scrutiny (App Store bundle-size limits + on-demand-resources discussion).
- Forces (binding on every future PR):
  - **Any new path that lets OCR'd text reach storage without passing through the cascade twice is a §4 protected-set violation.**
  - **Any new path that lets a `PrivacyTombstone` reach the brain ingestor is a §4 protected-set violation.**
  - **Any Phase-3 component that makes a network call is a §4.4 violation.** Re-consider only on a fresh CSO + CEO ADR.
  - **Any change to the `OCREvent` wire payload requires a lock-step bump across Swift / Rust / Python.** Same discipline as PR #44.
  - **Any change widening the per-app `known-safe-apps.toml` allowlist requires CSO sign-off**, exactly as ADR-0013 §3 / §6 + ADR-0015 §5 already specifies.

## CSO sign-off (placeholder — owed at first protected-set PR in §6)

Protected-set authoring (AGENT_PROTOCOL §5). The §4 privacy invariants — OCR'd text is content; cascade-twice for OCR; embeddings of suppressed events never stored; no network in any Phase 3 component; recall-UI privacy moments opaque; idle-batch worker reads `.allow`-stored events only; telemetry payload content-free; keyframe blobs post-cascade-twice; per-event OCR text capped — are binding. CSO sign-off blocks are owed on every PR in §6 asserting (by reading the diff) that the invariants hold. CSO veto is final unless the human CEO overrides.

— CSO, pending (this ADR is a CEO ratification gate; CSO sign-off is owed at PR P3.1 / P3.2 / P3.6 protected-set moments)

## Director sign-offs (placeholders — owed at PR P3.1 / P3.5)

The Phase-3 PR sequence in §6 is split across three Directors:

- **Director-Sync-Core** (P3.1 scaffold + P3.2 store + P3.6 wire) — acknowledged: scaffold is OS-free, no `cfg(target_os)`, `#![forbid(unsafe_code)]` preserved on `mci-brain`; store impl loads sqlite-vec from signed-bundle path only; wire bump is lock-step across all three sides + byte-exact cross-side fixture.
- **Director-Recording** (P3.5 OCR + P3.6 Swift side) — acknowledged: OCR worker runs only on `.allow` paths; dirty-rect ROI scoping is structural (no full-frame OCR); cascade §6 re-runs over OCR'd text before any IPC emission; OCR text capped at 64 KB per event.
- **Director-Brain** (P3.3 embedder + P3.4 chunker + P3.7 retriever + P3.8 idle-batch + P3.9 recall UI + P3.10 agent API) — acknowledged: arctic-embed-s int8 with query/document prefixes; L2-normalized output; event-level chunker with context header per ADR-0010; min-max CC fusion + query router; idle-batch on `.allow`-stored events only; recall UI read-only connection; agent API loopback-only + shared-secret-rotated-per-launch.

— Director-Sync-Core / Director-Recording / Director-Brain, pending (owed at PR P3.1 / P3.5 respectively)

## References

- **ADR-0001** (privacy posture — local-first, E2E, minimum-data-collection; zero-network thesis = §4.4 invariant). **ADR-0003** (no OS code above the `CaptureSource` seam — Phase 3 honors this, OS code lives in `adapters/macos/` for OCR + Core ML embedder). **ADR-0007** (separate signed macOS helper — OCR worker lives in the helper). **ADR-0008** (encrypted store — Phase 3 fills the schema for real). **ADR-0009** (vector dim pinned at 384 — arctic-embed-s honors this). **ADR-0010** (event/episode retrieval unit + min-max CC fusion + query router — Phase 3 implements all three). **ADR-0011** (arctic-embed-s 384-d, int8, Apache-2.0; query/document prefixes binding). **ADR-0012** (zero-knowledge spec tightening — Phase 3 plaintext-residency rules in §4 hold the line). **ADR-0013** + Amendment 1 (the cascade Phase 3 feeds; §6 OCR-time secret/PII regex becomes operationally meaningful for the first time). **ADR-0014** (fd-pass seam — unchanged this phase; OCR text flows on a separate `OCREvent` message type). **ADR-0015** (Phase 2 context join — Phase 3 consumes the populated `appBundleId` + `windowTitle` + `url` to build the embedding-time context header per ADR-0010 §1.3).
- **`docs/STATE.md`** (2026-05-20 — Phase 1 close state + screenpipe-encryption reframe → §7 corpus + the brain quality itself are MCI's primary remaining wedges → Phase 3 ships the brain that must win on quality, not just hygiene).
- **`docs/AGENT_PROTOCOL.md`** §4 (footprint budget), §5 (CSO protected-set + veto-gate), §8 (ADR-required for material choices), §9 (autonomous-mode hard stops — Phase 3 footprint claims are HUMAN-ONLY).
- **`docs/DESIGN.md`** §8 (brain index design), §12 (schema), §13 (embedder), §15 Phase 3 ("OCR + brain. Vision OCR (dirty-rect scoped) → chunk → MiniLM embed → SQLite FTS5+sqlite-vec → hybrid recall. Local recall UI v1." — this ADR replaces the MiniLM call-out with arctic-embed-s per ADR-0011, fully expands every other item), §16 R4 (OCR + embedding are the real energy cost — addressed by dirty-rect ROI scoping + idle-batch separation in §1 above), R7 (embedding quality on heterogeneous screen text unproven — addressed by the eval discipline in §7 binding-before-P3.7).
- **`docs/RESEARCH_DIGEST.md`** 2026-05-18 Stream B + C + D (OCR / memory / embeddings, all primary-source-verified in the Verification pass): MIRIX 2507.07957, LongMemEval 2410.10813, Bruch 2210.11934 (fusion, TOIS 2023), Lifelog review 2506.06743 (recall r=0.75 dominant), arctic-embed-s HF card (33M, 384-d, 51.98 MTEB-R), sqlite-vec brute-force + 124 ms/1M-binary, Apple Vision WWDC19 session 234 (varied-font / dense-layout).
- **`docs/COMPETITORS.md`** [001] (screenpipe encryption FIRE ALARM — §7 corpus + brain-quality reframe; Phase 3 ships the brain-quality side of the wedge).
- **`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamCaptureSession.swift`** — the SCStream callback hands `CVPixelBuffer` to the OCR worker on `.allow` decisions; OCR worker lives in `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/` (new directory).
- **`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift`** — the §6 OCR-time secret/PII regex re-runs on OCR'd text (P3.6 wires the second cascade pass).
- **`core/src/ipc/wire.rs`** — `0x03 → 0x04` wire-frame-version bump; new `OCR_EVENT_MSG_TYPE` slot.
- **`core/brain/`** — new crate; the seam lands at P3.1.
- **`apps/agent/`** — gains the localhost-MCP recall API at P3.10.
- **`apps/recall-ui/`** — new app at P3.9.
- Apple — `VNRecognizeTextRequest` <https://developer.apple.com/documentation/vision/vnrecognizetextrequest>; Core ML `MLModel` <https://developer.apple.com/documentation/coreml/mlmodel>; ScreenCaptureKit `SCStreamFrameInfo.dirtyRects` <https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo>. WWDC 2019 session 234 (Vision-text-recognition heuristics for screenshots).
- Phase-4 dependency: DESIGN.md §15 Phase 4 (privacy controls + onboarding UX) wraps around the recall UI Phase 3 ships and the brain content Phase 3 produces. Phase 4 ADR is owed at Phase 3 close.
