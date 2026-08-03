//! Episode-segmenter idle worker — ADR-0010 §1.
//!
//! Polls `events WHERE episode_id IS NULL`, runs the
//! `HeuristicEpisodeSegmenter`, writes `episode_id` back. Same
//! structure as the idle-batch embedder (`idle_batch.rs`): single-flight,
//! yields between cycles, exits on shutdown signal.
//!
//! # Privacy invariants
//!
//! - Only reads `.allow`-stored events (suppressed events have no rows).
//! - Only writes to `events.episode_id` (existing nullable column) and
//!   `episodes` (existing table). No new write surface in `BrainStore`.

use std::sync::Arc;

use mci_brain::episode_segmenter::{EpisodeSegmenter, EpisodeWriter};
use mci_brain::SqlCipherBrainStore;
use tokio::sync::watch;

/// Stats returned when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegmentWorkerStats {
    /// Total events assigned an `episode_id`.
    pub events_assigned: u64,
    /// Total new episodes created.
    pub episodes_created: u64,
    /// Total batches processed.
    pub batches_run: u64,
}

/// Errors the episode worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum EpisodeWorkerError {
    /// A store read failed fatally.
    #[error("episode-worker: store: {0}")]
    Store(String),
}

/// Segment every unsegmented event, then return.
///
/// The one-shot sibling of [`run_episode_worker`]: same read-segment-write
/// sequence, opposite lifecycle. Drains the queue and exits instead of
/// sleeping for more work. `mci-agent enrich` calls this.
///
/// # Errors
/// [`EpisodeWorkerError::Store`] if reading unsegmented events, reading the
/// last segmented event, or the segmenter's own writes fail.
pub fn segment_until_drained(
    store: &SqlCipherBrainStore,
    segmenter: &dyn EpisodeSegmenter,
    batch_size: usize,
) -> Result<SegmentWorkerStats, EpisodeWorkerError> {
    let mut stats = SegmentWorkerStats {
        events_assigned: 0,
        episodes_created: 0,
        batches_run: 0,
    };
    let batch_size = batch_size.max(1);

    loop {
        let batch = store
            .unsegmented_events(batch_size)
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;
        if batch.is_empty() {
            break;
        }

        // Episodes are contiguous in time, so each batch needs the tail of
        // the previous one to decide whether it continues that episode or
        // starts a new one.
        let last = store
            .last_segmented_event()
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;

        let result = segmenter
            .segment(&batch, last.as_ref(), store as &dyn EpisodeWriter)
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;

        // A batch that assigns nothing would otherwise spin forever: the
        // same rows stay unsegmented and the next read returns them again.
        if result.events_assigned == 0 {
            break;
        }

        stats.events_assigned += result.events_assigned;
        stats.episodes_created += result.episodes_created;
        stats.batches_run += 1;
    }

    Ok(stats)
}

/// Run the episode-segmenter idle loop.
///
/// Reads up to `batch_size` unsegmented events per cycle, fetches the
/// last segmented event for continuity, runs the segmenter, sleeps
/// `idle_interval` when the queue is drained. Exits on shutdown.
pub async fn run_episode_worker(
    store: Arc<SqlCipherBrainStore>,
    segmenter: Arc<dyn EpisodeSegmenter>,
    batch_size: usize,
    idle_interval: std::time::Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<SegmentWorkerStats, EpisodeWorkerError> {
    let mut stats = SegmentWorkerStats {
        events_assigned: 0,
        episodes_created: 0,
        batches_run: 0,
    };

    loop {
        if *shutdown.borrow() {
            break;
        }

        let store_c = Arc::clone(&store);
        let bs = batch_size;
        let batch = tokio::task::spawn_blocking(move || store_c.unsegmented_events(bs))
            .await
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;

        if batch.is_empty() {
            tokio::select! {
                () = tokio::time::sleep(idle_interval) => continue,
                _ = shutdown.changed() => break,
            }
        }

        let store_c = Arc::clone(&store);
        let last = tokio::task::spawn_blocking(move || store_c.last_segmented_event())
            .await
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?
            .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;

        let store_c = Arc::clone(&store);
        let seg = Arc::clone(&segmenter);
        let result = tokio::task::spawn_blocking(move || {
            seg.segment(
                &batch,
                last.as_ref(),
                store_c.as_ref() as &dyn EpisodeWriter,
            )
        })
        .await
        .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?
        .map_err(|e| EpisodeWorkerError::Store(e.to_string()))?;

        stats.events_assigned += result.events_assigned;
        stats.episodes_created += result.episodes_created;
        stats.batches_run += 1;
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_default_values() {
        let s = SegmentWorkerStats {
            events_assigned: 0,
            episodes_created: 0,
            batches_run: 0,
        };
        assert_eq!(s.events_assigned, 0);
    }
}
