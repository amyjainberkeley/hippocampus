//! Wire-to-brain ingest pump — PR P3.6.6.
//!
//! Closes the demo-path gap between the `0x04` IPC wire (`mci-capture-helper`
//! emits twice-cleared [`Message::OCREvent`] frames per ADR-0016 §1.6 /
//! P3.6) and the durable Phase-3 brain store
//! (`mci_brain::SqlCipherBrainStore`, P3.2).
//!
//! # What this module does
//!
//! - Defines the [`BrainIngestor`] trait — one method, `ingest_ocr_event`,
//!   accepting a `&Message`. By construction the trait only acts on
//!   [`Message::OCREvent`]; any other variant returns
//!   [`IngestOutcome::NotOcrEvent`] without touching the store. This is the
//!   *structural* part of the §4.3 invariant (`PrivacyTombstone` cannot
//!   reach `BrainStore::put_event` because the IPC `Routed` enum dispatches
//!   it to the tombstone-log writer — see `mci_core::ipc::connection::Routed`
//!   — and the brain-side handler refuses anything that isn't an
//!   `OCREvent`).
//! - Provides [`BrainPump`], the production composite: a
//!   `dyn mci_brain::BrainStore` writer + an `Option<dyn mci_brain::Embedder>`
//!   (None when the on-disk `arctic-embed-s.mlpackage` isn't bundled yet;
//!   events still ingest with `embedding = None` so the demo path works
//!   without Core ML). Includes the content-free
//!   `brain_events_ingested_count` counter.
//!
//! # Privacy invariants (CSO sign-off block on the PR body)
//!
//! - **§4.1** OCR'd text reaching this module already cleared cascade-twice
//!   on the helper side (pixel-time §1–§5/§7 + OCR-time §6). This module
//!   does not re-litigate cascade; it trusts the wire variant because the
//!   helper is the trust boundary (ADR-0007 / ADR-0016 §4.2).
//! - **§4.3** `PrivacyTombstone` never reaches `put_event`. Two walls:
//!   (1) the IPC `Routed::Tombstone(EventRow)` variant carries a typed
//!   `EventRow`, not a `Frame` — it is *structurally impossible* to
//!   accidentally pass it to `BrainIngestor::ingest_ocr_event` because the
//!   trait method takes `&Message` and the `Routed` dispatcher hands the
//!   brain only `Routed::OCREvent(Frame)`; (2) defence in depth,
//!   `ingest_ocr_event` itself enum-matches on `Message::OCREvent { .. }`
//!   and returns `Ok(NotOcrEvent)` for every other variant (no store
//!   call). Unit test `tombstone_dispatch_never_reaches_brain` pins the
//!   second wall.
//! - **§4.4** No network. The ingest path is `mci-core` (in-process IPC
//!   transport) + `mci-brain` (local `SQLCipher` + arctic-embed-s Core ML).
//!   `cargo tree -p mci-agent` carries no transitive net I/O dep that
//!   wasn't already on the lockfile at PR #79.
//! - **§4.7** The `brain_events_ingested_count` counter is `u64` —
//!   content-free, identical discipline to `frames_redacted_by_failsafe`
//!   (PR #24) and `cascade_forced_count` (PR #44).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use mci_brain::{
    mark_event_tier2_processed_as, persist_tier2_matches_as, BrainStore, ChunkerError, EmbedError,
    Embedder, Event, EventChunker, EventId, NerBackend, StoreError, Tier1Extractor, Tier2Extractor,
};
use mci_brain::extraction::tier1::persist_tier1_matches;
use mci_brain::extraction::tier2::{EXTRACTOR_KIND_NER, SENTINEL_NAME_NER};
use mci_brain::Chunker;
use mci_core::ipc::Message;

use crate::page_content::PageContentCache;
use crate::wall_clock::format_unix_ms;

/// Outcome of a single `ingest_ocr_event` call.
#[derive(Debug, Clone, PartialEq)]
pub enum IngestOutcome {
    /// The `OCREvent` was inserted into the brain. Carries the
    /// store-assigned id + whether an embedding was attached (false when
    /// the embedder was absent, e.g. the `arctic-embed-s.mlpackage` is
    /// not bundled in this build; ADR-0016 §1.3 acknowledges this
    /// graceful degradation).
    Stored {
        /// Store-assigned event id.
        id: EventId,
        /// `true` when an embedding was attached and stored.
        embedded: bool,
    },
    /// The frame was not an `OCREvent` — caller routed it incorrectly.
    /// The trait method returns this rather than panicking so the
    /// brain-side dispatch is provably idempotent on wrong-routes.
    /// Production callers should never observe this variant because the
    /// IPC `Routed::OCREvent(_)` dispatch is the only path that calls
    /// `ingest_ocr_event`.
    NotOcrEvent,
}

/// Errors the ingest pump surfaces.
#[derive(Debug, thiserror::Error)]
pub enum IngestError {
    /// The embedder rejected the OCR'd text (e.g. empty input rejected
    /// by [`mci_brain::EmbedError::InvalidInput`]; or a backend / Core ML
    /// failure on the runtime side).
    #[error("brain ingest: embed: {0}")]
    Embed(#[from] EmbedError),
    /// The store rejected the event (mis-dim embedding per ADR-0009,
    /// suppressed-event tripwire per ADR-0016 §4.3, `SQLCipher` backend
    /// failure).
    #[error("brain ingest: store: {0}")]
    Store(#[from] StoreError),
    /// The chunker failed on the headered OCR'd text (e.g. invalid UTF-8
    /// boundary at a sub-chunk cut). Production [`EventChunker`] does not
    /// surface this in normal operation; the variant exists so a future
    /// chunker impl that does (e.g. a model-tokenizer-backed split) can
    /// propagate the error without changing the `BrainIngestor` surface.
    #[error("brain ingest: chunk: {0}")]
    Chunk(#[from] ChunkerError),
}

/// Single-method trait the runner dispatches `OCREvent` frames through.
///
/// Trait-object friendly (`Send + Sync + ?Sized`-callable) so the runner
/// can hold `&dyn BrainIngestor`. Two production-shape impls live in this
/// crate:
///
/// - [`BrainPump`] — the wire-to-store composite.
/// - [`NoopBrainIngestor`] — used when the agent runs in `--demo` mode
///   without the brain spun up (e.g. on a host where the on-disk
///   `mci.sqlite` would be created in the wrong location).
pub trait BrainIngestor: Send + Sync {
    /// Dispatch one frame. Returns [`IngestOutcome::Stored`] for an
    /// `OCREvent` that successfully reached the store, or
    /// [`IngestOutcome::NotOcrEvent`] for any other variant (no store
    /// call made).
    ///
    /// # Errors
    /// [`IngestError::Embed`] from the embedder, [`IngestError::Store`]
    /// from the store. Production callers treat these as connection-
    /// aborting; the agent loop closes and re-spawns the helper.
    fn ingest_ocr_event(&self, msg: &Message) -> Result<IngestOutcome, IngestError>;

    /// Number of `OCREvent` frames that reached `put_event` successfully
    /// since this ingestor was constructed. Content-free counter for
    /// the CRS Telemetry-Gap analyst (ADR-0016 §4.7).
    fn events_ingested_count(&self) -> u64;
}

/// No-op ingestor: counts the frames it sees, never touches a store.
///
/// Used when the agent is started without a brain store (e.g. early-boot
/// `--demo` mode before the bundled `mci.sqlite` is provisioned, or in
/// tests that only care about the runner's frame routing). Returns
/// [`IngestOutcome::Stored`] (id = `EventId(0)`, embedded = `false`)
/// for `OCREvent` frames so the call-site stats logic still observes
/// the "store accepted it" branch.
#[derive(Debug, Default)]
pub struct NoopBrainIngestor {
    seen: AtomicU64,
}

impl NoopBrainIngestor {
    /// Construct a fresh no-op ingestor.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            seen: AtomicU64::new(0),
        }
    }
}

impl BrainIngestor for NoopBrainIngestor {
    fn ingest_ocr_event(&self, msg: &Message) -> Result<IngestOutcome, IngestError> {
        if matches!(msg, Message::OCREvent { .. } | Message::PageContentEvent { .. }) {
            self.seen.fetch_add(1, Ordering::Relaxed);
            Ok(IngestOutcome::Stored {
                id: EventId(0),
                embedded: false,
            })
        } else {
            Ok(IngestOutcome::NotOcrEvent)
        }
    }

    fn events_ingested_count(&self) -> u64 {
        self.seen.load(Ordering::Relaxed)
    }
}

/// Production wire-to-brain pump.
///
/// Holds:
///
/// - `store`: a `dyn BrainStore` writer — typically
///   [`mci_brain::SqlCipherBrainStore`] in production, the stub
///   `InMemoryBrainStore` in tests.
/// - `embedder`: optional `dyn Embedder`. When the on-disk
///   `arctic-embed-s.mlpackage` isn't bundled (early-development demo
///   builds), the agent constructs `BrainPump` with `embedder = None`;
///   events still ingest with `embedding = None` (events.embedding
///   column already nullable per ADR-0016 §1.4 schema) so the recall
///   path falls back to FTS5-only.
/// - `chunker`: the [`Chunker`] that enforces the ADR-0010 §1.3
///   "key expansion" discipline (prepend `[app=… | title=… | url=… |
///   ts=…]\n` to OCR text *before* embedding) and the ADR-0011 §3
///   per-chunk word-token ceiling (~1500 word-tokens for the
///   arctic-embed-s effective context). Default = [`EventChunker`].
/// - `counter`: the content-free `brain_events_ingested_count`.
///
/// The pump is *strictly synchronous at ingest* — embedder runs inline
/// before `put_event`. ADR-0016 §1.3 acknowledges this is the
/// P3.6.6 demo simplicity; the idle-batch optimization (decouple
/// embedder from ingest so capture-time inserts don't block on the
/// 5-15 ms Core ML call) is the P3.8 follow-on.
///
/// # OCR/PageContent → chunker → event row wire (DOGFOOD v1 #5)
///
/// For every `OCREvent` / `PageContentEvent`, the pump:
///
/// 1. Decodes the wire payload into `(ts_us, app, title, url, text,
///    keyframe_blob)`.
/// 2. Merges extension-supplied page text with pixel-OCR text when a
///    `PageContentCache` is wired (see [`Self::maybe_merge_page_content`]).
/// 3. **Prepends the ADR-0010 §1.3 context header** `[app=… | title=…
///    | url=… | ts=…]\n` via [`compose_context_header`]. The header
///    co-vectors the app/title/url tokens with the body text so queries
///    like "the 1Password vault I had open yesterday" project onto the
///    embedding via the `app=com.1password.app` token, not just the
///    body — `LongMemEval` arXiv:2410.10813 reports +9.4% recall@5 from
///    this single move.
/// 4. **Runs [`Chunker::chunk`]** on the headered text. For OCR-typical
///    events (one frame's worth of UI text, ≤1500 word-tokens) the
///    chunker returns a single chunk equal to the headered input. For
///    long events the chunker splits on paragraph / sentence boundaries
///    — only the **first chunk** is embedded in this PR (it carries the
///    header naturally); the full headered text is still persisted in
///    `events.text` so FTS5 indexes the whole content. Sub-chunk
///    persistence to the `chunks` table is a follow-on (the chunks
///    table already exists in `migrations/0001_phase_3_brain_schema.sql`).
/// 5. Calls `store.put_event(&event)` with `event.text = headered_text`
///    and `event.embedding = Some(embed(chunks[0]))` (or `None` when
///    the embedder is absent / text is empty).
///
/// The chunker is invoked **once** per ingested event — preserving the
/// ADR-0016 §4.2 cascade-twice "exactly one `OCREvent` emission site"
/// invariant from the producer side and now the consumer side too.
pub struct BrainPump {
    store: Arc<dyn BrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
    chunker: Arc<dyn Chunker>,
    page_cache: Option<PageContentCache>,
    counter: AtomicU64,
    /// V2-P4 Tier 1 regex entity extractor. Zero-sized — the regex
    /// bank lives in module-level `LazyLock` statics — so holding it
    /// by value adds no runtime cost. Invoked synchronously on the
    /// Allow arm of `ingest_ocr_event` after `put_event` returns.
    /// See [`mci_brain::extraction`] for the cascade-discipline
    /// invariant and token-shape REDACT discipline.
    tier1: Tier1Extractor,
    /// Cumulative `entity_mentions` rows the Tier 1 extractor has
    /// attempted to write. Content-free counter (`u64`) — identical
    /// discipline to `counter` above, surfaces as a CRS Telemetry-Gap
    /// signal so a regression in Tier 1 yield is visible.
    tier1_mentions_persisted: AtomicU64,
    /// V2-P5+ — SYNC Tier-2 BERT NER extractor, run inline on the Allow
    /// arm after Tier 1. `None` when the bert-base-NER `.mlmodelc` is
    /// absent (opt-in download) or on non-macOS — the agent constructs a
    /// [`mci_brain::Tier2Extractor`] wrapping a `NerTier2Backend` and
    /// injects it via [`BrainPump::with_ner_sync`]. Coexists with the
    /// async Qwen Tier-2 (`tier2_worker`) via the two-sentinel pattern:
    /// this tier marks `(extractor_status, ner_sync_processed)`, the Qwen
    /// tier marks `(extractor_status, qwen_tier2_processed)`.
    ner_sync: Option<Tier2Extractor>,
    /// Cumulative `entity_mentions` rows the sync NER tier has inserted.
    /// Content-free CRS Telemetry-Gap counter, mirroring
    /// `tier1_mentions_persisted`.
    ner_sync_mentions_persisted: AtomicU64,
}

/// Separator injected between extension-sourced page text and the
/// pixel-OCR text when the agent merges both signals into one brain
/// event. The label lets downstream consumers (recall UI, agent API)
/// distinguish the two sources.
const VISIBLE_OCR_SEPARATOR: &str = "\n\n[VISIBLE-OCR]\n";

impl BrainPump {
    /// Construct a brain pump with the default production [`EventChunker`].
    ///
    /// `embedder = None` is acceptable for demo / development builds
    /// where the bundled `arctic-embed-s.mlpackage` isn't shipped yet.
    /// `page_cache = None` disables OCR/PageContent merge (pre-extension
    /// builds; the OCR text is stored as-is).
    #[must_use]
    pub fn new(store: Arc<dyn BrainStore>, embedder: Option<Arc<dyn Embedder>>) -> Self {
        Self {
            store,
            embedder,
            chunker: Arc::new(EventChunker::default()),
            page_cache: None,
            counter: AtomicU64::new(0),
            tier1: Tier1Extractor::new(),
            tier1_mentions_persisted: AtomicU64::new(0),
            ner_sync: None,
            ner_sync_mentions_persisted: AtomicU64::new(0),
        }
    }

    /// Construct a brain pump with page-content merge enabled.
    #[must_use]
    pub fn with_page_cache(
        store: Arc<dyn BrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
        page_cache: PageContentCache,
    ) -> Self {
        Self {
            store,
            embedder,
            chunker: Arc::new(EventChunker::default()),
            page_cache: Some(page_cache),
            counter: AtomicU64::new(0),
            tier1: Tier1Extractor::new(),
            tier1_mentions_persisted: AtomicU64::new(0),
            ner_sync: None,
            ner_sync_mentions_persisted: AtomicU64::new(0),
        }
    }

    /// Construct a brain pump with a caller-supplied chunker. Test-only
    /// path; production callers use [`Self::new`] / [`Self::with_page_cache`]
    /// (which install the default [`EventChunker`]).
    #[must_use]
    pub fn with_chunker(
        store: Arc<dyn BrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
        chunker: Arc<dyn Chunker>,
    ) -> Self {
        Self {
            store,
            embedder,
            chunker,
            page_cache: None,
            counter: AtomicU64::new(0),
            tier1: Tier1Extractor::new(),
            tier1_mentions_persisted: AtomicU64::new(0),
            ner_sync: None,
            ner_sync_mentions_persisted: AtomicU64::new(0),
        }
    }

    /// Cumulative number of `entity_mentions` writes the V2-P4 Tier 1
    /// extractor has attempted on the Allow arm of `ingest_ocr_event`.
    /// Content-free counter — useful for the CRS Telemetry-Gap
    /// analyst to spot a Tier 1 yield regression.
    #[must_use]
    pub fn tier1_mentions_persisted_count(&self) -> u64 {
        self.tier1_mentions_persisted.load(Ordering::Relaxed)
    }

    /// Install the V2-P5+ SYNC Tier-2 BERT NER extractor. The `backend`
    /// is the macOS `NerTier2Backend` (Core ML, `cpu_only`) in production
    /// or a `MockNerBackend` in the wiring test; it is wrapped in a
    /// [`Tier2Extractor`] (cascade-marker SKIP + token-REDACT downstream
    /// SKIP + hallucination/confidence filters) and run inline after
    /// Tier 1 on the Allow arm of [`Self::ingest_ocr_event`].
    ///
    /// Builder form so the existing 3 constructors keep their signatures
    /// (mirrors how `embedder = None` stays the default). The production
    /// caller in `apps/agent/src/bin/mci_agent.rs` calls this only when
    /// the bert-base-NER model loads; otherwise the pump runs Tier 1 only
    /// and the sync NER stays disabled (Tier 1 mentions still flow).
    #[must_use]
    pub fn with_ner_sync(mut self, backend: Arc<dyn NerBackend>) -> Self {
        self.ner_sync = Some(Tier2Extractor::new(backend));
        self
    }

    /// Cumulative number of `entity_mentions` rows the sync NER tier has
    /// inserted on the Allow arm. Content-free CRS Telemetry-Gap counter.
    #[must_use]
    pub fn ner_sync_mentions_persisted_count(&self) -> u64 {
        self.ner_sync_mentions_persisted.load(Ordering::Relaxed)
    }

    /// Whether the sync NER tier is installed (the bert-base-NER model
    /// loaded). Lets the production caller log enabled/disabled state.
    #[must_use]
    pub fn ner_sync_enabled(&self) -> bool {
        self.ner_sync.is_some()
    }
}

impl BrainPump {
    /// If a cached extension page-content exists for `url` (within the
    /// 5 s TTL), merge: extension text (preferred) + separator +
    /// pixel-OCR text (secondary). Otherwise return OCR text unchanged.
    ///
    /// Both sources are already §6-secret-filtered independently
    /// (OCR by helper cascade-twice, extension by native-host filter).
    fn maybe_merge_page_content(&self, url: Option<&str>, ocr_text: &str) -> String {
        let Some(cache) = &self.page_cache else {
            return ocr_text.to_owned();
        };
        let Some(url) = url else {
            return ocr_text.to_owned();
        };
        if url.is_empty() {
            return ocr_text.to_owned();
        }
        match cache.get(url) {
            Some(cached) if !cached.text.is_empty() => {
                let mut merged = cached.text;
                merged.push_str(VISIBLE_OCR_SEPARATOR);
                merged.push_str(ocr_text);
                merged
            }
            _ => ocr_text.to_owned(),
        }
    }
}

impl BrainIngestor for BrainPump {
    #[allow(clippy::too_many_lines)]
    fn ingest_ocr_event(&self, msg: &Message) -> Result<IngestOutcome, IngestError> {
        let (ts_us, app, title, u, text, keyframe_blob, tab_id) = match msg {
            Message::OCREvent {
                seq: _,
                ts_us,
                app_bundle_id,
                window_title,
                url,
                ocr_text,
                keyframe_hash,
            } => {
                let app = bundle_id_from_padded_bytes(app_bundle_id);
                let title = if window_title.is_empty() { None } else { Some(window_title.clone()) };
                let u = if url.is_empty() { None } else { Some(url.clone()) };
                let kb = if keyframe_hash.iter().all(|b| *b == 0) {
                    None
                } else {
                    Some(hex_lower(keyframe_hash))
                };
                let merged = self.maybe_merge_page_content(u.as_deref(), ocr_text);
                // OCREvent carries no per-tab signal — the helper
                // does not observe browser-internal tab state.
                (ts_us, app, title, u, merged, kb, None)
            }
            Message::PageContentEvent {
                seq: _,
                ts_us,
                url,
                title,
                full_text,
                source_browser,
                tab_id,
            } => {
                let app = browser_bundle_id(source_browser);
                let t = if title.is_empty() { None } else { Some(title.clone()) };
                let u = if url.is_empty() { None } else { Some(url.clone()) };
                // V2-P2: plumb tab_id end-to-end. Extension JS in
                // both extensions/chromium/background.js and
                // extensions/safari/background.js sends `0` when no
                // tab id is available (`sender.tab.id || 0`); the
                // brain store column semantics treat that as NULL
                // — distinct from a real tab id of 0 (which
                // browsers do not assign in practice).
                let resolved_tab = if *tab_id == 0 { None } else { Some(*tab_id) };
                (ts_us, app, t, u, full_text.clone(), None, resolved_tab)
            }
            _ => return Ok(IngestOutcome::NotOcrEvent),
        };

        // ADR-0010 §1.3 "key expansion" — prepend the per-event context
        // header so the embedder sees the app/title/url tokens alongside
        // the OCR body. The header is also persisted into events.text so
        // FTS5 indexes those tokens inline (the events.app_bundle_id /
        // window_title / url columns are also FTS5-indexed via
        // events_fts, so the header is additive coverage, not new PII).
        let header = compose_context_header(app.as_deref(), title.as_deref(), u.as_deref(), *ts_us);
        let headered_text = if text.is_empty() {
            String::new()
        } else {
            let mut s = String::with_capacity(header.len() + text.len());
            s.push_str(&header);
            s.push_str(&text);
            s
        };

        // ADR-0016 §1.2 — run the chunker on the headered text. For OCR-
        // typical events (≤1500 word-tokens) the chunker returns a single
        // chunk equal to the headered input; embedding it is the same
        // thing as embedding `headered_text`. For long events the chunker
        // splits on paragraph/sentence boundaries; we embed only the
        // first chunk in this PR (it naturally carries the header) and
        // persist the full headered text in `events.text` so FTS5
        // indexes the whole content. Sub-chunk persistence to the
        // `chunks` table is a follow-on; the table already exists in
        // `migrations/0001_phase_3_brain_schema.sql`.
        let chunks = self.chunker.chunk(&headered_text)?;
        let embed_input: Option<&str> = chunks.first().map(String::as_str);

        let embedding: Option<Vec<f32>> = match (&self.embedder, embed_input) {
            (Some(e), Some(t)) if !t.is_empty() => Some(e.embed_one(t)?),
            _ => None,
        };

        let event = Event {
            id: EventId(0),
            ts_us: *ts_us,
            app_bundle_id: app,
            window_title: title,
            url: u,
            text: headered_text,
            summary: None,
            entities: None,
            episode_id: None,
            // ADR-0016 §4.3: events reaching put_event are .allow-decided;
            // cascade_reason is always 0 here. The store's belt-and-suspenders
            // check rejects non-zero with StoreError::InvalidInput.
            cascade_reason: 0,
            keyframe_blob,
            // V2-P2: per-tab attribution. `tab_id` is populated only
            // for browser-extension PageContentEvent ingest paths;
            // OCREvent ingest leaves it None (the helper has no
            // browser-internal tab signal). Two events with the same
            // URL but distinct tab_ids now land as DISTINCT rows in
            // the brain store (migration 0003 events.tab_id column).
            tab_id,
            embedding: embedding.clone(),
        };

        let embedded = embedding.is_some();
        let id = self.store.put_event(&event)?;
        self.counter.fetch_add(1, Ordering::Relaxed);

        // V2-P4 — synchronous Allow-arm dispatch.
        //
        // Trade-off chosen vs. post-persistence idle batch:
        //
        // - In-line keeps `entity_mentions` consistent with `events` —
        //   the V2-P5 Qwen NER batch (next cycle) sees a brain where
        //   the Tier 1 regex pass has already run, so its output is
        //   strictly additive (`extractor_kind = "qwen"` alongside
        //   `"regex"`). A batch dispatch here would force the Tier 2
        //   pass to either re-derive Tier 1 mentions or coordinate
        //   ordering — neither is worth the cost.
        // - The regex bank is bounded (one `Regex::find_iter` per
        //   kind; ~14 kinds; DFA-bounded constants). On 4 KB OCR-
        //   typical events the scan completes in <1 ms on M1 — well
        //   inside the Footprint SLO §2 G2 per-event burst budget.
        // - Extraction failure must NOT fail the ingest: the event
        //   is already in `events`, so a `StoreError` from the
        //   extractor's `put_entity` / `put_entity_mention` calls is
        //   logged-and-continued, not returned. A subsequent ingest
        //   pass (or the V2-P5 batch) can backfill missing rows
        //   because the writer is idempotent on PK by construction.
        let matches = self.tier1.extract(&event.text);
        if !matches.is_empty() {
            match persist_tier1_matches(&*self.store, id, event.ts_us, &matches) {
                Ok(stats) => {
                    self.tier1_mentions_persisted
                        .fetch_add(stats.mentions_inserted as u64, Ordering::Relaxed);
                }
                Err(_e) => {
                    // Best-effort: keep going. The event lives;
                    // mentions can be backfilled.
                }
            }
        }

        // V2-P5+ — SYNC Tier-2 BERT NER (CEO-ratified hot-path extractor,
        // dslim/bert-base-NER INT8, cpu_only). Runs inline after Tier 1 on
        // the same Allow-arm event when the model is installed (else
        // `ner_sync` is None and this is a no-op — Tier 1 still flows).
        // Disciplines, inherited from the shared `Tier2Extractor` + the
        // V2-P3 content-stable ULID schema:
        //
        // - **Cascade-marker SKIP / token-REDACT downstream SKIP**: the
        //   `Tier2Extractor` drops any NER span overlapping a `[REDACTED:…]`
        //   marker or a V2-P4 `redacted_token` span, so REDACT-classed
        //   source bytes never reach `entities` / `entity_mentions`.
        // - **Idempotent**: same `(kind, canonical_name)` → same `EntityId`;
        //   same `(entity_id, event_id, "ner", mention_text)` → same
        //   `EntityMentionId`. Re-ingesting the same event is a row-level
        //   no-op (`INSERT OR IGNORE`), so a re-run converges.
        // - **Two-sentinel**: marks `(extractor_status, ner_sync_processed)`
        //   — distinct from the Qwen async sentinel — so both tiers stay
        //   independently idempotent + forward-compatible.
        // - **Best-effort**: extract / persist failure must NOT fail the
        //   ingest (the event already lives). The sentinel is written only
        //   on a successful extract (including an empty result), never on a
        //   backend error — a transient model failure leaves the event
        //   findable for a later backfill pass.
        if let Some(ner) = &self.ner_sync {
            match ner.extract(&event.text) {
                Ok(ner_matches) => {
                    if let Ok(stats) = persist_tier2_matches_as(
                        &*self.store,
                        id,
                        event.ts_us,
                        &ner_matches,
                        EXTRACTOR_KIND_NER,
                    ) {
                        self.ner_sync_mentions_persisted
                            .fetch_add(stats.mentions_inserted as u64, Ordering::Relaxed);
                    }
                    // Mark processed (even on empty output) so a future
                    // backfill's `WHERE NOT EXISTS sentinel` query does not
                    // re-scan an already-processed event. Best-effort.
                    let _ = mark_event_tier2_processed_as(
                        &*self.store,
                        id,
                        event.ts_us,
                        SENTINEL_NAME_NER,
                        EXTRACTOR_KIND_NER,
                    );
                }
                Err(_e) => {
                    // Backend failure (model load / inference) — do NOT mark
                    // processed, so the event stays eligible for a retry.
                }
            }
        }

        Ok(IngestOutcome::Stored { id, embedded })
    }

    fn events_ingested_count(&self) -> u64 {
        self.counter.load(Ordering::Relaxed)
    }
}

/// Compose the ADR-0010 §1.3 / ADR-0016 §1.2 per-event context header.
///
/// Returns `[app=<bundle> | title=<title> | url=<url> | ts=<iso8601>]\n`.
/// Fields are emitted as `?` when missing — keeps the layout stable so
/// the embedder always sees the same number of separators (the position
/// of the `|` characters is itself a token boundary signal).
///
/// `ts_us` (microseconds since epoch) is rendered via
/// [`format_unix_ms`] as ISO-8601 UTC with millisecond precision; same
/// shape as the `HealthLogRecord::wall_ts` field. No `chrono` / `time`
/// crate dep is taken (the formatter is hand-rolled in
/// `wall_clock.rs`).
#[must_use]
pub fn compose_context_header(
    app: Option<&str>,
    title: Option<&str>,
    url: Option<&str>,
    ts_us: u64,
) -> String {
    let app = app.unwrap_or("?");
    let title = title.unwrap_or("?");
    let url = url.unwrap_or("?");
    let ts = format_unix_ms(u128::from(ts_us / 1000));
    format!("[app={app} | title={title} | url={url} | ts={ts}]\n")
}

/// Map a `source_browser` string from the extension to a macOS bundle id.
fn browser_bundle_id(source: &str) -> Option<String> {
    let id = match source {
        "safari" => "com.apple.Safari",
        "chrome" => "com.google.Chrome",
        "arc" => "company.thebrowser.Browser",
        "edge" => "com.microsoft.edgemac",
        "brave" => "com.brave.Browser",
        "firefox" => "org.mozilla.firefox",
        _ => return Some(source.to_owned()),
    };
    Some(id.to_owned())
}

/// Decode the wire's null-padded 64-byte app-bundle-id field into an
/// `Option<String>`. Returns `None` for an all-zero field (the helper
/// uses that to signal "no bundle id available"); otherwise truncates at
/// the first null byte and UTF-8-decodes the prefix.
///
/// Non-UTF-8 bytes resolve to `None` rather than panicking — the wire
/// decoder already validates UTF-8 on length-prefixed strings, but the
/// fixed 64-byte field has no length prefix, so this guard is the
/// trust-boundary check.
fn bundle_id_from_padded_bytes(bytes: &[u8; 64]) -> Option<String> {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    if end == 0 {
        return None;
    }
    std::str::from_utf8(&bytes[..end]).ok().map(str::to_owned)
}

/// Lowercase-hex encode a fixed 32-byte slice without pulling in the
/// `hex` crate (ADR-0008 dependency-addition gate — no net-new third-
/// party crate).
fn hex_lower(bytes: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for b in bytes {
        s.push(HEX[(*b >> 4) as usize] as char);
        s.push(HEX[(*b & 0x0F) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::stubs::{FixedDimEmbedder, InMemoryBrainStore};
    use mci_core::ipc::RedactionReason;

    fn make_ocr_event(ts_us: u64, text: &str) -> Message {
        let mut bundle = [0u8; 64];
        let id = b"com.apple.Safari";
        bundle[..id.len()].copy_from_slice(id);
        Message::OCREvent {
            seq: 1,
            ts_us,
            app_bundle_id: bundle,
            window_title: "Login — example.com".to_string(),
            url: "https://example.com/login".to_string(),
            ocr_text: text.to_string(),
            keyframe_hash: [0u8; 32],
        }
    }

    #[test]
    fn bundle_id_decodes_truncated_at_null() {
        let mut b = [0u8; 64];
        b[..3].copy_from_slice(b"abc");
        assert_eq!(bundle_id_from_padded_bytes(&b), Some("abc".to_string()));
    }

    #[test]
    fn bundle_id_all_zero_is_none() {
        let b = [0u8; 64];
        assert_eq!(bundle_id_from_padded_bytes(&b), None);
    }

    #[test]
    fn hex_lower_padding_zeros() {
        assert_eq!(hex_lower(&[0xAB; 32]), "ab".repeat(32));
        assert_eq!(hex_lower(&[0u8; 32]), "0".repeat(64));
    }

    #[test]
    fn noop_ingestor_counts_only_ocr_events() {
        let n = NoopBrainIngestor::new();
        let _ = n
            .ingest_ocr_event(&Message::PrivacyTombstone {
                ts_us: 1,
                app_bundle: "x".into(),
                reason: RedactionReason::AxSecureSubrole,
            })
            .unwrap();
        let _ = n.ingest_ocr_event(&make_ocr_event(2, "hi")).unwrap();
        let _ = n.ingest_ocr_event(&make_ocr_event(3, "yo")).unwrap();
        assert_eq!(n.events_ingested_count(), 2);
    }

    #[test]
    fn pump_stores_ocr_event_with_embedding() {
        let store = Arc::new(InMemoryBrainStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = BrainPump::new(store.clone(), Some(embedder));
        let out = pump
            .ingest_ocr_event(&make_ocr_event(1_000_000, "hello world"))
            .expect("ingest ok");
        match out {
            IngestOutcome::Stored { id, embedded } => {
                assert!(embedded, "embedder was Some + text non-empty");
                let ev = store.get_event(id).unwrap().unwrap();
                assert_eq!(ev.ts_us, 1_000_000);
                // ADR-0010 §1.3 — events.text now carries the prepended
                // context header. The original OCR body is preserved at
                // the tail of the column.
                assert!(
                    ev.text.starts_with("[app=com.apple.Safari | title=Login — example.com | url=https://example.com/login | ts="),
                    "expected ADR-0010 §1.3 header prefix, got: {}",
                    &ev.text[..ev.text.len().min(160)]
                );
                assert!(ev.text.ends_with("hello world"), "OCR body preserved");
                assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.Safari"));
                assert_eq!(ev.embedding.as_ref().map(Vec::len), Some(384));
                assert_eq!(ev.cascade_reason, 0);
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored, got NotOcrEvent"),
        }
        assert_eq!(pump.events_ingested_count(), 1);
    }

    fn make_page_content_event(ts_us: u64, text: &str) -> Message {
        Message::PageContentEvent {
            seq: 1,
            ts_us,
            url: "https://example.com/pricing".to_string(),
            title: "Pricing — Example Corp".to_string(),
            full_text: text.to_string(),
            source_browser: "chrome".to_string(),
            tab_id: 42,
        }
    }

    #[test]
    fn pump_stores_page_content_event() {
        let store = Arc::new(InMemoryBrainStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = BrainPump::new(store.clone(), Some(embedder));
        let out = pump
            .ingest_ocr_event(&make_page_content_event(2_000_000, "Full page text here"))
            .expect("ingest ok");
        match out {
            IngestOutcome::Stored { id, embedded } => {
                assert!(embedded);
                let ev = store.get_event(id).unwrap().unwrap();
                assert_eq!(ev.ts_us, 2_000_000);
                assert!(
                    ev.text.contains("[app=com.google.Chrome"),
                    "expected ADR-0010 §1.3 header, got: {}",
                    &ev.text[..ev.text.len().min(160)]
                );
                assert!(ev.text.ends_with("Full page text here"));
                assert_eq!(ev.app_bundle_id.as_deref(), Some("com.google.Chrome"));
                assert_eq!(ev.url.as_deref(), Some("https://example.com/pricing"));
                assert_eq!(ev.window_title.as_deref(), Some("Pricing — Example Corp"));
                assert_eq!(ev.keyframe_blob, None);
                // V2-P2: tab_id plumbed end-to-end (wire u32 → store
                // Option<u32>; 0 collapses to None, non-zero passes
                // through).
                assert_eq!(ev.tab_id, Some(42));
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        }
    }

    // -----------------------------------------------------------
    // V2-P2 tab_id plumb
    // -----------------------------------------------------------

    /// Round-trip pin: two PageContentEvents with the same URL but
    /// distinct `tab_id` values land as DISTINCT brain rows that
    /// each carry their own tab_id back through `get_event`. This
    /// is the load-bearing V2-P2 fix (memo `docs/research/tab-
    /// attribution-mix-2026-05-29.md` §3 + §5 secondary).
    #[test]
    fn pump_preserves_distinct_tab_ids_for_shared_url() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = BrainPump::new(store.clone(), None);

        let evt_a = Message::PageContentEvent {
            seq: 1,
            ts_us: 1_000_000,
            url: "https://example.com/page".to_string(),
            title: "Tab A".to_string(),
            full_text: "content from tab A".to_string(),
            source_browser: "safari".to_string(),
            tab_id: 11,
        };
        let evt_b = Message::PageContentEvent {
            seq: 2,
            ts_us: 2_000_000,
            url: "https://example.com/page".to_string(),
            title: "Tab B".to_string(),
            full_text: "content from tab B".to_string(),
            source_browser: "safari".to_string(),
            tab_id: 22,
        };

        let id_a = match pump.ingest_ocr_event(&evt_a).expect("a") {
            IngestOutcome::Stored { id, .. } => id,
            IngestOutcome::NotOcrEvent => panic!("expected Stored a"),
        };
        let id_b = match pump.ingest_ocr_event(&evt_b).expect("b") {
            IngestOutcome::Stored { id, .. } => id,
            IngestOutcome::NotOcrEvent => panic!("expected Stored b"),
        };
        assert_ne!(id_a, id_b, "shared URL but distinct tab ⇒ distinct rows");

        let got_a = store.get_event(id_a).unwrap().expect("get a");
        let got_b = store.get_event(id_b).unwrap().expect("get b");
        assert_eq!(got_a.tab_id, Some(11));
        assert_eq!(got_b.tab_id, Some(22));
        assert_eq!(
            got_a.url, got_b.url,
            "URL truly is shared — tab_id is the distinguisher"
        );
    }

    /// Wire-level `tab_id = 0` collapses to `None` on the store
    /// side. Pins the chromium/safari `sender.tab.id || 0` shape
    /// at the brain boundary.
    #[test]
    fn pump_collapses_wire_tab_id_zero_to_none() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = BrainPump::new(store.clone(), None);

        let evt = Message::PageContentEvent {
            seq: 1,
            ts_us: 1_000_000,
            url: "https://example.com/".to_string(),
            title: "No Tab".to_string(),
            full_text: "no tab id available".to_string(),
            source_browser: "chrome".to_string(),
            tab_id: 0,
        };
        let id = match pump.ingest_ocr_event(&evt).expect("ingest") {
            IngestOutcome::Stored { id, .. } => id,
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        };
        let got = store.get_event(id).unwrap().expect("get");
        assert!(
            got.tab_id.is_none(),
            "wire tab_id == 0 must collapse to None at the store"
        );
    }

    /// OCREvent ingest does NOT populate tab_id — the helper has no
    /// per-tab signal.
    #[test]
    fn pump_leaves_tab_id_none_for_ocr_event_ingest() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = BrainPump::new(store.clone(), None);
        let id = match pump
            .ingest_ocr_event(&make_ocr_event(9_000_000, "some pixel text"))
            .expect("ingest")
        {
            IngestOutcome::Stored { id, .. } => id,
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        };
        let got = store.get_event(id).unwrap().expect("get");
        assert!(got.tab_id.is_none(), "OCREvent path leaves tab_id None");
    }

    #[test]
    fn noop_ingestor_counts_page_content_events() {
        let n = NoopBrainIngestor::new();
        let _ = n.ingest_ocr_event(&make_page_content_event(1, "hi")).unwrap();
        assert_eq!(n.events_ingested_count(), 1);
    }

    // -----------------------------------------------------------
    // OCR / PageContent merge tests (wire 0x06)
    // -----------------------------------------------------------

    use crate::page_content::PageContentCache;

    #[test]
    fn merge_prefers_extension_when_cached() {
        let store = Arc::new(InMemoryBrainStore::new());
        let cache = PageContentCache::new();
        cache.insert(
            "https://example.com/login".into(),
            "Full DOM text from extension".into(),
            "Login Page".into(),
            "chrome".into(),
        );
        let pump = BrainPump::with_page_cache(store.clone(), None, cache);
        let out = pump
            .ingest_ocr_event(&make_ocr_event(1_000_000, "OCR pixels"))
            .expect("ingest ok");
        match out {
            IngestOutcome::Stored { id, .. } => {
                let ev = store.get_event(id).unwrap().unwrap();
                // ADR-0010 §1.3 header is prepended; the extension body
                // is the primary body content (before the [VISIBLE-OCR]
                // separator), not necessarily the absolute prefix.
                assert!(ev.text.starts_with("[app="), "header prefix");
                let body_start = ev
                    .text
                    .find('\n')
                    .map(|i| i + 1)
                    .expect("header newline");
                assert!(
                    ev.text[body_start..].starts_with("Full DOM text from extension"),
                    "extension text must be primary body; got: {}",
                    &ev.text[body_start..ev.text.len().min(body_start + 80)]
                );
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        }
    }

    #[test]
    fn merge_falls_back_to_ocr_when_no_cache() {
        let store = Arc::new(InMemoryBrainStore::new());
        let cache = PageContentCache::new();
        // Cache is empty — no extension text for this URL.
        let pump = BrainPump::with_page_cache(store.clone(), None, cache);
        let out = pump
            .ingest_ocr_event(&make_ocr_event(2_000_000, "pure OCR text"))
            .expect("ingest ok");
        match out {
            IngestOutcome::Stored { id, .. } => {
                let ev = store.get_event(id).unwrap().unwrap();
                assert!(ev.text.ends_with("pure OCR text"));
                assert!(ev.text.contains("[app=com.apple.Safari"));
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        }
    }

    #[test]
    fn merge_appends_visible_ocr_label() {
        let store = Arc::new(InMemoryBrainStore::new());
        let cache = PageContentCache::new();
        cache.insert(
            "https://example.com/login".into(),
            "Extension page body".into(),
            "Login Page".into(),
            "chrome".into(),
        );
        let pump = BrainPump::with_page_cache(store.clone(), None, cache);
        let out = pump
            .ingest_ocr_event(&make_ocr_event(3_000_000, "visible pixel text"))
            .expect("ingest ok");
        match out {
            IngestOutcome::Stored { id, .. } => {
                let ev = store.get_event(id).unwrap().unwrap();
                assert!(
                    ev.text.contains("[VISIBLE-OCR]"),
                    "merged text must contain [VISIBLE-OCR] separator; got: {}",
                    ev.text
                );
                assert!(ev.text.contains("Extension page body"));
                assert!(ev.text.contains("visible pixel text"));
                let parts: Vec<&str> = ev.text.split("[VISIBLE-OCR]").collect();
                assert_eq!(parts.len(), 2, "exactly one separator");
                assert!(
                    parts[0].trim().ends_with("Extension page body"),
                    "extension text before separator"
                );
                assert!(
                    parts[1].trim().starts_with("visible pixel text"),
                    "OCR text after separator"
                );
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored"),
        }
    }

    // -----------------------------------------------------------
    // Chunker wire tests (DOGFOOD v1 #5)
    // -----------------------------------------------------------

    use mci_brain::{Chunker, ChunkerError};
    use std::sync::Mutex;

    /// Recording chunker that counts calls and snapshots inputs so a
    /// test can prove the wire crosses the chunker exactly once per
    /// ingested event and that the input carries the §1.3 header.
    struct RecordingChunker {
        inner: EventChunker,
        calls: AtomicU64,
        last_input: Mutex<Option<String>>,
    }

    impl RecordingChunker {
        fn new() -> Self {
            Self {
                inner: EventChunker::default(),
                calls: AtomicU64::new(0),
                last_input: Mutex::new(None),
            }
        }
        fn call_count(&self) -> u64 {
            self.calls.load(Ordering::Relaxed)
        }
        fn last(&self) -> Option<String> {
            self.last_input.lock().unwrap().clone()
        }
    }

    impl Chunker for RecordingChunker {
        fn chunk(&self, event_text: &str) -> Result<Vec<String>, ChunkerError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            *self.last_input.lock().unwrap() = Some(event_text.to_owned());
            self.inner.chunk(event_text)
        }
    }

    #[test]
    fn pump_invokes_chunker_once_per_ocr_event_with_headered_text() {
        let store = Arc::new(InMemoryBrainStore::new());
        let chunker = Arc::new(RecordingChunker::new());
        let pump = BrainPump::with_chunker(
            store.clone(),
            None,
            Arc::clone(&chunker) as Arc<dyn Chunker>,
        );

        let _ = pump
            .ingest_ocr_event(&make_ocr_event(7_000_000, "the quick brown fox"))
            .expect("ingest ok");

        assert_eq!(chunker.call_count(), 1, "chunker called exactly once");
        let input = chunker.last().expect("chunker saw an input");
        assert!(
            input.starts_with("[app=com.apple.Safari | title="),
            "chunker input must carry ADR-0010 §1.3 header; got: {}",
            &input[..input.len().min(120)]
        );
        assert!(
            input.ends_with("the quick brown fox"),
            "chunker input must carry the OCR body at the tail"
        );
    }

    #[test]
    fn pump_embeds_first_chunk_when_text_exceeds_window() {
        // Force a tiny window so the chunker splits even modest input.
        // The chunker uses word-count > window as the split trigger.
        let store = Arc::new(InMemoryBrainStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let tiny: Arc<dyn Chunker> = Arc::new(mci_brain::EventChunker::new(8));
        let pump = BrainPump::with_chunker(store.clone(), Some(embedder), tiny);

        // Body forces ≥2 chunks at window=8 — three sentences across two
        // paragraphs, ~20 words after the header is prepended.
        let body = "First sentence here. Second sentence here. Third sentence here.\n\nFourth sentence here. Fifth sentence here. Sixth sentence here.";
        let out = pump
            .ingest_ocr_event(&make_ocr_event(8_000_000, body))
            .expect("ingest ok");
        let IngestOutcome::Stored { id, embedded } = out else {
            panic!("expected Stored");
        };
        assert!(embedded, "embedder runs on the first chunk");
        let ev = store.get_event(id).unwrap().unwrap();
        // events.text persists the FULL headered text (FTS5 indexes the
        // whole content — the embedding-only first-chunk discipline is a
        // semantic-recall lever, not a storage truncation).
        assert!(ev.text.contains("Sixth sentence here."));
        assert!(ev.text.starts_with("[app="));
        assert_eq!(ev.embedding.as_ref().map(Vec::len), Some(384));
    }

    #[test]
    fn pump_rejects_privacy_tombstone_without_store_call() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = BrainPump::new(store.clone(), None);
        let out = pump
            .ingest_ocr_event(&Message::PrivacyTombstone {
                ts_us: 5,
                app_bundle: "com.apple.Safari".into(),
                reason: RedactionReason::AxSecureSubrole,
            })
            .expect("tombstone treated as not-an-ocr-event");
        assert_eq!(out, IngestOutcome::NotOcrEvent);
        assert_eq!(pump.events_ingested_count(), 0);
        // Belt + suspenders: nothing in the store.
        assert!(store.get_event(EventId(1)).unwrap().is_none());
    }
}
