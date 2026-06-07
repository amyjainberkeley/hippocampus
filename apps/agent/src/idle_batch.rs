//! Idle-batch embedder — P3.8.
//!
//! Picks up events from `events WHERE embedding IS NULL` (no matching
//! `event_vectors` row), embeds via the `Embedder` trait, writes to
//! `event_vectors` via `SqlCipherBrainStore::set_event_embedding`, and
//! yields between batches so it doesn't compete with capture-time work.
//!
//! ADR-0016 §1.3: idle-batch is the decoupling from capture-time. Worker
//! stays single-flight (no concurrent embed calls) to keep the Core ML
//! model loaded once + the memory budget predictable.
//!
//! # Privacy invariants
//!
//! - §4.2 cascade-twice: the worker ONLY writes to `event_vectors`. No
//!   new `events` INSERT. No new OCREvent emission site.
//! - §4.3 cascade_reason=0 wall: untouched. Reads existing events; never
//!   inserts them.
//! - §4.6 idle-batch worker reads `.allow`-stored events only. Its input
//!   is `events.text` for events already in the store. It can never see
//!   a suppressed event because suppressed events don't have rows in
//!   `events`.

use std::sync::Arc;

use mci_brain::{Embedder, SqlCipherBrainStore};
use tokio::sync::watch;

/// Stats returned when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunStats {
    /// Total events embedded across all batches.
    pub events_embedded: u64,
    /// Total batches processed.
    pub batches_run: u64,
    /// Embed calls that returned an error (event skipped).
    pub embed_errors: u64,
    /// Store writes that returned an error (event skipped).
    pub store_errors: u64,
}

/// Errors the idle-batch worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum IdleBatchError {
    /// A store read (`unembedded_events`) failed fatally.
    #[error("idle-batch: store read: {0}")]
    StoreRead(String),
}

/// Run the idle-batch embedding loop.
///
/// Reads up to `batch_size` un-embedded events per cycle, embeds each
/// one via `embedder.embed_one(&event.text)`, writes via
/// `store.set_event_embedding(...)`. Sleeps `idle_interval` between
/// cycles when the queue is drained. Exits cleanly when `shutdown`
/// flips to `true`.
///
/// Single-flight by design: one embed call at a time, one store write
/// at a time. Keeps the Core ML model loaded once and the memory
/// budget predictable (ADR-0016 §1.3).
pub async fn run_idle_batch_worker(
    store: Arc<SqlCipherBrainStore>,
    embedder: Arc<dyn Embedder>,
    batch_size: usize,
    idle_interval: std::time::Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<RunStats, IdleBatchError> {
    let mut stats = RunStats {
        events_embedded: 0,
        batches_run: 0,
        embed_errors: 0,
        store_errors: 0,
    };

    loop {
        // Check shutdown before doing work.
        if *shutdown.borrow() {
            break;
        }

        let store_c = Arc::clone(&store);
        let bs = batch_size;
        let batch = tokio::task::spawn_blocking(move || store_c.unembedded_events(bs))
            .await
            .map_err(|e| IdleBatchError::StoreRead(e.to_string()))?
            .map_err(|e| IdleBatchError::StoreRead(e.to_string()))?;

        if batch.is_empty() {
            // Nothing to do — sleep and re-check.
            tokio::select! {
                _ = tokio::time::sleep(idle_interval) => continue,
                _ = shutdown.changed() => break,
            }
        }

        for event in &batch {
            if *shutdown.borrow() {
                return Ok(stats);
            }

            let embedding = match embedder.embed_one(&event.text) {
                Ok(v) => v,
                Err(e) => {
                    stats.embed_errors += 1;
                    // Rate-limited per-error surfacing. Previously the error
                    // was swallowed to `_e` and only an aggregate count
                    // surfaced once at worker exit — a dead embedder was
                    // invisible until shutdown. Log the first failure and
                    // every 64th thereafter with the actual backend error
                    // string so a persistent failure is known immediately
                    // without flooding logs. Content-free: `e` is backend
                    // diagnostic text and `event.id` is a row id, never
                    // event content.
                    if stats.embed_errors == 1 || stats.embed_errors % 64 == 0 {
                        eprintln!(
                            "mci-agent: idle-batch embed error #{} (event {}): {e}",
                            stats.embed_errors, event.id,
                        );
                    }
                    continue;
                }
            };

            let store_c = Arc::clone(&store);
            let eid = event.id;
            let write_result =
                tokio::task::spawn_blocking(move || store_c.set_event_embedding(eid, &embedding))
                    .await
                    .map_err(|e| IdleBatchError::StoreRead(e.to_string()))?;

            match write_result {
                Ok(()) => stats.events_embedded += 1,
                Err(_e) => stats.store_errors += 1,
            }
        }

        stats.batches_run += 1;
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_stats_default_values() {
        let s = RunStats {
            events_embedded: 0,
            batches_run: 0,
            embed_errors: 0,
            store_errors: 0,
        };
        assert_eq!(s.events_embedded, 0);
    }
}
