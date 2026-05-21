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

use mci_brain::{BrainStore, EmbedError, Embedder, Event, EventId, StoreError};
use mci_core::ipc::Message;

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
        if matches!(msg, Message::OCREvent { .. }) {
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
/// - `counter`: the content-free `brain_events_ingested_count`.
///
/// The pump is *strictly synchronous at ingest* — embedder runs inline
/// before `put_event`. ADR-0016 §1.3 acknowledges this is the
/// P3.6.6 demo simplicity; the idle-batch optimization (decouple
/// embedder from ingest so capture-time inserts don't block on the
/// 5-15 ms Core ML call) is the P3.8 follow-on.
pub struct BrainPump {
    store: Arc<dyn BrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
    counter: AtomicU64,
}

impl BrainPump {
    /// Construct a brain pump.
    ///
    /// `embedder = None` is acceptable for demo / development builds
    /// where the bundled `arctic-embed-s.mlpackage` isn't shipped yet.
    /// Document this in the agent startup log (the binary's `main`
    /// emits the warning; this module does not — keeps `mci-brain`
    /// out of `tracing` for OS-purity).
    #[must_use]
    pub fn new(store: Arc<dyn BrainStore>, embedder: Option<Arc<dyn Embedder>>) -> Self {
        Self {
            store,
            embedder,
            counter: AtomicU64::new(0),
        }
    }
}

impl BrainIngestor for BrainPump {
    #[allow(clippy::too_many_lines)]
    fn ingest_ocr_event(&self, msg: &Message) -> Result<IngestOutcome, IngestError> {
        // ADR-0016 §4.3 defence-in-depth — exhaustive match against the
        // Message enum. ANY non-OCREvent variant returns NotOcrEvent
        // *without* a store call. PrivacyTombstone in particular MUST
        // dead-end here. The structural wall (the IPC `Routed` enum)
        // already prevents reaching this code with a Tombstone, but
        // this second wall is the in-source CSO-sign-off evidence the
        // PR body references.
        let Message::OCREvent {
            seq: _,
            ts_us,
            app_bundle_id,
            window_title,
            url,
            ocr_text,
            keyframe_hash,
        } = msg
        else {
            return Ok(IngestOutcome::NotOcrEvent);
        };

        let app = bundle_id_from_padded_bytes(app_bundle_id);
        let title = if window_title.is_empty() {
            None
        } else {
            Some(window_title.clone())
        };
        let u = if url.is_empty() {
            None
        } else {
            Some(url.clone())
        };
        let keyframe_blob = if keyframe_hash.iter().all(|b| *b == 0) {
            None
        } else {
            Some(hex_lower(keyframe_hash))
        };

        // Embedder runs BEFORE put_event so a mis-dim or backend
        // failure on the embedder cannot leave a half-stored event row
        // in the brain. If the embedder is absent, embedding stays
        // `None` (column is nullable per ADR-0016 §1.4); recall falls
        // back to FTS5-only.
        let embedding: Option<Vec<f32>> = match &self.embedder {
            Some(e) if !ocr_text.is_empty() => Some(e.embed_one(ocr_text)?),
            _ => None,
        };

        let event = Event {
            id: EventId(0),
            ts_us: *ts_us,
            app_bundle_id: app,
            window_title: title,
            url: u,
            text: ocr_text.clone(),
            summary: None,
            entities: None,
            episode_id: None,
            // ADR-0016 §4.3: events reaching put_event are .allow-decided;
            // cascade_reason is always 0 here. The store's belt-and-suspenders
            // check rejects non-zero with StoreError::InvalidInput.
            cascade_reason: 0,
            keyframe_blob,
            embedding: embedding.clone(),
        };

        let embedded = embedding.is_some();
        let id = self.store.put_event(&event)?;
        self.counter.fetch_add(1, Ordering::Relaxed);
        Ok(IngestOutcome::Stored { id, embedded })
    }

    fn events_ingested_count(&self) -> u64 {
        self.counter.load(Ordering::Relaxed)
    }
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
                assert_eq!(ev.text, "hello world");
                assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.Safari"));
                assert_eq!(ev.embedding.as_ref().map(Vec::len), Some(384));
                assert_eq!(ev.cascade_reason, 0);
            }
            IngestOutcome::NotOcrEvent => panic!("expected Stored, got NotOcrEvent"),
        }
        assert_eq!(pump.events_ingested_count(), 1);
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
