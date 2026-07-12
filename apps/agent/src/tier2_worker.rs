//! V2-P5 — Tier 2 Qwen NER idle-batch worker.
//!
//! Same shape as [`crate::idle_batch`] (the P3.8 embedder worker)
//! and [`crate::brief_worker`] (the ADR-0028 daily brief author):
//! a single tokio task that polls the brain store for events
//! pending Tier 2 extraction, runs them through a
//! [`Tier2Extractor`], writes results + a sentinel "processed"
//! marker, and yields between cycles.
//!
//! # Why idle-batch (not synchronous on the brain ingest hot path)
//!
//! Qwen3-1.7B inference is ~100-500ms per call (ADR-0028 §6
//! steady state). Running it inline in
//! [`crate::brain_ingest::BrainPump::ingest_ocr_event`] would blow
//! the G2 per-event burst SLO (≤25% CPU brief sub-second). The
//! idle-batch pattern decouples Tier 2 from the hot path:
//!
//! - V2-P4 Tier 1 regex extractor runs **synchronously** on the
//!   hot path. It's microseconds-per-event; the cost is amortized.
//! - V2-P5 Tier 2 Qwen NER runs **asynchronously** in this worker.
//!   Bounded steady-state via the idle interval; single-flight
//!   protects the ~500 MB working set.
//!
//! # Disabled-idle mode (Qwen model not downloaded)
//!
//! Qwen3-1.7B is an **opt-in download** (`brief_worker::
//! QWEN3_MODEL_BASENAME` + the `ModelDownloadManager` UI). When the
//! model is not present on disk, this worker enters disabled-idle
//! mode — same pattern as
//! [`crate::brief_worker::run_disabled_idle`]. The worker logs one
//! line and idles on the shutdown channel; no busy-loop, no
//! repeated failure logs.
//!
//! V2-P4 Tier 1 continues writing `(extractor_kind = "regex")`
//! mentions on the hot path regardless. Users who opt out of the
//! Qwen download still get all V2-P4 structural entities.
//!
//! # Privacy invariants
//!
//! - **§4.2 cascade-twice** — the worker reads `events.text` for
//!   events already in the store. Those events cleared the
//!   pixel-time §1–§5/§7 cascade + the OCR-time §6 redaction
//!   upstream (`BrainStore::put_event` rejects `cascade_reason
//!   != 0`). The worker does not re-litigate cascade.
//! - **§4.3 cascade_reason=0 wall** — untouched. Reads existing
//!   events; never inserts them.
//! - **§4.6 idle-batch reads `.allow` events only** — by
//!   construction: suppressed events have no row in `events`.
//! - **Token-REDACT downstream discipline** —
//!   [`mci_brain::Tier2Extractor`] drops any NER mention whose span
//!   overlaps a V2-P4 `redacted_token` span. The JWT / AWS-key /
//!   GitHub-PAT / Stripe-key / Bitcoin-WIF source bytes that V2-P4
//!   refused to persist never re-emerge via V2-P5.

use std::sync::Arc;
use std::time::Duration;

use mci_brain::{
    mark_event_tier2_processed, persist_tier2_matches, SqlCipherBrainStore, Tier2Extractor,
};
use tokio::sync::watch;

/// Stats reported when the worker exits.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Tier2WorkerStats {
    /// Total events scanned by the Tier 2 extractor across all
    /// batches. Includes events whose NER output was empty (the
    /// sentinel "processed" marker still got written so they're not
    /// re-scanned).
    pub events_scanned: u64,
    /// Total `entity_mentions` rows inserted (real Tier 2 mentions,
    /// not counting the sentinel).
    pub mentions_inserted: u64,
    /// Total batches processed.
    pub batches_run: u64,
    /// NER backend calls that returned an error (event still gets
    /// sentinel-marked so it isn't retried).
    pub ner_errors: u64,
    /// Store writes that returned an error.
    pub store_errors: u64,
    /// True if the worker entered disabled-idle mode and never
    /// processed events.
    pub disabled: bool,
}

/// Errors the Tier 2 worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum Tier2WorkerError {
    /// A store read (`events_pending_tier2`) failed fatally.
    #[error("tier2-worker: store read: {0}")]
    StoreRead(String),
}

/// Run the V2-P5 Tier 2 NER idle-batch loop.
///
/// Reads up to `batch_size` events pending Tier 2 extraction per
/// cycle (via [`SqlCipherBrainStore::events_pending_tier2`]), runs
/// each through `extractor`, persists Tier 2 matches +
/// the sentinel "processed" marker, then sleeps `idle_interval`
/// before the next cycle. Exits cleanly when `shutdown` flips to
/// `true`.
///
/// Single-flight by design: one Qwen call at a time, one store
/// write at a time. Keeps the ~500 MB Qwen working set predictable
/// and the SLO budget bounded.
///
/// The worker marks every event "processed" (via the sentinel
/// mention) **even when**:
///
/// - The NER backend returned an error (don't retry; log and move
///   on).
/// - The NER output was empty (no real Tier 2 entities for this
///   event).
///
/// This is intentional — without the sentinel mark on every event,
/// the "pending" query would re-emit the same event next cycle,
/// burning Qwen inference on the same input forever.
///
/// # Errors
/// [`Tier2WorkerError::StoreRead`] on a fatal store read failure
/// (the worker stops, propagating the error to the supervisor).
pub async fn run_tier2_worker(
    store: Arc<SqlCipherBrainStore>,
    extractor: Tier2Extractor,
    batch_size: usize,
    idle_interval: Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<Tier2WorkerStats, Tier2WorkerError> {
    let mut stats = Tier2WorkerStats::default();

    loop {
        if *shutdown.borrow() {
            break;
        }

        let store_c = Arc::clone(&store);
        let bs = batch_size;
        let batch = tokio::task::spawn_blocking(move || store_c.events_pending_tier2(bs))
            .await
            .map_err(|e| Tier2WorkerError::StoreRead(e.to_string()))?
            .map_err(|e| Tier2WorkerError::StoreRead(e.to_string()))?;

        if batch.is_empty() {
            tokio::select! {
                () = tokio::time::sleep(idle_interval) => continue,
                _ = shutdown.changed() => break,
            }
        }

        for event in &batch {
            if *shutdown.borrow() {
                return Ok(stats);
            }

            // Extract on a blocking worker (Qwen is CPU+ANE-bound;
            // never block the tokio runtime).
            let ex_for_call = extractor.clone();
            let text = event.text.clone();
            let extract_result = tokio::task::spawn_blocking(move || ex_for_call.extract(&text))
                .await
                .map_err(|e| Tier2WorkerError::StoreRead(format!("extract join: {e}")))?;

            let matches = match extract_result {
                Ok(m) => m,
                Err(_e) => {
                    stats.ner_errors += 1;
                    Vec::new() // fall through to sentinel mark
                }
            };

            // Persist matches + sentinel "processed" marker. Both
            // writes are idempotent on PK (entity upsert; mention
            // INSERT OR IGNORE).
            let store_for_write = Arc::clone(&store);
            let eid = event.id;
            let ts = event.ts_us;
            let matches_for_write = matches;
            let write_result =
                tokio::task::spawn_blocking(move || -> Result<usize, mci_brain::StoreError> {
                    let stats =
                        persist_tier2_matches(&*store_for_write, eid, ts, &matches_for_write)?;
                    mark_event_tier2_processed(&*store_for_write, eid, ts)?;
                    Ok(stats.mentions_inserted)
                })
                .await
                .map_err(|e| Tier2WorkerError::StoreRead(format!("write join: {e}")))?;

            match write_result {
                Ok(n) => {
                    stats.mentions_inserted += n as u64;
                    stats.events_scanned += 1;
                }
                Err(_e) => stats.store_errors += 1,
            }
        }

        stats.batches_run += 1;
    }

    Ok(stats)
}

/// Disabled-idle mode: log once, then sleep on the shutdown channel.
///
/// Used when the Qwen3 `.mlmodelc` is not present on disk (opt-in
/// download not yet completed). The task exits cleanly on shutdown;
/// no work happens between launch and exit beyond the single log
/// line. Mirrors [`crate::brief_worker::run_disabled_idle`].
pub async fn run_disabled_idle(
    reason: &str,
    mut shutdown: watch::Receiver<bool>,
) -> Tier2WorkerStats {
    eprintln!("mci-agent: tier2 NER worker disabled ({reason}); will sleep until shutdown");
    let _ = shutdown.changed().await;
    Tier2WorkerStats {
        disabled: true,
        ..Tier2WorkerStats::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_default_zero() {
        let s = Tier2WorkerStats::default();
        assert_eq!(s.events_scanned, 0);
        assert_eq!(s.mentions_inserted, 0);
        assert!(!s.disabled);
    }

    #[tokio::test]
    async fn disabled_idle_exits_on_shutdown() {
        let (tx, rx) = watch::channel(false);
        let task = tokio::spawn(run_disabled_idle("test reason", rx));
        // Flip the shutdown.
        tokio::time::sleep(Duration::from_millis(20)).await;
        tx.send(true).expect("send shutdown");
        let stats = task.await.expect("join");
        assert!(stats.disabled);
        assert_eq!(stats.events_scanned, 0);
    }
}
