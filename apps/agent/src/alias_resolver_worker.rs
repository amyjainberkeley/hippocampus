//! `AliasResolver` idle worker — V2-P6.
//!
//! Periodically reads the alias-allowlist entities + their co-occurrence
//! out of the brain, runs the OS-free [`AliasResolver`] (precision-first
//! clustering — see `core/brain/src/alias_resolver.rs`), and writes the
//! resulting canonical-identity membership rows
//! (`entity_identities`, migration 0005) back via
//! [`BrainStore::put_entity_identity`].
//!
//! Same shape as the other idle-batch workers (`episode_worker.rs`,
//! `idle_batch.rs`, `retention_worker.rs`): single-flight, yields between
//! cycles, exits on the shutdown signal. **Off the hot path** — it polls
//! a cheap [`ResolutionWatermark`] and only re-resolves when the entity /
//! mention population actually changed, so a steady-state session does no
//! work beyond one watermark query per `idle_interval`.
//!
//! # Privacy invariants
//!
//! - Operates only on already-extracted, post-cascade entities. The
//!   store read (`list_resolvable_entities` / `entity_cooccurrences`)
//!   filters to the alias allowlist, so `redacted_token` placeholders
//!   never reach the resolver (`AGENT_PROTOCOL` §5 redaction discipline).
//! - Writes only to the `entity_identities` table (migration 0005). No
//!   capture-scope change, no new IPC, no network surface — the
//!   zero-knowledge invariant is preserved by construction.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::{
    AliasResolver, BrainStore, EntityIdentity, ResolutionWatermark, SqlCipherBrainStore,
};
use tokio::sync::watch;

/// Stats returned when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AliasResolverStats {
    /// Total resolve cycles that did real work (watermark changed).
    pub cycles_run: u64,
    /// Total NEW membership rows inserted across cycles (the reconcile
    /// pass; an unchanged re-run inserts nothing).
    pub memberships_written: u64,
    /// Total stale membership rows pruned across cycles (a leaf the
    /// resolver disavowed once a colliding core appeared).
    pub memberships_pruned: u64,
    /// Distinct identities produced by the most recent resolve.
    pub identities_last: u64,
    /// Total store write errors across cycles.
    pub store_errors: u64,
}

/// Errors the alias-resolver worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum AliasResolverWorkerError {
    /// A store read/write failed fatally (or the blocking task panicked).
    #[error("alias-resolver: store: {0}")]
    Store(String),
}

/// Microseconds since the UNIX epoch (best-effort; saturates to 0 before
/// the epoch). Stamped onto the first write of each membership row; the
/// store preserves it on re-insert so re-runs stay row-level no-ops.
fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
}

/// Run the alias-resolver idle loop.
///
/// Each cycle: read a cheap [`ResolutionWatermark`]; if unchanged since
/// the last resolve, sleep `idle_interval`. Otherwise read the alias
/// entities + co-occurrence, resolve, and upsert the membership rows.
/// Exits cleanly when `shutdown` flips to `true`.
pub async fn run_alias_resolver_worker(
    store: Arc<SqlCipherBrainStore>,
    idle_interval: std::time::Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<AliasResolverStats, AliasResolverWorkerError> {
    let resolver = AliasResolver::default();
    let mut stats = AliasResolverStats::default();
    let mut last_watermark: Option<ResolutionWatermark> = None;

    loop {
        if *shutdown.borrow() {
            break;
        }

        // Cheap change-detection: skip the full resolve when nothing the
        // resolver reads has changed since last time.
        let store_c = Arc::clone(&store);
        let watermark = tokio::task::spawn_blocking(move || store_c.resolution_watermark())
            .await
            .map_err(|e| AliasResolverWorkerError::Store(e.to_string()))?
            .map_err(|e| AliasResolverWorkerError::Store(e.to_string()))?;

        if Some(watermark) == last_watermark {
            tokio::select! {
                () = tokio::time::sleep(idle_interval) => continue,
                _ = shutdown.changed() => break,
            }
        }

        // Read the resolver inputs in one blocking hop.
        let store_c = Arc::clone(&store);
        let (entities, cooccurrences) = tokio::task::spawn_blocking(move || {
            let entities = store_c.list_resolvable_entities()?;
            let cooccurrences = store_c.entity_cooccurrences()?;
            Ok::<_, mci_brain::StoreError>((entities, cooccurrences))
        })
        .await
        .map_err(|e| AliasResolverWorkerError::Store(e.to_string()))?
        .map_err(|e| AliasResolverWorkerError::Store(e.to_string()))?;

        let clusters = resolver.resolve(&entities, &cooccurrences);
        let identities_last = u64::try_from(clusters.len()).unwrap_or(u64::MAX);
        let ts = now_us();

        // Materialize the FULL current membership set, then reconcile the
        // store to exactly it — pruning any stale row the resolver no
        // longer emits (the non-monotonic leaf case). Reconcile is
        // idempotent: an unchanged re-run inserts and deletes nothing.
        let rows: Vec<EntityIdentity> = clusters
            .iter()
            .flat_map(|identity| {
                identity.members.iter().map(move |member| EntityIdentity {
                    id: EntityIdentity::derive_id(&identity.identity_id, &member.entity_id),
                    entity_id: member.entity_id.clone(),
                    identity_id: identity.identity_id.clone(),
                    identity_kind: identity.identity_kind.clone(),
                    identity_canonical_name: identity.canonical_name.clone(),
                    rule: member.rule.clone(),
                    confidence: member.confidence,
                    ts_us: ts,
                })
            })
            .collect();

        let store_c = Arc::clone(&store);
        let reconcile =
            tokio::task::spawn_blocking(move || store_c.reconcile_entity_identities(&rows))
                .await
                .map_err(|e| AliasResolverWorkerError::Store(e.to_string()))?;

        match reconcile {
            Ok(rstats) => {
                stats.memberships_written += rstats.inserted;
                stats.memberships_pruned += rstats.deleted;
            }
            Err(_) => stats.store_errors += 1,
        }
        stats.cycles_run += 1;
        stats.identities_last = identities_last;
        last_watermark = Some(watermark);
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_us_is_after_2020() {
        // 2020-01-01T00:00:00Z in microseconds.
        assert!(now_us() > 1_577_836_800_000_000);
    }

    #[test]
    fn stats_default_is_zero() {
        let s = AliasResolverStats::default();
        assert_eq!(s.cycles_run, 0);
        assert_eq!(s.memberships_written, 0);
    }
}
