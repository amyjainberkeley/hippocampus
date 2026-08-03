//! Run the understanding pipeline over a brain that already has events.
//!
//! # Why this exists
//!
//! Five workers turn raw events into something you can actually ask
//! questions of: the embedder, the episode segmenter, the alias resolver,
//! the consolidator, and entity extraction. Every one of them was reachable
//! only from inside the live-capture ingest path (`--drain-stdin`).
//!
//! Capture ships off by default. So on any brain filled some other way (the
//! seeder, the Mail or Messages readers, an import) none of them ever ran.
//! A brain full of names, companies and URLs reported `Entities: 0` and
//! `Episode links: 0`, not because the extractors were broken — they are
//! well tested — but because nothing called them.
//!
//! This module is the missing caller. Same code as the capture path, driven
//! to completion once instead of looping forever.
//!
//! # Order matters
//!
//! The stages form a dependency chain and running them out of order
//! silently produces less:
//!
//! 1. **Extract** finds entities in event text. Everything downstream that
//!    is about *who and what* depends on this.
//! 2. **Embed** fills `event_vectors` so recall can fuse semantic hits.
//!    Independent of the rest; ordered here because it is the slowest.
//! 3. **Segment** groups events into episodes. Needs nothing but events.
//! 4. **Resolve** clusters entities into identities. Needs step 1.
//! 5. **Consolidate** links episodes that share an identity. Needs 3 and 4.
//!
//! # Idempotence
//!
//! Every stage is safe to re-run. Extraction and embedding skip work that
//! exists; resolve and consolidate reconcile to the current derived set.
//! Running `enrich` twice on an unchanged brain writes nothing, which is
//! what makes it safe to wire into a cron or a post-import step later.

use mci_brain::episode_segmenter::HeuristicEpisodeSegmenter;
use mci_brain::extraction::tier1::persist_tier1_matches;
use mci_brain::{BrainStore, Embedder, SqlCipherBrainStore, Tier1Extractor};

use crate::alias_resolver_worker::{self, AliasResolverWorkerError};
use crate::consolidator_worker::{self, ConsolidatorWorkerError};
use crate::episode_worker::{self, EpisodeWorkerError};
use crate::idle_batch::{self, IdleBatchError};

/// What a full enrich pass did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EnrichStats {
    /// Events read during extraction.
    pub events_scanned: u64,
    /// Entity mentions written by Tier-1 extraction.
    pub mentions_written: u64,
    /// Events given an embedding. Zero when no embedder was supplied.
    pub embedded: u64,
    /// Events assigned to an episode.
    pub events_segmented: u64,
    /// Episodes created.
    pub episodes_created: u64,
    /// Identity membership rows written by the alias resolver.
    pub memberships_written: u64,
    /// Distinct identities after resolution.
    pub identities: u64,
    /// `shared_identity` edges written between episodes.
    pub edges_written: u64,
}

/// Errors a stage can surface. A stage that fails aborts the run, because
/// later stages read what earlier ones wrote and would silently under-produce.
#[derive(Debug, thiserror::Error)]
pub enum EnrichError {
    /// A store read or write failed.
    #[error("enrich: store: {0}")]
    Store(String),
    /// The embed stage failed.
    #[error("enrich: embed: {0}")]
    Embed(#[from] IdleBatchError),
    /// The segment stage failed.
    #[error("enrich: segment: {0}")]
    Segment(#[from] EpisodeWorkerError),
    /// The resolve stage failed.
    #[error("enrich: resolve: {0}")]
    Resolve(#[from] AliasResolverWorkerError),
    /// The consolidate stage failed.
    #[error("enrich: consolidate: {0}")]
    Consolidate(#[from] ConsolidatorWorkerError),
}

/// Which stage is running, for progress reporting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// Tier-1 entity extraction.
    Extract,
    /// Embedding backfill.
    Embed,
    /// Episode segmentation.
    Segment,
    /// Alias resolution.
    Resolve,
    /// Episode-edge consolidation.
    Consolidate,
}

impl Stage {
    /// Human label used in CLI output.
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Stage::Extract => "extract",
            Stage::Embed => "embed",
            Stage::Segment => "segment",
            Stage::Resolve => "resolve",
            Stage::Consolidate => "consolidate",
        }
    }
}

/// Run Tier-1 entity extraction over every event.
///
/// There is no "un-extracted" index to query, so this walks all events. That
/// is fine because `persist_tier1_matches` is idempotent on its primary keys
/// (`INSERT OR IGNORE`), so re-extracting an event writes nothing new. The
/// design anticipates exactly this: the ingest path documents that "a
/// subsequent pass can backfill missing rows because the writer is
/// idempotent by construction."
///
/// A per-event failure is skipped rather than fatal, matching the ingest
/// path, where extraction failure must never lose the event itself.
///
/// # Errors
/// [`EnrichError::Store`] if listing events fails.
pub fn extract_until_drained(
    store: &SqlCipherBrainStore,
    batch_size: usize,
    mut on_progress: impl FnMut(u64),
) -> Result<(u64, u64), EnrichError> {
    let extractor = Tier1Extractor::new();
    let base_batch = batch_size.max(1);
    let mut scanned: u64 = 0;
    let mut attempted: u64 = 0;
    let mut cursor: u64 = 0;
    // Widened only when a whole batch lands on one timestamp; see below.
    let mut limit = base_batch;

    loop {
        let batch = store
            .events_since(cursor, limit)
            .map_err(|e| EnrichError::Store(e.to_string()))?;
        if batch.is_empty() {
            break;
        }

        // `events_since` is `ts_us > cursor`, exclusive, and cannot
        // paginate *within* a timestamp. If a full batch sits entirely at
        // one instant it may be truncated, and advancing the cursor past
        // that instant would silently skip the remainder. Widen the window
        // and re-read instead. Terminates because the limit doubles.
        let first_ts = batch.first().map_or(cursor, |r| r.ts_us);
        let last_ts = batch.last().map_or(cursor, |r| r.ts_us);
        if first_ts == last_ts && batch.len() >= limit {
            limit = limit.saturating_mul(2);
            continue;
        }

        for record in &batch {
            // `events_since` carries only a truncated snippet; extraction
            // needs the whole text or it misses entities past the cut.
            let Ok(Some(event)) = store.get_event(record.event_id) else {
                continue;
            };
            let matches = extractor.extract(&event.text);
            if !matches.is_empty() {
                if let Ok(stats) =
                    persist_tier1_matches(store, record.event_id, record.ts_us, &matches)
                {
                    attempted += stats.mentions_inserted as u64;
                }
            }
            scanned += 1;
        }

        cursor = last_ts;
        limit = base_batch;
        on_progress(scanned);
    }

    Ok((scanned, attempted))
}

/// Run every understanding stage over an existing brain, in dependency order.
///
/// `embedder` is optional: without one the embed stage is skipped and recall
/// stays keyword-only. Every other stage runs regardless, because entities,
/// episodes and identities need no model.
///
/// # Errors
/// The first stage that fails, wrapped in the matching [`EnrichError`]
/// variant. Stages are not rolled back; a re-run picks up where it stopped
/// because every stage is idempotent.
pub fn run_enrich(
    store: &SqlCipherBrainStore,
    embedder: Option<&dyn Embedder>,
    batch_size: usize,
    mut on_stage: impl FnMut(Stage, &str),
) -> Result<EnrichStats, EnrichError> {
    let mut stats = EnrichStats::default();

    on_stage(Stage::Extract, "scanning events for entities");
    // Measure the store, not the extractor's return value. Tier-1 counts
    // rows it *offered*, and the writers are INSERT OR IGNORE, so on a
    // re-run it reports the same number while writing nothing. Reporting
    // that verbatim would tell you work happened when none did.
    let before = store
        .stats()
        .map_err(|e| EnrichError::Store(e.to_string()))?
        .entity_mention_count;
    let (scanned, _attempted) = extract_until_drained(store, batch_size, |_| {})?;
    let after = store
        .stats()
        .map_err(|e| EnrichError::Store(e.to_string()))?
        .entity_mention_count;

    stats.events_scanned = scanned;
    stats.mentions_written = after.saturating_sub(before);
    on_stage(
        Stage::Extract,
        &format!(
            "{scanned} events scanned, {} new mentions",
            stats.mentions_written
        ),
    );

    if let Some(emb) = embedder {
        on_stage(Stage::Embed, "embedding events with no vector");
        let s = idle_batch::backfill_until_drained(store, emb, batch_size, |_| {})?;
        stats.embedded = s.events_embedded;
        on_stage(Stage::Embed, &format!("{} embedded", s.events_embedded));
    } else {
        on_stage(
            Stage::Embed,
            "skipped, no embedder available (recall stays keyword-only)",
        );
    }

    on_stage(Stage::Segment, "grouping events into episodes");
    let segmenter = HeuristicEpisodeSegmenter::default();
    let s = episode_worker::segment_until_drained(store, &segmenter, batch_size)?;
    stats.events_segmented = s.events_assigned;
    stats.episodes_created = s.episodes_created;
    on_stage(
        Stage::Segment,
        &format!(
            "{} events into {} episodes",
            s.events_assigned, s.episodes_created
        ),
    );

    on_stage(Stage::Resolve, "clustering entities into identities");
    let s = alias_resolver_worker::resolve_once(store)?;
    stats.memberships_written = s.memberships_written;
    stats.identities = s.identities_last;
    on_stage(
        Stage::Resolve,
        &format!(
            "{} identities, {} memberships written",
            s.identities_last, s.memberships_written
        ),
    );

    on_stage(
        Stage::Consolidate,
        "linking episodes that share an identity",
    );
    let s = consolidator_worker::consolidate_once(store)?;
    stats.edges_written = s.edges_written;
    on_stage(
        Stage::Consolidate,
        &format!(
            "{} edges written ({} derived)",
            s.edges_written, s.edges_derived_last
        ),
    );

    Ok(stats)
}
