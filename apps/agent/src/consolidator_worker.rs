//! Episode-edge **Consolidator** idle worker — V2-P6 (the last
//! graph-construction step before the Phase-6 dot-connect demo).
//!
//! Periodically reads the consolidation candidates out of the brain
//! (`entity_identities ⋈ entity_mentions ⋈ events`, post-cascade +
//! segmented), runs the OS-free [`EpisodeConsolidator`] (cross-app
//! `shared_identity` edge derivation — see
//! `core/brain/src/consolidator.rs`), and **reconciles** the resulting
//! [`EpisodeEdge`] rows into the store via
//! [`BrainStore::reconcile_episode_edges`] — pruning any `shared_identity`
//! edge the latest derive no longer produces (the alias resolver's
//! leaf-attachment is non-monotonic) while leaving an unchanged re-run a
//! row-level no-op (migration 0004, **NO new schema**).
//!
//! Same shape as the other idle-batch workers
//! (`alias_resolver_worker.rs`, `episode_worker.rs`, `idle_batch.rs`):
//! single-flight, yields between cycles, exits on the shutdown signal.
//! **Off the hot path** — it polls a cheap [`ConsolidationWatermark`] and
//! only re-derives when the identity / mention / episode-assignment
//! population actually changed, so a steady-state session does no work
//! beyond one watermark query per `idle_interval`.
//!
//! # Privacy invariants
//!
//! - Operates only on already-resolved identities + post-cascade,
//!   segmented events. The store read (`consolidation_candidates`) filters
//!   `cascade_reason = 0` and joins through `entity_identities`, so a
//!   `redacted_token` placeholder or a suppressed bundle can never seed an
//!   edge (`AGENT_PROTOCOL` §5 redaction discipline).
//! - Writes only to the `episode_edges` table (migration 0004 — existing
//!   schema). No capture-scope change, no new IPC, no network surface —
//!   the zero-knowledge invariant is preserved by construction.

use std::sync::Arc;

use mci_brain::{
    BrainStore, ConsolidationWatermark, EpisodeConsolidator, EpisodeEdge, SqlCipherBrainStore,
};
use tokio::sync::watch;

/// Stats returned when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ConsolidatorStats {
    /// Total consolidate cycles that did real work (watermark changed).
    pub cycles_run: u64,
    /// Total NEW `episode_edges` rows inserted across cycles (an unchanged
    /// re-run inserts nothing — `INSERT OR IGNORE` on the content-stable
    /// PK).
    pub edges_written: u64,
    /// Total stale `shared_identity` edges pruned across cycles (an edge no
    /// longer derivable because the `AliasResolver` dropped a membership it
    /// rested on). Zero on a steady re-run.
    pub edges_pruned: u64,
    /// Edges DERIVED by the most recent consolidate (incl. ones that
    /// already existed). `edges_derived_last - edges_written` over a
    /// steady re-run is the idempotent-skip count.
    pub edges_derived_last: u64,
    /// Total store write errors across cycles.
    pub store_errors: u64,
}

/// Errors the consolidator worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum ConsolidatorWorkerError {
    /// A store read/write failed fatally (or the blocking task panicked).
    #[error("consolidator: store: {0}")]
    Store(String),
}

/// Run the episode-edge consolidator idle loop.
///
/// Each cycle: read a cheap [`ConsolidationWatermark`]; if unchanged since
/// the last derive, sleep `idle_interval`. Otherwise read the candidate
/// mention sites, consolidate them into `shared_identity` edges, and batch
/// `INSERT OR IGNORE` them. Exits cleanly when `shutdown` flips to `true`.
pub async fn run_consolidator_worker(
    store: Arc<SqlCipherBrainStore>,
    idle_interval: std::time::Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<ConsolidatorStats, ConsolidatorWorkerError> {
    let consolidator = EpisodeConsolidator::default();
    let mut stats = ConsolidatorStats::default();
    let mut last_watermark: Option<ConsolidationWatermark> = None;

    loop {
        if *shutdown.borrow() {
            break;
        }

        // Cheap change-detection: skip the full derive when nothing the
        // consolidator reads has changed since last time.
        let store_c = Arc::clone(&store);
        let watermark = tokio::task::spawn_blocking(move || store_c.consolidation_watermark())
            .await
            .map_err(|e| ConsolidatorWorkerError::Store(e.to_string()))?
            .map_err(|e| ConsolidatorWorkerError::Store(e.to_string()))?;

        if Some(watermark) == last_watermark {
            tokio::select! {
                () = tokio::time::sleep(idle_interval) => continue,
                _ = shutdown.changed() => break,
            }
        }

        // Read the consolidation inputs in one blocking hop.
        let store_c = Arc::clone(&store);
        let sites = tokio::task::spawn_blocking(move || store_c.consolidation_candidates())
            .await
            .map_err(|e| ConsolidatorWorkerError::Store(e.to_string()))?
            .map_err(|e| ConsolidatorWorkerError::Store(e.to_string()))?;

        let derived = consolidator.consolidate(&sites);
        stats.edges_derived_last = u64::try_from(derived.len()).unwrap_or(u64::MAX);

        // Materialize the content-stable `EpisodeEdge` rows. The PK folds
        // the identity in (so two identities over one episode pair stay
        // distinct) and `evidence_entity_ids` is the JSON array of the
        // contributing member entity ids — faithful to the column's
        // documented shape (migration 0004).
        let rows: Vec<EpisodeEdge> = derived
            .iter()
            .map(|d| EpisodeEdge {
                id: EpisodeEdge::derive_shared_identity_id(
                    d.src_episode_id,
                    d.dst_episode_id,
                    &d.identity_id,
                ),
                src_episode_id: d.src_episode_id,
                dst_episode_id: d.dst_episode_id,
                edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
                evidence_entity_ids: Some(evidence_json(d)),
                ts_us: d.ts_us,
            })
            .collect();

        // Reconcile (not append): prune any `shared_identity` edge no
        // longer in the current derived set — the alias resolver's
        // leaf-attachment is non-monotonic, so an edge can lose the
        // membership it rested on. Re-running on an unchanged store is a
        // true no-op (zero inserts, zero deletes).
        let store_c = Arc::clone(&store);
        let write = tokio::task::spawn_blocking(move || {
            store_c.reconcile_episode_edges(EpisodeEdge::KIND_SHARED_IDENTITY, &rows)
        })
        .await
        .map_err(|e| ConsolidatorWorkerError::Store(e.to_string()))?;

        match write {
            Ok(rstats) => {
                stats.edges_written += rstats.inserted;
                stats.edges_pruned += rstats.deleted;
            }
            Err(_) => stats.store_errors += 1,
        }
        stats.cycles_run += 1;
        last_watermark = Some(watermark);
    }

    Ok(stats)
}

/// Encode a derived edge's evidence as a JSON array of entity-id strings —
/// the format `episode_edges.evidence_entity_ids` documents (migration
/// 0004). The ids are content-stable Crockford-base32 ULIDs (no characters
/// that need JSON escaping), but we go through `serde_json` so the encoding
/// is correct by construction rather than by assumption.
fn evidence_json(edge: &mci_brain::DerivedEdge) -> String {
    let ids: Vec<&str> = edge
        .evidence_entity_ids
        .iter()
        .map(|e| e.0.as_str())
        .collect();
    serde_json::to_string(&ids).unwrap_or_else(|_| "[]".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_default_is_zero() {
        let s = ConsolidatorStats::default();
        assert_eq!(s.cycles_run, 0);
        assert_eq!(s.edges_written, 0);
    }

    #[test]
    fn evidence_json_is_a_sorted_string_array() {
        let edge = mci_brain::DerivedEdge {
            src_episode_id: mci_brain::EpisodeId(1),
            dst_episode_id: mci_brain::EpisodeId(2),
            identity_id: mci_brain::IdentityId("ID".to_string()),
            evidence_entity_ids: vec![
                mci_brain::EntityId("AAA".to_string()),
                mci_brain::EntityId("BBB".to_string()),
            ],
            ts_us: 5,
        };
        assert_eq!(evidence_json(&edge), "[\"AAA\",\"BBB\"]");
    }
}
