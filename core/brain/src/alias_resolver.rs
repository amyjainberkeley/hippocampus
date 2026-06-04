//! V2-P6 — **`AliasResolver`**: cluster alias entities into canonical
//! identities so the dot-connect recall surface can walk ONE
//! Person/Org/Location across apps.
//!
//! The V2-P4 regex tier and V2-P5 NER tier write `entities` rows that
//! are *aliases* of the same real-world thing — a person's display name
//! (`person_name`), their email (`email`), their phone (`phone`); an
//! org's name (`organization`) and its domain (`url`). This module is
//! the pure, OS-free logic that decides which aliases are the same
//! identity. The idle-batch worker
//! (`apps/agent/src/alias_resolver_worker.rs`) reads the alias entities
//! plus their co-occurrence out of the store, calls
//! [`AliasResolver::resolve`], and writes the resulting
//! [`EntityIdentity`](crate::EntityIdentity) membership rows back
//! (migration 0005).
//!
//! # ★ Precision over recall (the load-bearing design rule)
//!
//! A **wrong merge** (two different Alices collapsed into one identity)
//! is far worse than a **missed merge**: it corrupts the graph and
//! leaks one person's context into another's recall. So the resolver is
//! built to make false merges *structurally impossible*, not merely
//! unlikely:
//!
//! 1. **Strong cores never bridge.** A core (a candidate identity) is
//!    seeded ONLY by exact normalized-name equality — two `person_name`
//!    entities with the identical normalized full name, two
//!    `organization` entities with the identical normalized name, two
//!    `location` entities with the identical normalized name. Two
//!    *distinct* normalized names are two distinct cores and can NEVER
//!    be merged by any later step. (Person cores additionally require
//!    ≥2 name tokens — a bare first name is too common to anchor an
//!    identity.)
//!
//! 2. **Leaves attach to AT MOST ONE core, and never connect two.** A
//!    single-token first name, an email, a phone, or a domain is a
//!    *leaf*: it attaches to exactly one existing core when the evidence
//!    is unambiguous, and is **dropped** the moment it matches two or
//!    more cores. A leaf can therefore never act as a transitive bridge
//!    between cores (the "bare `Alice` links `Alice Smith` to `Alice
//!    Chen`" failure mode is impossible by construction).
//!
//! Consequently every entity resolves to **at most one** identity, and
//! the only merges that happen are exact-name equality (high precision
//! for a single-user brain) plus unambiguous leaf attachment.
//!
//! # Redaction discipline (POST-cascade)
//!
//! The resolver operates on already-extracted, post-cascade entities.
//! The worker only ever hands it the alias allowlist
//! (`person_name` / `organization` / `location` / `email` / `phone` /
//! `url`); `redacted_token` entities — the placeholders Tier 1 emits for
//! REDACT-shaped tokens — are excluded at the store read, so a redacted
//! credential's subkind label can never be treated as a name. The
//! resolver additionally hard-skips any entity whose kind is outside the
//! allowlist as defence in depth.
//!
//! # OS-purity
//!
//! Pure Rust, no OS calls, no clock, no randomness — the worker stamps
//! `ts_us`. Same `#![forbid(unsafe_code)]` discipline as the rest of
//! `mci-brain`.

use std::collections::{BTreeSet, HashMap};

use crate::extraction::tier1::{KIND_EMAIL, KIND_PHONE, KIND_URL};
use crate::extraction::tier2::{KIND_LOCATION, KIND_ORGANIZATION, KIND_PERSON_NAME};
use crate::graph::{EntityId, IdentityId};
use crate::EventId;

// ---------------------------------------------------------------------------
// Identity-level kinds + merge-rule provenance tags
// ---------------------------------------------------------------------------

/// Identity-level kind for a clustered person.
pub const IDENTITY_PERSON: &str = "person";
/// Identity-level kind for a clustered organization.
pub const IDENTITY_ORG: &str = "org";
/// Identity-level kind for a clustered location.
pub const IDENTITY_LOCATION: &str = "location";

/// The entity-level kinds the resolver clusters. The idle-batch worker's
/// store reads filter to exactly these (single source of truth), which
/// excludes `redacted_token` (and every other non-alias kind) so a
/// REDACT-classed token's subkind label can never be resolved into an
/// identity (`AGENT_PROTOCOL` §5 redaction discipline).
pub const RESOLVABLE_KINDS: &[&str] = &[
    KIND_PERSON_NAME,
    KIND_ORGANIZATION,
    KIND_LOCATION,
    KIND_EMAIL,
    KIND_PHONE,
    KIND_URL,
];

/// The entity that seeds a core (the canonical name itself).
pub const RULE_ANCHOR: &str = "anchor";
/// Another entity carrying the identical normalized name.
pub const RULE_EXACT_NAME: &str = "exact_name";
/// An unambiguous single-token first/last name attached to one core.
pub const RULE_NAME_VARIANT: &str = "name_variant";
/// An email whose localpart token-matches exactly one person core.
pub const RULE_EMAIL_NAME: &str = "email_name";
/// A phone that co-occurs (same event) with exactly one person core.
pub const RULE_PHONE_COOCCUR: &str = "phone_cooccur";
/// A URL whose host label equals exactly one org's name.
pub const RULE_DOMAIN_ORG: &str = "domain_org";

const CONF_ANCHOR: f32 = 1.0;
const CONF_EXACT_NAME: f32 = 1.0;
const CONF_NAME_VARIANT: f32 = 0.8;
const CONF_EMAIL_EXACT: f32 = 0.9;
const CONF_EMAIL_INITIAL: f32 = 0.75;
const CONF_PHONE: f32 = 0.7;
const CONF_DOMAIN: f32 = 0.7;

/// Leading honorifics stripped from a name before normalization (they do
/// not change identity). Generational suffixes (`jr` / `sr` / `iii`) are
/// deliberately **kept** — they distinguish a father from a son.
const HONORIFICS: &[&str] = &[
    "mr",
    "mrs",
    "ms",
    "mx",
    "miss",
    "dr",
    "prof",
    "professor",
    "sir",
    "madam",
    "rev",
];

// ---------------------------------------------------------------------------
// Public input / output types
// ---------------------------------------------------------------------------

/// One alias entity handed to the resolver. A thin projection of an
/// [`Entity`](crate::Entity) row — only the fields resolution needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolverEntity {
    /// The entity's content-stable id.
    pub id: EntityId,
    /// The entity-level kind (`"person_name"` / `"organization"` /
    /// `"location"` / `"email"` / `"phone"` / `"url"`).
    pub kind: String,
    /// The entity's canonical name (the display name / email / phone /
    /// url string).
    pub canonical_name: String,
}

/// One member of a resolved identity, with the rule that attached it.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedMember {
    /// The member alias entity.
    pub entity_id: EntityId,
    /// Which [`RULE_*`](RULE_ANCHOR) attached it.
    pub rule: String,
    /// Per-member confidence in `[0.0, 1.0]`.
    pub confidence: f32,
}

/// One canonical identity = a cluster of ≥ `min_cluster_size` alias
/// entities.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedIdentity {
    /// Content-stable identity id (derived from `(identity_kind,
    /// normalized anchor)`).
    pub identity_id: IdentityId,
    /// `"person"` / `"org"` / `"location"`.
    pub identity_kind: String,
    /// Deterministic Title-Cased display name.
    pub canonical_name: String,
    /// Members, sorted by `entity_id` for stable output.
    pub members: Vec<ResolvedMember>,
}

/// Resolver tuning. Defaults are the precision-first production values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AliasResolverConfig {
    /// Minimum number of member entities for a cluster to be emitted as
    /// an identity. Default 2 — a singleton (one lone alias) is its own
    /// implicit identity and needs no row; identities exist to UNIFY
    /// distinct aliases.
    pub min_cluster_size: usize,
}

impl Default for AliasResolverConfig {
    fn default() -> Self {
        Self {
            min_cluster_size: 2,
        }
    }
}

/// The resolver. Stateless apart from its config — `resolve` is a pure
/// function of its inputs.
#[derive(Debug, Clone, Copy, Default)]
pub struct AliasResolver {
    config: AliasResolverConfig,
}

impl AliasResolver {
    /// Construct with explicit config.
    #[must_use]
    pub fn new(config: AliasResolverConfig) -> Self {
        Self { config }
    }

    /// Resolve `entities` (the alias allowlist) plus `cooccurrences`
    /// (one entry per event: the entity ids mentioned in that event)
    /// into canonical identities.
    ///
    /// Deterministic: the same inputs always yield byte-identical output
    /// (members sorted by id, identities sorted by id), so re-running is
    /// a row-level no-op downstream.
    #[must_use]
    // The two-phase clustering (strong cores → leaf attachment, B1–B4) is
    // one cohesive pass; splitting it across helpers would scatter the
    // precision invariants that only hold when the phases run in order.
    #[allow(clippy::too_many_lines)]
    pub fn resolve(
        &self,
        entities: &[ResolverEntity],
        cooccurrences: &[(EventId, Vec<EntityId>)],
    ) -> Vec<ResolvedIdentity> {
        // Deterministic processing order.
        let mut ents: Vec<&ResolverEntity> = entities.iter().collect();
        ents.sort_by(|a, b| a.id.0.cmp(&b.id.0));

        let mut cores: Vec<Core> = Vec::new();
        // entity id -> index into `cores` (each entity in ≤1 core).
        let mut entity_to_core: HashMap<String, usize> = HashMap::new();

        // Leaves held for phase B.
        let mut single_names: Vec<(EntityId, String)> = Vec::new(); // (id, token)
        let mut emails: Vec<&ResolverEntity> = Vec::new();
        let mut phones: Vec<&ResolverEntity> = Vec::new();
        let mut urls: Vec<&ResolverEntity> = Vec::new();

        // --- Phase A: strong cores (exact normalized-name equality) ---
        for e in &ents {
            match e.kind.as_str() {
                KIND_PERSON_NAME => {
                    let norm = normalize_name(&e.canonical_name);
                    let toks = tokens(&norm);
                    if toks.len() >= 2 {
                        let idx = upsert_core(&mut cores, IDENTITY_PERSON, &norm, &toks);
                        add_member(&mut cores, idx, &mut entity_to_core, &e.id);
                    } else if toks.len() == 1 {
                        single_names.push((e.id.clone(), toks[0].clone()));
                    }
                    // 0 tokens (empty after normalization) -> ignored.
                }
                KIND_ORGANIZATION => {
                    let norm = normalize_name(&e.canonical_name);
                    let toks = tokens(&norm);
                    if !toks.is_empty() {
                        let idx = upsert_core(&mut cores, IDENTITY_ORG, &norm, &toks);
                        add_member(&mut cores, idx, &mut entity_to_core, &e.id);
                    }
                }
                KIND_LOCATION => {
                    let norm = normalize_name(&e.canonical_name);
                    let toks = tokens(&norm);
                    if !toks.is_empty() {
                        let idx = upsert_core(&mut cores, IDENTITY_LOCATION, &norm, &toks);
                        add_member(&mut cores, idx, &mut entity_to_core, &e.id);
                    }
                }
                KIND_EMAIL => emails.push(e),
                KIND_PHONE => phones.push(e),
                KIND_URL => urls.push(e),
                _ => { /* outside allowlist — defence-in-depth skip */ }
            }
        }

        // Indices for leaf matching.
        // person token -> set of person-core indices containing that token.
        let mut person_token_idx: HashMap<String, BTreeSet<usize>> = HashMap::new();
        // org normalized-name-without-spaces -> set of org-core indices.
        let mut org_label_idx: HashMap<String, BTreeSet<usize>> = HashMap::new();
        for (idx, c) in cores.iter().enumerate() {
            match c.identity_kind {
                IDENTITY_PERSON => {
                    for t in &c.tokens {
                        person_token_idx.entry(t.clone()).or_default().insert(idx);
                    }
                }
                IDENTITY_ORG => {
                    org_label_idx
                        .entry(c.tokens.join(""))
                        .or_default()
                        .insert(idx);
                }
                _ => {}
            }
        }

        // Co-occurrence: entity id -> set of event indices; event index ->
        // member entity ids. Used by phone (sole signal) and as the email
        // / domain tiebreak.
        let mut event_members: Vec<&[EntityId]> = Vec::with_capacity(cooccurrences.len());
        let mut entity_events: HashMap<String, BTreeSet<usize>> = HashMap::new();
        for (ev_idx, (_eid, members)) in cooccurrences.iter().enumerate() {
            event_members.push(members.as_slice());
            for m in members {
                entity_events.entry(m.0.clone()).or_default().insert(ev_idx);
            }
        }

        // --- Phase B: unambiguous leaf attachment ---

        // (B1) single-token names -> the unique person core holding that token.
        for (id, tok) in &single_names {
            let cand = person_token_idx.get(tok);
            if let Some(set) = cand {
                if set.len() == 1 {
                    let idx = *set.iter().next().expect("len==1");
                    attach_leaf(
                        &mut cores,
                        idx,
                        &mut entity_to_core,
                        id,
                        RULE_NAME_VARIANT,
                        CONF_NAME_VARIANT,
                    );
                }
                // ≥2 candidates -> ambiguous -> drop (no bridge).
            }
        }

        // (B2) emails -> person core by localpart. Precision-first:
        //   · STRONG match (token-set / concat equality) attaches WITHOUT
        //     co-occurrence — UNLESS the target core is contested by strong
        //     emails from ≥2 distinct domains (the homonym red flag: two
        //     different real people share a name, so two unrelated emails
        //     `j.smith@acme` + `j.smith@globex` both localpart-match the
        //     single name core). A contested attach then requires
        //     co-occurrence corroboration.
        //   · MEDIUM match (first-initial+last, e.g. `asmith`) is a weak
        //     heuristic and ALWAYS requires co-occurrence.
        //   · ≥2 strong candidate cores → co-occurrence tiebreak.
        // Pass 1: classify each email.
        let mut strong_targets: Vec<(usize, usize, String)> = Vec::new(); // (email_i, core, domain)
        let mut medium_targets: Vec<(usize, Vec<usize>)> = Vec::new(); // (email_i, medium cands)
        for (email_i, e) in emails.iter().enumerate() {
            let Some((local, domain)) = split_email(&e.canonical_name) else {
                continue;
            };
            let lp_tokens = localpart_tokens(&local);
            if lp_tokens.is_empty() {
                continue;
            }
            let (strong, medium) = email_person_candidates(&cores, &lp_tokens);
            if strong.len() == 1 {
                strong_targets.push((email_i, strong[0], domain));
            } else if strong.len() >= 2 {
                // Ambiguous strong → co-occurrence tiebreak (existing rule).
                if let Some(idx) = disambiguate(
                    strong,
                    &e.id,
                    &entity_events,
                    &event_members,
                    &entity_to_core,
                ) {
                    attach_leaf(
                        &mut cores,
                        idx,
                        &mut entity_to_core,
                        &e.id,
                        RULE_EMAIL_NAME,
                        CONF_EMAIL_EXACT,
                    );
                }
            } else if !medium.is_empty() {
                medium_targets.push((email_i, medium));
            }
        }
        // Per-core distinct strong-email domains → homonym-contest detection.
        let mut core_domains: HashMap<usize, BTreeSet<String>> = HashMap::new();
        for (_, core, domain) in &strong_targets {
            core_domains
                .entry(*core)
                .or_default()
                .insert(domain.clone());
        }
        // Pass 2a: attach strong matches, gating contested cores on co-occurrence.
        for (email_i, core, _domain) in &strong_targets {
            let contested = core_domains.get(core).is_some_and(|d| d.len() >= 2);
            let attach = !contested
                || cooccurring_cores(
                    &emails[*email_i].id,
                    &entity_events,
                    &event_members,
                    &entity_to_core,
                    &cores,
                    IDENTITY_PERSON,
                )
                .contains(core);
            if attach {
                attach_leaf(
                    &mut cores,
                    *core,
                    &mut entity_to_core,
                    &emails[*email_i].id,
                    RULE_EMAIL_NAME,
                    CONF_EMAIL_EXACT,
                );
            }
        }
        // Pass 2b: attach medium (initial+last) only via co-occurrence.
        for (email_i, cands) in medium_targets {
            let co = cooccurring_core_indices(
                &emails[email_i].id,
                &entity_events,
                &event_members,
                &entity_to_core,
            );
            let kept: Vec<usize> = cands.into_iter().filter(|i| co.contains(i)).collect();
            if kept.len() == 1 {
                attach_leaf(
                    &mut cores,
                    kept[0],
                    &mut entity_to_core,
                    &emails[email_i].id,
                    RULE_EMAIL_NAME,
                    CONF_EMAIL_INITIAL,
                );
            }
        }

        // (B3) phones -> the unique person core they co-occur with (sole
        // signal: a phone number carries no semantic content).
        for p in &phones {
            let co_cores = cooccurring_cores(
                &p.id,
                &entity_events,
                &event_members,
                &entity_to_core,
                &cores,
                IDENTITY_PERSON,
            );
            if co_cores.len() == 1 {
                let idx = *co_cores.iter().next().expect("len==1");
                attach_leaf(
                    &mut cores,
                    idx,
                    &mut entity_to_core,
                    &p.id,
                    RULE_PHONE_COOCCUR,
                    CONF_PHONE,
                );
            }
            // 0 or ≥2 distinct person cores -> ambiguous -> drop.
        }

        // (B4) urls -> the unique org core whose name equals the host label.
        for u in &urls {
            let Some(label) = url_host_label(&u.canonical_name) else {
                continue;
            };
            let cands: Vec<usize> = org_label_idx
                .get(&label)
                .map(|s| s.iter().copied().collect())
                .unwrap_or_default();
            let chosen = disambiguate(
                cands,
                &u.id,
                &entity_events,
                &event_members,
                &entity_to_core,
            );
            if let Some(idx) = chosen {
                attach_leaf(
                    &mut cores,
                    idx,
                    &mut entity_to_core,
                    &u.id,
                    RULE_DOMAIN_ORG,
                    CONF_DOMAIN,
                );
            }
        }

        // --- Emit clusters of size >= min_cluster_size ---
        let mut out: Vec<ResolvedIdentity> = Vec::new();
        for c in cores {
            if c.member_ids.len() < self.config.min_cluster_size {
                continue;
            }
            let mut members = c.members;
            members.sort_by(|a, b| a.entity_id.0.cmp(&b.entity_id.0));
            out.push(ResolvedIdentity {
                identity_id: c.identity_id,
                identity_kind: c.identity_kind.to_string(),
                canonical_name: c.canonical_name,
                members,
            });
        }
        out.sort_by(|a, b| a.identity_id.0.cmp(&b.identity_id.0));
        out
    }
}

// ---------------------------------------------------------------------------
// Internal core type + helpers
// ---------------------------------------------------------------------------

struct Core {
    identity_id: IdentityId,
    identity_kind: &'static str,
    canonical_name: String,
    /// Normalized tokens of the anchor name (person/org/location).
    tokens: Vec<String>,
    members: Vec<ResolvedMember>,
    member_ids: BTreeSet<String>,
    /// Normalized anchor — keyed for core lookup.
    norm: String,
}

/// Find-or-create the core for `(kind, norm)`. The first entity to reach
/// a core anchors it; later same-normalized entities reuse it.
fn upsert_core(
    cores: &mut Vec<Core>,
    identity_kind: &'static str,
    norm: &str,
    toks: &[String],
) -> usize {
    if let Some(i) = cores
        .iter()
        .position(|c| c.identity_kind == identity_kind && c.norm == norm)
    {
        return i;
    }
    let identity_id = crate::graph::EntityIdentity::derive_identity_id(identity_kind, norm);
    cores.push(Core {
        identity_id,
        identity_kind,
        canonical_name: title_case(toks),
        tokens: toks.to_vec(),
        members: Vec::new(),
        member_ids: BTreeSet::new(),
        norm: norm.to_string(),
    });
    cores.len() - 1
}

/// Add a name entity to core `idx`. The lex-first member is the `anchor`;
/// later members carrying the identical normalized name are `exact_name`.
/// Also records the entity → core index so later co-occurrence lookups
/// can map a co-mentioned entity back to its identity.
fn add_member(
    cores: &mut [Core],
    idx: usize,
    entity_to_core: &mut HashMap<String, usize>,
    id: &EntityId,
) {
    let core = &mut cores[idx];
    if core.member_ids.contains(&id.0) {
        return;
    }
    let rule = if core.members.is_empty() {
        (RULE_ANCHOR, CONF_ANCHOR)
    } else {
        (RULE_EXACT_NAME, CONF_EXACT_NAME)
    };
    core.members.push(ResolvedMember {
        entity_id: id.clone(),
        rule: rule.0.to_string(),
        confidence: rule.1,
    });
    core.member_ids.insert(id.0.clone());
    entity_to_core.insert(id.0.clone(), idx);
}

/// Attach a leaf entity to core `idx` under `rule`. No-op if the entity
/// is already a member (an entity resolves to at most one identity).
/// Records the entity → core index for downstream co-occurrence lookups.
fn attach_leaf(
    cores: &mut [Core],
    idx: usize,
    entity_to_core: &mut HashMap<String, usize>,
    id: &EntityId,
    rule: &str,
    confidence: f32,
) {
    let core = &mut cores[idx];
    if core.member_ids.contains(&id.0) {
        return;
    }
    core.members.push(ResolvedMember {
        entity_id: id.clone(),
        rule: rule.to_string(),
        confidence,
    });
    core.member_ids.insert(id.0.clone());
    entity_to_core.insert(id.0.clone(), idx);
}

/// Person-core candidates for an email localpart, split by match
/// strength: `(strong, medium)`.
///
/// - **strong** — the localpart token SET equals the core name token set,
///   or the concatenated localpart equals the concatenated name (e.g.
///   `alice.smith` / `alicesmith` ↔ `["alice","smith"]`). High precision.
/// - **medium** — first-initial + last name (e.g. `asmith` ↔ `a`+`smith`).
///   A weak heuristic — many people match — so the caller attaches it
///   ONLY with co-occurrence corroboration.
///
/// `medium` is computed only when `strong` is empty (a strong match never
/// needs the weaker rule).
fn email_person_candidates(cores: &[Core], lp_tokens: &[String]) -> (Vec<usize>, Vec<usize>) {
    let lp_set: BTreeSet<&String> = lp_tokens.iter().collect();
    let lp_joined: String = lp_tokens.concat();

    let mut strong: Vec<usize> = Vec::new();
    for (idx, c) in cores.iter().enumerate() {
        if c.identity_kind != IDENTITY_PERSON {
            continue;
        }
        let name_set: BTreeSet<&String> = c.tokens.iter().collect();
        let name_joined: String = c.tokens.concat();
        if lp_set == name_set || lp_joined == name_joined {
            strong.push(idx);
        }
    }
    if !strong.is_empty() {
        return (strong, Vec::new());
    }

    // Medium: first-initial + last name, only when the localpart is a
    // single token.
    let mut medium: Vec<usize> = Vec::new();
    if lp_tokens.len() == 1 {
        let lp = &lp_tokens[0];
        for (idx, c) in cores.iter().enumerate() {
            if c.identity_kind != IDENTITY_PERSON || c.tokens.len() < 2 {
                continue;
            }
            let first = &c.tokens[0];
            let last = &c.tokens[c.tokens.len() - 1];
            if let Some(fc) = first.chars().next() {
                let pat = format!("{fc}{last}");
                if *lp == pat {
                    medium.push(idx);
                }
            }
        }
    }
    (strong, medium)
}

/// Pick the unique candidate, breaking a tie by co-occurrence. Returns
/// `None` (drop) when 0 candidates, or when ≥2 remain after the tiebreak.
fn disambiguate(
    cands: Vec<usize>,
    leaf_id: &EntityId,
    entity_events: &HashMap<String, BTreeSet<usize>>,
    event_members: &[&[EntityId]],
    entity_to_core: &HashMap<String, usize>,
) -> Option<usize> {
    match cands.len() {
        0 => None,
        1 => Some(cands[0]),
        _ => {
            // Tiebreak: keep only candidates that co-occur with the leaf.
            let co: BTreeSet<usize> =
                cooccurring_core_indices(leaf_id, entity_events, event_members, entity_to_core);
            let kept: Vec<usize> = cands.into_iter().filter(|i| co.contains(i)).collect();
            if kept.len() == 1 {
                Some(kept[0])
            } else {
                None
            }
        }
    }
}

/// All core indices that co-occur (share an event) with `leaf_id`.
fn cooccurring_core_indices(
    leaf_id: &EntityId,
    entity_events: &HashMap<String, BTreeSet<usize>>,
    event_members: &[&[EntityId]],
    entity_to_core: &HashMap<String, usize>,
) -> BTreeSet<usize> {
    let mut out = BTreeSet::new();
    if let Some(evs) = entity_events.get(&leaf_id.0) {
        for &ev in evs {
            for other in event_members[ev] {
                if other.0 == leaf_id.0 {
                    continue;
                }
                if let Some(&ci) = entity_to_core.get(&other.0) {
                    out.insert(ci);
                }
            }
        }
    }
    out
}

/// Co-occurring cores restricted to a given identity kind.
fn cooccurring_cores(
    leaf_id: &EntityId,
    entity_events: &HashMap<String, BTreeSet<usize>>,
    event_members: &[&[EntityId]],
    entity_to_core: &HashMap<String, usize>,
    cores: &[Core],
    identity_kind: &str,
) -> BTreeSet<usize> {
    cooccurring_core_indices(leaf_id, entity_events, event_members, entity_to_core)
        .into_iter()
        .filter(|&i| cores[i].identity_kind == identity_kind)
        .collect()
}

// ---------------------------------------------------------------------------
// Normalization + parsing helpers (pure, ASCII-fold)
// ---------------------------------------------------------------------------

/// Lower-case, replace every non-alphanumeric byte with a space, collapse
/// runs of whitespace, strip leading honorifics. Deterministic.
fn normalize_name(s: &str) -> String {
    let lowered: String = s
        .chars()
        .map(|c| {
            if c.is_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect();
    let mut toks: Vec<&str> = lowered.split_whitespace().collect();
    while toks.len() > 1 && HONORIFICS.contains(&toks[0]) {
        toks.remove(0);
    }
    toks.join(" ")
}

fn tokens(normalized: &str) -> Vec<String> {
    normalized
        .split_whitespace()
        .map(std::string::ToString::to_string)
        .collect()
}

/// Title-case a normalized token list for display ("alice smith" ->
/// "Alice Smith"). Deterministic and independent of which surface forms
/// were present, so the denormalized display name on every membership
/// row of one identity is identical.
fn title_case(toks: &[String]) -> String {
    toks.iter()
        .map(|t| {
            let mut ch = t.chars();
            match ch.next() {
                None => String::new(),
                Some(f) => f.to_ascii_uppercase().to_string() + ch.as_str(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Split an email into `(localpart, domain)`, both lower-cased. `None`
/// if there is no single `@`.
fn split_email(s: &str) -> Option<(String, String)> {
    let s = s.trim().to_ascii_lowercase();
    let (local, domain) = s.split_once('@')?;
    if local.is_empty() || domain.is_empty() || domain.contains('@') {
        return None;
    }
    Some((local.to_string(), domain.to_string()))
}

/// Tokenize an email localpart: split on `. _ + -`, drop trailing digits
/// from each part, drop empties. `alice.smith2+newsletter` ->
/// `["alice", "smith"]`.
fn localpart_tokens(local: &str) -> Vec<String> {
    local
        .split(['.', '_', '+', '-'])
        .map(|p| p.trim_end_matches(|c: char| c.is_ascii_digit()))
        .filter(|p| !p.is_empty())
        .map(std::string::ToString::to_string)
        .collect()
}

/// Extract the registrable host label from a URL or bare host:
/// `https://www.stripe.com/pricing` -> `stripe`. `None` if no host or no
/// dot (a hostless string cannot identify a domain).
fn url_host_label(s: &str) -> Option<String> {
    let s = s.trim().to_ascii_lowercase();
    // Strip scheme.
    let after_scheme = s.split_once("://").map_or(s.as_str(), |(_, rest)| rest);
    // Host = up to first '/', '?', '#'.
    let host: &str = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(after_scheme);
    // Drop userinfo / port.
    let host = host.rsplit('@').next().unwrap_or(host);
    let host = host.split(':').next().unwrap_or(host);
    let host = host.strip_prefix("www.").unwrap_or(host);
    let labels: Vec<&str> = host.split('.').filter(|l| !l.is_empty()).collect();
    let n = labels.len();
    if n < 2 {
        return None;
    }
    // An all-numeric host is an IPv4 address, not a domain — never a label.
    if labels.iter().all(|l| l.chars().all(|c| c.is_ascii_digit())) {
        return None;
    }
    // Registrable label = the label left of the public suffix. The naive
    // "second-to-last label" is WRONG for multi-level public suffixes
    // (`barclays.co.uk` → `co`, not `barclays`), which would let two
    // unrelated `*.co.uk` orgs both match a phantom "Co" org and bridge.
    // Recognise the common multi-level suffixes and step one label further
    // left for them.
    let last_two = format!("{}.{}", labels[n - 2], labels[n - 1]);
    if n >= 3 && MULTI_LEVEL_PUBLIC_SUFFIXES.contains(&last_two.as_str()) {
        return Some(labels[n - 3].to_string());
    }
    Some(labels[n - 2].to_string())
}

/// Common multi-level public suffixes (eTLDs) where the registrable label
/// is the THIRD-from-last, not the second. Not a full Public Suffix List
/// (that would need a bundled data file / crate, ADR-0008) — just the
/// high-traffic ccTLD second levels, enough to stop the `*.co.uk`-style
/// cross-org bridge. Unknown multi-level suffixes fall back to the
/// second-to-last label, which is precision-preserving (a wrong label
/// simply fails to match any org name rather than matching the wrong one).
const MULTI_LEVEL_PUBLIC_SUFFIXES: &[&str] = &[
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au", "co.nz", "org.nz", "net.nz",
    "govt.nz", "ac.nz", "co.za", "org.za", "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp", "com.br",
    "net.br", "org.br", "gov.br", "co.in", "net.in", "org.in", "gov.in", "ac.in", "com.cn",
    "net.cn", "org.cn", "gov.cn", "com.sg", "edu.sg", "gov.sg", "com.hk", "org.hk", "com.mx",
    "com.tr", "com.tw", "co.kr", "or.kr", "com.ar", "com.pl", "com.ua",
];

// ---------------------------------------------------------------------------
// Tests — the false-merge corpus. Each test asserts a precision property:
// the right things merge AND, crucially, the wrong things never do.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn person(name: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_PERSON_NAME, name),
            kind: KIND_PERSON_NAME.to_string(),
            canonical_name: name.to_string(),
        }
    }
    fn org(name: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_ORGANIZATION, name),
            kind: KIND_ORGANIZATION.to_string(),
            canonical_name: name.to_string(),
        }
    }
    fn email(addr: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_EMAIL, addr),
            kind: KIND_EMAIL.to_string(),
            canonical_name: addr.to_string(),
        }
    }
    fn phone(num: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_PHONE, num),
            kind: KIND_PHONE.to_string(),
            canonical_name: num.to_string(),
        }
    }
    fn url(u: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_URL, u),
            kind: KIND_URL.to_string(),
            canonical_name: u.to_string(),
        }
    }
    fn loc(name: &str) -> ResolverEntity {
        ResolverEntity {
            id: crate::graph::Entity::derive_id(KIND_LOCATION, name),
            kind: KIND_LOCATION.to_string(),
            canonical_name: name.to_string(),
        }
    }

    fn r() -> AliasResolver {
        AliasResolver::default()
    }

    /// Find the identity containing a given entity id, if any.
    fn identity_of<'a>(out: &'a [ResolvedIdentity], id: &EntityId) -> Option<&'a ResolvedIdentity> {
        out.iter()
            .find(|i| i.members.iter().any(|m| m.entity_id == *id))
    }

    // ---- POSITIVE: the dot-connect demo path must merge ----

    #[test]
    fn merges_name_email_phone_for_one_person() {
        let alice = person("Alice Smith");
        let mail = email("alice.smith@corp.com");
        let ph = phone("+1 555 123 4567");
        // phone co-occurs with the name in one event.
        let co = vec![(EventId(1), vec![alice.id.clone(), ph.id.clone()])];
        let out = r().resolve(&[alice.clone(), mail.clone(), ph.clone()], &co);
        assert_eq!(out.len(), 1, "one identity");
        let id = &out[0];
        assert_eq!(id.identity_kind, IDENTITY_PERSON);
        assert_eq!(id.canonical_name, "Alice Smith");
        let ids: BTreeSet<&str> = id.members.iter().map(|m| m.entity_id.0.as_str()).collect();
        assert!(ids.contains(alice.id.0.as_str()));
        assert!(ids.contains(mail.id.0.as_str()));
        assert!(ids.contains(ph.id.0.as_str()));
    }

    #[test]
    fn merges_two_surface_forms_of_same_name() {
        // Two entity rows, same normalized name -> one identity.
        let a = person("Alice Smith");
        let b = person("alice  smith"); // different surface, same normalized
        let out = r().resolve(&[a.clone(), b.clone()], &[]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].members.len(), 2);
    }

    #[test]
    fn merges_org_with_its_domain_url() {
        let stripe = org("Stripe");
        let site = url("https://www.stripe.com/pricing");
        let out = r().resolve(&[stripe.clone(), site.clone()], &[]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].identity_kind, IDENTITY_ORG);
        assert!(identity_of(&out, &site.id).is_some());
    }

    // ---- NEGATIVE: the false-merge guards ----

    #[test]
    fn never_merges_two_distinct_same_first_name_people() {
        // The canonical false-merge guard: Alice Smith vs Alice Chen.
        let smith = person("Alice Smith");
        let chen = person("Alice Chen");
        let out = r().resolve(&[smith.clone(), chen.clone()], &[]);
        // Distinct full names -> distinct cores -> neither reaches size 2
        // -> no identity emitted at all.
        assert!(out.is_empty(), "two distinct people must never merge");
    }

    #[test]
    fn bare_first_name_never_bridges_two_people() {
        // "Alice" must NOT connect "Alice Smith" and "Alice Chen".
        let smith = person("Alice Smith");
        let chen = person("Alice Chen");
        let bare = person("Alice");
        let out = r().resolve(&[smith.clone(), chen.clone(), bare.clone()], &[]);
        // bare "Alice" matches 2 cores -> dropped. Cores stay separate and
        // singleton -> nothing emitted.
        assert!(out.is_empty());
        // And specifically: Smith and Chen are never in the same identity.
        for idy in &out {
            let has_smith = idy.members.iter().any(|m| m.entity_id == smith.id);
            let has_chen = idy.members.iter().any(|m| m.entity_id == chen.id);
            assert!(!(has_smith && has_chen));
        }
    }

    #[test]
    fn bare_first_name_attaches_when_unique() {
        // With only ONE "Alice * " core, bare "Alice" attaches.
        let smith = person("Alice Smith");
        let bare = person("Alice");
        let out = r().resolve(&[smith.clone(), bare.clone()], &[]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].members.len(), 2);
        let variant = out[0]
            .members
            .iter()
            .find(|m| m.entity_id == bare.id)
            .expect("bare attached");
        assert_eq!(variant.rule, RULE_NAME_VARIANT);
    }

    #[test]
    fn email_never_merges_into_wrong_name() {
        // alice.smith@ must not attach to "Alice Chen".
        let chen = person("Alice Chen");
        let mail = email("alice.smith@corp.com");
        let out = r().resolve(&[chen.clone(), mail.clone()], &[]);
        // localpart tokens {alice,smith} != {alice,chen} -> no match ->
        // chen singleton, mail unattached -> nothing emitted.
        assert!(out.is_empty());
    }

    #[test]
    fn email_localpart_collision_is_dropped_without_cooccurrence() {
        // Two people whose names both token-match "jsmith"? Construct an
        // exact-set collision: "Sam Carter" and "Carter Sam" both
        // normalize to token-set {carter, sam}. An email "sam.carter@x"
        // matches both -> ambiguous -> dropped (no co-occurrence).
        let p1 = person("Sam Carter");
        let p2 = person("Carter Sam");
        let mail = email("sam.carter@x.com");
        let out = r().resolve(&[p1.clone(), p2.clone(), mail.clone()], &[]);
        // Neither person core gains the email; both stay singleton.
        assert!(
            identity_of(&out, &mail.id).is_none(),
            "ambiguous email dropped"
        );
    }

    #[test]
    fn email_collision_resolved_by_cooccurrence() {
        let p1 = person("Sam Carter");
        let p2 = person("Carter Sam");
        let mail = email("sam.carter@x.com");
        // The email co-occurs with p1 only.
        let co = vec![(EventId(9), vec![p1.id.clone(), mail.id.clone()])];
        let out = r().resolve(&[p1.clone(), p2.clone(), mail.clone()], &co);
        let idy = identity_of(&out, &mail.id).expect("email attached via co-occurrence");
        assert!(idy.members.iter().any(|m| m.entity_id == p1.id));
        assert!(!idy.members.iter().any(|m| m.entity_id == p2.id));
    }

    #[test]
    fn phone_never_merges_when_cooccurs_with_two_people() {
        let a = person("Alice Smith");
        let b = person("Bob Jones");
        let ph = phone("+1 555 000 1111");
        // Phone appears in a signature block alongside BOTH people.
        let co = vec![(EventId(2), vec![a.id.clone(), b.id.clone(), ph.id.clone()])];
        let out = r().resolve(&[a.clone(), b.clone(), ph.clone()], &co);
        // Ambiguous co-occurrence -> phone dropped -> no identity (each
        // person singleton).
        assert!(identity_of(&out, &ph.id).is_none());
    }

    #[test]
    fn phone_attaches_on_unambiguous_cooccurrence() {
        let a = person("Alice Smith");
        let ph = phone("+1 555 222 3333");
        let co = vec![(EventId(3), vec![a.id.clone(), ph.id.clone()])];
        let out = r().resolve(&[a.clone(), ph.clone()], &co);
        let idy = identity_of(&out, &ph.id).expect("phone attached");
        assert_eq!(
            idy.members
                .iter()
                .find(|m| m.entity_id == ph.id)
                .unwrap()
                .rule,
            RULE_PHONE_COOCCUR
        );
    }

    #[test]
    fn org_never_merges_with_lookalike_domain() {
        // "Stripe" org vs a lookalike "stripes.com" url -> labels differ
        // ("stripe" vs "stripes") -> no merge.
        let stripe = org("Stripe");
        let look = url("https://stripes.com");
        let out = r().resolve(&[stripe.clone(), look.clone()], &[]);
        assert!(identity_of(&out, &look.id).is_none());
    }

    #[test]
    fn distinct_orgs_never_merge() {
        let a = org("Acme");
        let b = org("Globex");
        let out = r().resolve(&[a, b], &[]);
        assert!(out.is_empty());
    }

    #[test]
    fn location_exact_name_merges_two_rows_only() {
        let p1 = loc("Paris");
        let p2 = loc("paris");
        let other = loc("London");
        let out = r().resolve(&[p1.clone(), p2.clone(), other.clone()], &[]);
        // Paris+paris -> one identity; London singleton -> not emitted.
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].identity_kind, IDENTITY_LOCATION);
        assert_eq!(out[0].canonical_name, "Paris");
        assert!(identity_of(&out, &other.id).is_none());
    }

    #[test]
    fn redacted_token_kind_never_resolves() {
        // A redacted_token entity (subkind label as canonical_name) must
        // never enter an identity even if it shares text with a name.
        let redacted = ResolverEntity {
            id: EntityId("SEEDREDACTED00000000000000".to_string()),
            kind: "redacted_token".to_string(),
            canonical_name: "jwt".to_string(),
        };
        let p = person("Jwt Token"); // adversarial: name overlaps subkind
        let out = r().resolve(&[redacted.clone(), p.clone()], &[]);
        assert!(identity_of(&out, &redacted.id).is_none());
    }

    #[test]
    fn each_entity_in_at_most_one_identity() {
        // Property: across a mixed corpus, no entity appears in two
        // identities.
        let ents = vec![
            person("Alice Smith"),
            person("Alice"),
            email("alice.smith@corp.com"),
            phone("+1 555 9 9 9"),
            org("Stripe"),
            url("https://stripe.com"),
            person("Bob Jones"),
            email("bob.jones@corp.com"),
        ];
        let co = vec![(EventId(1), vec![ents[0].id.clone(), ents[3].id.clone()])];
        let out = r().resolve(&ents, &co);
        let mut seen: BTreeSet<String> = BTreeSet::new();
        for idy in &out {
            for m in &idy.members {
                assert!(
                    seen.insert(m.entity_id.0.clone()),
                    "entity {} in two identities",
                    m.entity_id.0
                );
            }
        }
    }

    // ---- Determinism / content-stability ----

    #[test]
    fn resolve_is_deterministic_and_order_independent() {
        let a = person("Alice Smith");
        let mail = email("alice.smith@corp.com");
        let url1 = url("https://stripe.com");
        let stripe = org("Stripe");
        let forward = r().resolve(
            &[a.clone(), mail.clone(), stripe.clone(), url1.clone()],
            &[],
        );
        let reversed = r().resolve(&[url1, stripe, mail, a], &[]);
        assert_eq!(forward, reversed, "output independent of input order");
    }

    #[test]
    fn identity_id_is_anchor_stable_when_alias_added() {
        // Adding the email later must NOT move the identity id (it is
        // anchored on the name, present in both runs).
        let a = person("Alice Smith");
        let mail = email("alice.smith@corp.com");
        let extra = person("Alice"); // a second alias, added in run 2
        let run1 = r().resolve(&[a.clone(), mail.clone()], &[]);
        let run2 = r().resolve(&[a.clone(), mail.clone(), extra.clone()], &[]);
        assert_eq!(run1.len(), 1);
        assert_eq!(run2.len(), 1);
        assert_eq!(
            run1[0].identity_id, run2[0].identity_id,
            "identity id is anchor-stable across incremental growth"
        );
    }

    #[test]
    fn singletons_are_not_emitted() {
        // A lone name with no aliases -> no identity row.
        let out = r().resolve(&[person("Solo Person")], &[]);
        assert!(out.is_empty());
    }

    #[test]
    fn min_cluster_size_one_emits_singletons() {
        let cfg = AliasResolverConfig {
            min_cluster_size: 1,
        };
        let out = AliasResolver::new(cfg).resolve(&[person("Solo Person")], &[]);
        assert_eq!(out.len(), 1);
    }

    // ---- normalization unit checks ----

    #[test]
    fn normalize_strips_honorific_keeps_suffix() {
        assert_eq!(normalize_name("Dr. Alice Smith"), "alice smith");
        // Jr is kept — father vs son must not merge.
        assert_eq!(normalize_name("John Smith Jr"), "john smith jr");
        assert_ne!(
            normalize_name("John Smith"),
            normalize_name("John Smith Jr")
        );
    }

    #[test]
    fn localpart_tokenization() {
        assert_eq!(localpart_tokens("alice.smith"), vec!["alice", "smith"]);
        assert_eq!(
            localpart_tokens("alice.smith2+news"),
            vec!["alice", "smith", "news"]
        );
        assert_eq!(localpart_tokens("asmith"), vec!["asmith"]);
    }

    #[test]
    fn url_label_extraction() {
        assert_eq!(
            url_host_label("https://www.stripe.com/x"),
            Some("stripe".to_string())
        );
        assert_eq!(
            url_host_label("http://mail.corp.com"),
            Some("corp".to_string())
        );
        assert_eq!(url_host_label("stripe.com"), Some("stripe".to_string()));
        assert_eq!(url_host_label("localhost"), None);
        // Multi-level public suffixes resolve to the registrable label,
        // not the ccTLD second level (regression: barclays.co.uk → "co").
        assert_eq!(
            url_host_label("https://www.barclays.co.uk/x"),
            Some("barclays".to_string())
        );
        assert_eq!(url_host_label("tesco.co.uk"), Some("tesco".to_string()));
        assert_eq!(url_host_label("foo.com.au"), Some("foo".to_string()));
        // An IPv4 host is not a domain.
        assert_eq!(url_host_label("http://192.168.0.1/x"), None);
    }

    // ---- regression: adversarial-workflow findings ----

    #[test]
    fn email_initial_last_requires_cooccurrence() {
        // FINDING (email-localpart-collision): "asmith@" is first-initial +
        // last — a weak heuristic that matches Anna/Alex/Andy Smith. It must
        // NOT attach without corroboration.
        let a = person("Anna Smith");
        let mail = email("asmith@corp.com");
        let out = r().resolve(&[a.clone(), mail.clone()], &[]);
        assert!(
            identity_of(&out, &mail.id).is_none(),
            "initial+last email must not attach without co-occurrence"
        );
        // With co-occurrence it DOES attach (corroborated).
        let co = vec![(EventId(1), vec![a.id.clone(), mail.id.clone()])];
        let out2 = r().resolve(&[a.clone(), mail.clone()], &co);
        let idy = identity_of(&out2, &mail.id).expect("attaches with co-occurrence");
        assert_eq!(
            idy.members
                .iter()
                .find(|m| m.entity_id == mail.id)
                .unwrap()
                .rule,
            RULE_EMAIL_NAME
        );
    }

    #[test]
    fn multi_domain_emails_same_localpart_need_cooccurrence() {
        // FINDING (homonym-same-name): two DIFFERENT real people share the
        // name "John Smith" → one upstream person entity → one core. Their
        // two emails — john.smith@acme.com and john.smith@globex.com —
        // both localpart-match. Auto-attaching BOTH glues two people's
        // context together. The different-domain contest must require
        // co-occurrence: with none, neither attaches.
        let john = person("John Smith");
        let acme = email("john.smith@acme.com");
        let globex = email("john.smith@globex.com");
        let out = r().resolve(&[john.clone(), acme.clone(), globex.clone()], &[]);
        assert!(
            identity_of(&out, &acme.id).is_none(),
            "contested email (acme) must not auto-attach"
        );
        assert!(
            identity_of(&out, &globex.id).is_none(),
            "contested email (globex) must not auto-attach"
        );
        // A SINGLE email on one domain still attaches freely (the demo path).
        let out_single = r().resolve(&[john.clone(), acme.clone()], &[]);
        assert!(
            identity_of(&out_single, &acme.id).is_some(),
            "a single same-name email still attaches (cross-app demo)"
        );
        // Co-occurrence disambiguates the contest: only the corroborated
        // email attaches.
        let co = vec![(EventId(7), vec![john.id.clone(), acme.id.clone()])];
        let out_co = r().resolve(&[john.clone(), acme.clone(), globex.clone()], &co);
        assert!(
            identity_of(&out_co, &acme.id).is_some(),
            "co-occurring email attaches"
        );
        assert!(
            identity_of(&out_co, &globex.id).is_none(),
            "non-co-occurring contested email stays out"
        );
    }

    #[test]
    fn same_domain_two_emails_attach_freely() {
        // Two emails, same domain, both strong-match → not a homonym
        // contest (one org, likely one person with two handles). Both
        // attach without co-occurrence.
        let alice = person("Alice Smith");
        let m1 = email("alice.smith@corp.com");
        let m2 = email("alicesmith@corp.com");
        let out = r().resolve(&[alice.clone(), m1.clone(), m2.clone()], &[]);
        let idy = identity_of(&out, &m1.id).expect("m1 attaches");
        assert!(
            idy.members.iter().any(|m| m.entity_id == m2.id),
            "m2 also attaches"
        );
    }

    #[test]
    fn org_domain_multi_level_tld_no_cross_org_bridge() {
        // FINDING (org-domain): two unrelated UK orgs on *.co.uk must NOT
        // bridge through the ccTLD label "co".
        let barclays = org("Barclays");
        let tesco = org("Tesco");
        let b_url = url("https://www.barclays.co.uk/login");
        let t_url = url("https://www.tesco.co.uk/groceries");
        let out = r().resolve(
            &[
                barclays.clone(),
                tesco.clone(),
                b_url.clone(),
                t_url.clone(),
            ],
            &[],
        );
        // Each url attaches to its OWN org; no identity spans both orgs.
        for idy in &out {
            let has_b = idy.members.iter().any(|m| m.entity_id == barclays.id);
            let has_t = idy.members.iter().any(|m| m.entity_id == tesco.id);
            assert!(!(has_b && has_t), "two distinct orgs must never bridge");
        }
        // Barclays url resolves to Barclays (registrable label, not "co").
        let b_id = identity_of(&out, &b_url.id).expect("barclays url attaches");
        assert!(b_id.members.iter().any(|m| m.entity_id == barclays.id));
    }
}
