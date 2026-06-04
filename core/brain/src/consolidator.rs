//! V2-P6 — **`EpisodeConsolidator`**: derive cross-app `episode_edges`
//! from the canonical identities the [`AliasResolver`](crate::AliasResolver)
//! settles.
//!
//! This is the LAST graph-construction step before the Phase-6 dot-connect
//! demo. The resolver answers "these aliases are one Person/Org/Location";
//! the consolidator answers **"these two episodes are connected, because an
//! event in each co-mentions that one identity within a short time
//! window."** That edge is the cross-app link — a Messages event and a
//! Safari event that both point at the same person become a single
//! traversable hop in the graph.
//!
//! Like [`AliasResolver`](crate::AliasResolver) this module is the pure,
//! OS-free logic; the idle-batch worker
//! (`apps/agent/src/consolidator_worker.rs`) reads the inputs out of the
//! store, calls [`EpisodeConsolidator::consolidate`], and writes the
//! resulting [`EpisodeEdge`](crate::EpisodeEdge) rows back (migration 0004,
//! NO new schema).
//!
//! # The model — episode-pair edges, keyed on identity
//!
//! The `episode_edges` table keys on `(src_episode_id, dst_episode_id)`,
//! both FK into `episodes(id)`. Episodes are app-homogeneous (the
//! segmenter breaks on app-change, ADR-0010), so two events in *different*
//! episodes that co-mention one identity within the window are, in
//! practice, a genuine cross-app jump. The consolidator therefore:
//!
//! 1. groups every mention "site" (one event's mention of an identity
//!    member) by its canonical [`IdentityId`];
//! 2. inside each identity, pairs sites that fall within `window_us` of
//!    each other AND live in **different** episodes;
//! 3. collapses every such in-window pair between the same two episodes
//!    into **one** [`DerivedEdge`] (keyed on the canonical episode pair +
//!    the identity), citing the contributing member entities as evidence.
//!
//! Step 3 is what makes re-derivation idempotent: the PK
//! ([`EpisodeEdge::derive_shared_identity_id`](crate::EpisodeEdge::derive_shared_identity_id))
//! is a content-stable function of `(min(src,dst), max(src,dst),
//! identity)`, so a second pass over an unchanged store re-emits exactly
//! the same rows (`INSERT OR IGNORE` no-ops them).
//!
//! # Algorithmic care (the red-team flagged this as the hard part)
//!
//! - **Windowing** is a sorted sliding scan: sites are sorted by `ts_us`,
//!   and the inner loop breaks as soon as the gap exceeds `window_us`. Cost
//!   is `O(n · w)` pair-tests across the chronological stream (n = sites
//!   for the identity), where `w` is the number of sites inside one
//!   window; worst case is `O(w²)` for one identity whose mentions all
//!   cluster inside a single window. Typical single-user `w` is small
//!   (≤ ~10); even a heavily-mentioned identity (`w` ≈ 100, ≈ 5k
//!   pair-tests) completes in sub-millisecond. It is NOT `O(n²)` over the
//!   whole stream.
//! - **Dedup** is structural: a [`std::collections::BTreeMap`] keyed on
//!   the canonical `(lo, hi)` episode pair folds repeated event-pairs into
//!   one edge and keeps the output sorted (deterministic, byte-identical
//!   across runs → row-level no-op downstream).
//! - **Evidence attribution**: each edge carries the *sorted, deduped*
//!   set of member [`EntityId`](crate::EntityId)s whose mentions actually
//!   co-occurred in-window across the two episodes — the "why" a reader
//!   (V2-P12 timeline / recall fusion) can render.
//! - **Idempotent re-derivation**: deterministic output + content-stable
//!   PK ⇒ a re-run writes nothing new.
//!
//! # Redaction / cascade discipline (POST-cascade)
//!
//! The consolidator never sees raw capture. The store read that feeds it
//! (`consolidation_candidates`) joins through `entity_identities` — which
//! only ever holds the resolver's alias allowlist (`person_name` /
//! `organization` / `location` / `email` / `phone` / `url`), never a
//! `redacted_token` placeholder — and filters `events.cascade_reason = 0`,
//! so edges are never built off a suppressed/redacted bundle. This module
//! adds defence in depth: a site whose `episode_id` equals its partner's
//! is skipped (no self-edges), and the inputs are treated as opaque ids.
//!
//! # OS-purity
//!
//! Pure Rust, no OS calls, no clock, no randomness. The edge timestamp is
//! the latest contributing event time (deterministic, derived from the
//! data — not a wall clock), preserving the `#![forbid(unsafe_code)]`
//! discipline and keeping the output reproducible for the idempotence
//! tests.

use std::collections::{BTreeMap, BTreeSet};

use crate::episode_segmenter::EpisodeId;
use crate::graph::{EntityId, IdentityId};

/// One mention "site": a single event's mention of an entity that belongs
/// to a canonical identity, projected to exactly what edge derivation
/// needs. The store produces these from
/// `entity_identities ⋈ entity_mentions ⋈ events` (post-cascade,
/// `episode_id IS NOT NULL`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityMentionSite {
    /// The canonical identity this mention resolves to.
    pub identity_id: IdentityId,
    /// The alias entity that was mentioned (the evidence the edge cites).
    pub entity_id: EntityId,
    /// The episode the mentioning event belongs to.
    pub episode_id: EpisodeId,
    /// The mentioning **event's** capture timestamp (`events.ts_us`),
    /// microseconds since UNIX epoch. The event time — not the mention
    /// row's `ts_us`, which fixtures often leave at a sentinel — is the
    /// windowing axis.
    pub ts_us: u64,
}

/// One cross-app edge the consolidator derived: the two episodes are
/// connected because they co-mention `identity_id` within the window.
///
/// `src_episode_id` is always the numerically smaller rowid and
/// `dst_episode_id` the larger (canonical order), matching the PK that
/// [`EpisodeEdge::derive_shared_identity_id`](crate::EpisodeEdge::derive_shared_identity_id)
/// hashes, so the worker can store the row and the identity-walk read can
/// re-derive + verify it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DerivedEdge {
    /// Canonical-low episode endpoint.
    pub src_episode_id: EpisodeId,
    /// Canonical-high episode endpoint.
    pub dst_episode_id: EpisodeId,
    /// The shared identity that justifies the edge.
    pub identity_id: IdentityId,
    /// Sorted, deduped member entity ids whose mentions co-occurred
    /// in-window across the two episodes — the edge's evidence.
    pub evidence_entity_ids: Vec<EntityId>,
    /// Latest contributing event time (max `ts_us` over the in-window
    /// co-occurrences for this edge). Deterministic; stamped into
    /// `episode_edges.ts_us` on first write.
    pub ts_us: u64,
}

/// Consolidator tuning. The default is the production co-occurrence window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConsolidatorConfig {
    /// Maximum gap between two events' capture times for them to count as
    /// co-occurring, in microseconds. **Default 60 s.**
    ///
    /// 60 s is the sweet spot for the dot-connect signal: long enough to
    /// span a real app switch (read Alice's email in Safari → reply in
    /// Messages), short enough that two unrelated mentions of the same
    /// person hours apart do NOT get glued into one "session" link. The
    /// window is inclusive (`gap <= window_us`).
    pub window_us: u64,
}

impl ConsolidatorConfig {
    /// 60 seconds, in microseconds — the default co-occurrence window.
    pub const DEFAULT_WINDOW_US: u64 = 60 * 1_000_000;
}

impl Default for ConsolidatorConfig {
    fn default() -> Self {
        Self {
            window_us: Self::DEFAULT_WINDOW_US,
        }
    }
}

/// The consolidator. Stateless apart from its config — [`Self::consolidate`]
/// is a pure function of its inputs.
#[derive(Debug, Clone, Copy, Default)]
pub struct EpisodeConsolidator {
    config: ConsolidatorConfig,
}

impl EpisodeConsolidator {
    /// Construct with explicit config.
    #[must_use]
    pub fn new(config: ConsolidatorConfig) -> Self {
        Self { config }
    }

    /// The configured co-occurrence window, in microseconds.
    #[must_use]
    pub fn window_us(&self) -> u64 {
        self.config.window_us
    }

    /// Derive the cross-app `shared_identity` edges implied by `sites`.
    ///
    /// Input order does not matter (the function sorts internally); output
    /// is sorted by `(identity_id, src_episode_id, dst_episode_id)` for
    /// determinism, so re-running on the same input is byte-identical.
    #[must_use]
    pub fn consolidate(&self, sites: &[IdentityMentionSite]) -> Vec<DerivedEdge> {
        // Deterministic processing order: identity, then time, then
        // episode/entity so equal-timestamp ties resolve stably.
        let mut ordered: Vec<&IdentityMentionSite> = sites.iter().collect();
        ordered.sort_by(|a, b| {
            a.identity_id
                .0
                .cmp(&b.identity_id.0)
                .then(a.ts_us.cmp(&b.ts_us))
                .then(a.episode_id.0.cmp(&b.episode_id.0))
                .then(a.entity_id.0.cmp(&b.entity_id.0))
        });

        let mut out: Vec<DerivedEdge> = Vec::new();

        // Walk one identity group at a time (the slice is sorted by id).
        let mut start = 0usize;
        while start < ordered.len() {
            let id = &ordered[start].identity_id;
            let mut end = start + 1;
            while end < ordered.len() && &ordered[end].identity_id == id {
                end += 1;
            }
            consolidate_one_identity(self.config.window_us, &ordered[start..end], &mut out);
            start = end;
        }

        out
    }
}

/// Pair the sites of a single identity (already sorted by `ts_us`) and
/// append the resulting edges to `out`. A free helper (not a method) so the
/// trivially-Copy [`EpisodeConsolidator`] is never passed by reference.
fn consolidate_one_identity(
    window_us: u64,
    group: &[&IdentityMentionSite],
    out: &mut Vec<DerivedEdge>,
) {
    // (lo_episode, hi_episode) -> (evidence set, latest contributing ts).
    let mut pairs: BTreeMap<(u64, u64), (BTreeSet<EntityId>, u64)> = BTreeMap::new();

    for i in 0..group.len() {
        let a = group[i];
        for b in group.iter().skip(i + 1) {
            // Sorted by ts → once the gap blows the window, every later
            // `b` is even further out. Stop scanning this `a`.
            if b.ts_us.saturating_sub(a.ts_us) > window_us {
                break;
            }
            // Same episode = same app run = not a cross-app link.
            if a.episode_id == b.episode_id {
                continue;
            }
            let (lo, hi) = if a.episode_id.0 <= b.episode_id.0 {
                (a.episode_id.0, b.episode_id.0)
            } else {
                (b.episode_id.0, a.episode_id.0)
            };
            let entry = pairs.entry((lo, hi)).or_default();
            entry.0.insert(a.entity_id.clone());
            entry.0.insert(b.entity_id.clone());
            entry.1 = entry.1.max(a.ts_us).max(b.ts_us);
        }
    }

    let identity_id = group[0].identity_id.clone();
    for ((lo, hi), (evidence, ts_us)) in pairs {
        out.push(DerivedEdge {
            src_episode_id: EpisodeId(lo),
            dst_episode_id: EpisodeId(hi),
            identity_id: identity_id.clone(),
            evidence_entity_ids: evidence.into_iter().collect(),
            ts_us,
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::EntityIdentity;

    fn ident(name: &str) -> IdentityId {
        EntityIdentity::derive_identity_id("person", name)
    }

    fn ent(kind: &str, name: &str) -> EntityId {
        crate::graph::Entity::derive_id(kind, name)
    }

    fn site(id: &IdentityId, e: &EntityId, ep: u64, ts_us: u64) -> IdentityMentionSite {
        IdentityMentionSite {
            identity_id: id.clone(),
            entity_id: e.clone(),
            episode_id: EpisodeId(ep),
            ts_us,
        }
    }

    fn c() -> EpisodeConsolidator {
        EpisodeConsolidator::default()
    }

    const S: u64 = 1_000_000; // one second in microseconds

    // ---- POSITIVE: the cross-app dot-connect path ----

    #[test]
    fn links_two_episodes_co_mentioning_one_identity_in_window() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // Messages episode 1 mentions the name at t=0; Safari episode 2
        // mentions the email 30 s later (within the 60 s window).
        let sites = vec![site(&alice, &name, 1, 0), site(&alice, &mail, 2, 30 * S)];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 1, "one cross-app edge");
        let e = &edges[0];
        assert_eq!(e.src_episode_id, EpisodeId(1));
        assert_eq!(e.dst_episode_id, EpisodeId(2));
        assert_eq!(e.identity_id, alice);
        // Evidence cites BOTH contributing member entities, sorted+deduped.
        let mut expect = vec![name.clone(), mail.clone()];
        expect.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(e.evidence_entity_ids, expect);
        // ts = latest contributing event time.
        assert_eq!(e.ts_us, 30 * S);
    }

    #[test]
    fn canonicalizes_episode_pair_regardless_of_observation_order() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // Higher-numbered episode observed FIRST in time.
        let sites = vec![site(&alice, &name, 9, 0), site(&alice, &mail, 4, 10 * S)];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 1);
        // src is always min(rowid), dst max(rowid).
        assert_eq!(edges[0].src_episode_id, EpisodeId(4));
        assert_eq!(edges[0].dst_episode_id, EpisodeId(9));
    }

    // ---- NEGATIVE / boundary guards ----

    #[test]
    fn no_edge_outside_window() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // 61 s apart — just past the 60 s window.
        let sites = vec![site(&alice, &name, 1, 0), site(&alice, &mail, 2, 61 * S)];
        assert!(c().consolidate(&sites).is_empty());
    }

    #[test]
    fn window_boundary_is_inclusive() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // Exactly 60 s — inside (gap <= window).
        let sites = vec![site(&alice, &name, 1, 0), site(&alice, &mail, 2, 60 * S)];
        assert_eq!(c().consolidate(&sites).len(), 1);
    }

    #[test]
    fn no_self_edge_within_one_episode() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // Both mentions in the SAME episode — same app run, no cross-app
        // jump, no edge.
        let sites = vec![site(&alice, &name, 5, 0), site(&alice, &mail, 5, S)];
        assert!(c().consolidate(&sites).is_empty());
    }

    #[test]
    fn different_identities_never_share_an_edge() {
        let alice = ident("alice smith");
        let bob = ident("bob jones");
        let a_name = ent("person_name", "Alice Smith");
        let b_name = ent("person_name", "Bob Jones");
        // Two different people each mentioned in the same two episodes,
        // in-window — must produce TWO distinct edges (one per identity),
        // never one merged edge.
        let sites = vec![
            site(&alice, &a_name, 1, 0),
            site(&alice, &a_name, 2, 5 * S),
            site(&bob, &b_name, 1, S),
            site(&bob, &b_name, 2, 6 * S),
        ];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 2);
        let ids: BTreeSet<&str> = edges.iter().map(|e| e.identity_id.0.as_str()).collect();
        assert!(ids.contains(alice.0.as_str()));
        assert!(ids.contains(bob.0.as_str()));
        // Each edge cites only its own identity's evidence.
        for e in &edges {
            if e.identity_id == alice {
                assert!(e.evidence_entity_ids.iter().all(|x| *x == a_name));
            } else {
                assert!(e.evidence_entity_ids.iter().all(|x| *x == b_name));
            }
        }
    }

    #[test]
    fn collapses_many_event_pairs_into_one_edge_per_episode_pair() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        // Episode 1 mentions Alice three times; episode 2 twice; all
        // in-window. 3×2 event-pairs cross the gap, but they must collapse
        // into ONE episode_edge (1↔2).
        let sites = vec![
            site(&alice, &name, 1, 0),
            site(&alice, &name, 1, 2 * S),
            site(&alice, &name, 1, 4 * S),
            site(&alice, &mail, 2, 6 * S),
            site(&alice, &mail, 2, 8 * S),
        ];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 1, "all event-pairs collapse to one edge");
        assert_eq!(edges[0].src_episode_id, EpisodeId(1));
        assert_eq!(edges[0].dst_episode_id, EpisodeId(2));
    }

    #[test]
    fn three_episodes_in_window_yield_three_pairwise_edges() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        // Three distinct episodes all within the window → 3 edges
        // (1↔2, 1↔3, 2↔3).
        let sites = vec![
            site(&alice, &name, 1, 0),
            site(&alice, &name, 2, 10 * S),
            site(&alice, &name, 3, 20 * S),
        ];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 3);
        let pairs: BTreeSet<(u64, u64)> = edges
            .iter()
            .map(|e| (e.src_episode_id.0, e.dst_episode_id.0))
            .collect();
        assert_eq!(pairs, BTreeSet::from([(1, 2), (1, 3), (2, 3)]));
    }

    #[test]
    fn duplicate_sites_per_event_dedup_in_evidence() {
        // Two extractor passes (regex + ner) surface the SAME entity on the
        // SAME event → the store join yields two identical sites. Evidence
        // must dedup to one entity, and only one edge is produced.
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        let sites = vec![
            site(&alice, &name, 1, 0),      // regex pass
            site(&alice, &name, 1, 0),      // ner pass — identical site
            site(&alice, &mail, 2, 30 * S), // cross-app mention
        ];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 1);
        let mut expect = vec![name.clone(), mail.clone()];
        expect.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(edges[0].evidence_entity_ids, expect, "name deduped once");
    }

    #[test]
    fn re_mention_in_earlier_episode_collapses_to_one_edge() {
        // Identity appears in episode 1, then 2, then 1 again (all within
        // window). The (1,2) pair must appear exactly once; the second ep-1
        // mention must NOT mint a self-edge nor a duplicate (1,2).
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        let sites = vec![
            site(&alice, &name, 1, 0),
            site(&alice, &mail, 2, 30 * S),
            site(&alice, &name, 1, 50 * S), // re-mention in ep1, in window of ep2
        ];
        let edges = c().consolidate(&sites);
        assert_eq!(edges.len(), 1, "single (1,2) edge despite re-mention");
        assert_eq!(edges[0].src_episode_id, EpisodeId(1));
        assert_eq!(edges[0].dst_episode_id, EpisodeId(2));
    }

    // ---- determinism / idempotence ----

    #[test]
    fn output_is_order_independent_and_sorted() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        let in_order = vec![site(&alice, &name, 1, 0), site(&alice, &mail, 2, 30 * S)];
        let reversed = vec![site(&alice, &mail, 2, 30 * S), site(&alice, &name, 1, 0)];
        let a = c().consolidate(&in_order);
        let b = c().consolidate(&reversed);
        assert_eq!(a, b, "consolidate is input-order-independent");
        // Re-running on the same input yields byte-identical output (the
        // pure half of the idempotence guarantee).
        assert_eq!(a, c().consolidate(&in_order));
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert!(c().consolidate(&[]).is_empty());
    }

    #[test]
    fn custom_window_widens_linkage() {
        let alice = ident("alice smith");
        let name = ent("person_name", "Alice Smith");
        let mail = ent("email", "alice.smith@corp.com");
        let sites = vec![
            site(&alice, &name, 1, 0),
            site(&alice, &mail, 2, 120 * S), // 2 min apart
        ];
        // Default 60 s → no edge.
        assert!(c().consolidate(&sites).is_empty());
        // 5-minute window → linked.
        let wide = EpisodeConsolidator::new(ConsolidatorConfig {
            window_us: 5 * 60 * S,
        });
        assert_eq!(wide.consolidate(&sites).len(), 1);
    }
}
