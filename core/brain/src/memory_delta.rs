//! Immutable inputs and outputs for governed memory projection.

use sha2::{Digest, Sha256};

use crate::episode_segmenter::EpisodeId;
use crate::EventId;
use crate::{EntityId, IdentityId};

/// Stable identifier for one evidence row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EvidenceId(pub String);

/// Stable identifier for one claim row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MemoryClaimId(pub String);

/// Durable claim state. New assertions may be `Proposed` or `Active`; the
/// remaining variants are append-only transitions produced by the projector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaimStatus {
    /// Unsupported or model-authored statement excluded from current facts.
    Proposed,
    /// Source-backed claim eligible for the current-fact view.
    Active,
    /// Claim replaced by one explicit correction.
    Superseded,
    /// Claim withdrawn because its source event was retracted.
    Retracted,
    /// Claim explicitly marked contradictory without selecting a winner.
    Contradicted,
}

impl ClaimStatus {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Proposed => "proposed",
            Self::Active => "active",
            Self::Superseded => "superseded",
            Self::Retracted => "retracted",
            Self::Contradicted => "contradicted",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "proposed" => Some(Self::Proposed),
            "active" => Some(Self::Active),
            "superseded" => Some(Self::Superseded),
            "retracted" => Some(Self::Retracted),
            "contradicted" => Some(Self::Contradicted),
            _ => None,
        }
    }
}

/// One immutable, event-anchored evidence reference.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceRef {
    /// Content-stable row identifier.
    pub id: EvidenceId,
    /// Canonical event that contains the evidence.
    pub event_id: EventId,
    /// Capture/source class, such as `structured_app`, `file`, or `ocr`.
    pub source_kind: String,
    /// Stable source locator, such as a GitHub URL or local file URI.
    pub source_locator: String,
    /// Source-specific visibility or organizational scope.
    pub source_scope: String,
    /// When the source was observed, supplied by the caller.
    pub observed_at_us: u64,
    /// Digest of the preserved source content.
    pub content_hash: String,
}

impl EvidenceRef {
    /// Construct an evidence reference and derive its stable identifier.
    #[must_use]
    pub fn new(
        event_id: EventId,
        source_kind: &str,
        source_locator: &str,
        source_scope: &str,
        observed_at_us: u64,
        content_hash: &str,
    ) -> Self {
        let observed = observed_at_us.to_be_bytes();
        let event = event_id.0.to_be_bytes();
        let id = EvidenceId(stable_id(&[
            b"evidence",
            &event,
            source_kind.as_bytes(),
            source_locator.as_bytes(),
            source_scope.as_bytes(),
            &observed,
            content_hash.as_bytes(),
        ]));
        Self {
            id,
            event_id,
            source_kind: source_kind.to_owned(),
            source_locator: source_locator.to_owned(),
            source_scope: source_scope.to_owned(),
            observed_at_us,
            content_hash: content_hash.to_owned(),
        }
    }
}

/// One immutable claim assertion and its evidence anchors.
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryClaim {
    /// Content-stable claim identifier.
    pub id: MemoryClaimId,
    /// Entity or topic the statement is about.
    pub subject: String,
    /// Relation or property being asserted.
    pub predicate: String,
    /// Asserted value.
    pub object: String,
    /// Hierarchical claim scope, with `/` delimiting narrower scopes.
    pub scope: String,
    /// Preserved human/source attribution.
    pub attribution: Option<String>,
    /// Confidence metadata in `[0, 1]`; it never erases contrary evidence.
    pub confidence: f32,
    /// Transaction-time assertion timestamp supplied by the caller.
    pub asserted_at_us: u64,
    /// First valid-time instant for the asserted fact.
    pub valid_from_us: u64,
    /// Optional last valid-time instant for the asserted fact.
    pub valid_to_us: Option<u64>,
    /// Projector implementation version that produced the row.
    pub projector_version: String,
    /// Initial status supplied by the projector.
    pub status: ClaimStatus,
    /// Specific prior claim corrected by this assertion.
    pub supersedes_claim_id: Option<MemoryClaimId>,
    /// Extant evidence references supporting this claim.
    pub evidence: Vec<EvidenceRef>,
}

impl MemoryClaim {
    /// Construct a claim and derive its identifier independently of projector
    /// version, so replay after a projector upgrade is idempotent.
    #[allow(clippy::too_many_arguments)]
    #[must_use]
    pub fn new(
        subject: &str,
        predicate: &str,
        object: &str,
        scope: &str,
        attribution: Option<String>,
        confidence: f32,
        asserted_at_us: u64,
        valid_from_us: u64,
        valid_to_us: Option<u64>,
        projector_version: &str,
        status: ClaimStatus,
        supersedes_claim_id: Option<MemoryClaimId>,
        mut evidence: Vec<EvidenceRef>,
    ) -> Self {
        evidence.sort_by(|a, b| a.id.cmp(&b.id));
        evidence.dedup_by(|a, b| a.id == b.id);
        let asserted = asserted_at_us.to_be_bytes();
        let valid_from = valid_from_us.to_be_bytes();
        let valid_to = valid_to_us.unwrap_or(u64::MAX).to_be_bytes();
        let supersedes = supersedes_claim_id.as_ref().map_or("", |id| id.0.as_str());
        let id = MemoryClaimId(stable_id(&[
            b"claim",
            subject.as_bytes(),
            predicate.as_bytes(),
            object.as_bytes(),
            scope.as_bytes(),
            attribution.as_deref().unwrap_or("").as_bytes(),
            &asserted,
            &valid_from,
            &valid_to,
            supersedes.as_bytes(),
        ]));
        Self {
            id,
            subject: subject.to_owned(),
            predicate: predicate.to_owned(),
            object: object.to_owned(),
            scope: scope.to_owned(),
            attribution,
            confidence,
            asserted_at_us,
            valid_from_us,
            valid_to_us,
            projector_version: projector_version.to_owned(),
            status,
            supersedes_claim_id,
            evidence,
        }
    }
}

/// Fully materialized, deterministic projection input.
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryDelta {
    /// Stable delta id, independent of projector version.
    pub id: String,
    /// Canonical event that owns this projection attempt.
    pub source_event_id: EventId,
    /// Explicit transaction-time timestamp.
    pub asserted_at_us: u64,
    /// Projector implementation version.
    pub projector_version: String,
    /// Immutable claims to append.
    pub claims: Vec<MemoryClaim>,
    /// Explicit claim transitions to append.
    pub transitions: Vec<ClaimTransition>,
}

impl MemoryDelta {
    /// Construct and deterministically order a projection delta.
    #[must_use]
    pub fn new(
        source_event_id: EventId,
        asserted_at_us: u64,
        projector_version: &str,
        mut claims: Vec<MemoryClaim>,
        mut transitions: Vec<ClaimTransition>,
    ) -> Self {
        claims.sort_by(|a, b| a.id.cmp(&b.id));
        transitions.sort_by(|a, b| a.id.cmp(&b.id));
        let source = source_event_id.0.to_be_bytes();
        let asserted = asserted_at_us.to_be_bytes();
        let claim_ids = claims
            .iter()
            .map(|c| c.id.0.as_str())
            .collect::<Vec<_>>()
            .join("\0");
        let transition_ids = transitions
            .iter()
            .map(|t| t.id.as_str())
            .collect::<Vec<_>>()
            .join("\0");
        let id = stable_id(&[
            b"delta",
            &source,
            &asserted,
            claim_ids.as_bytes(),
            transition_ids.as_bytes(),
        ]);
        Self {
            id,
            source_event_id,
            asserted_at_us,
            projector_version: projector_version.to_owned(),
            claims,
            transitions,
        }
    }
}

/// Explicit append-only status transition supplied to a delta.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaimTransition {
    /// Stable transition identifier.
    pub id: String,
    /// Claim whose effective status changes.
    pub claim_id: MemoryClaimId,
    /// New status.
    pub status: ClaimStatus,
    /// Transaction time when this transition became known.
    pub asserted_at_us: u64,
    /// Explicit effective timestamp.
    pub effective_at_us: u64,
    /// Human-readable reason retained in the audit trail.
    pub reason: String,
    /// Event anchoring the transition.
    pub source_event_id: EventId,
    /// Projector implementation version.
    pub projector_version: String,
}

impl ClaimTransition {
    pub(crate) fn new(
        claim_id: MemoryClaimId,
        status: ClaimStatus,
        asserted_at_us: u64,
        effective_at_us: u64,
        reason: &str,
        source_event_id: EventId,
        projector_version: &str,
    ) -> Self {
        let asserted = asserted_at_us.to_be_bytes();
        let effective = effective_at_us.to_be_bytes();
        let source = source_event_id.0.to_be_bytes();
        let id = stable_id(&[
            b"transition",
            claim_id.0.as_bytes(),
            status.as_str().as_bytes(),
            &asserted,
            &effective,
            reason.as_bytes(),
            &source,
        ]);
        Self {
            id,
            claim_id,
            status,
            asserted_at_us,
            effective_at_us,
            reason: reason.to_owned(),
            source_event_id,
            projector_version: projector_version.to_owned(),
        }
    }
}

/// One status entry returned from a claim's append-only audit history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaimStatusRecord {
    /// Effective status.
    pub status: ClaimStatus,
    /// Transaction time when this status became known.
    pub asserted_at_us: u64,
    /// Effective timestamp.
    pub effective_at_us: u64,
    /// Audit reason.
    pub reason: String,
    /// Source event that anchored this status.
    pub source_event_id: EventId,
}

/// Request to retract every claim evidenced by one canonical event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryRetraction {
    /// Event whose evidence is withdrawn.
    pub target_event_id: EventId,
    /// Event that records the retraction decision.
    pub retraction_event_id: EventId,
    /// Transaction time when the retraction became known.
    pub asserted_at_us: u64,
    /// Explicit effective timestamp.
    pub effective_at_us: u64,
    /// Audit reason.
    pub reason: String,
    /// Projector implementation version.
    pub projector_version: String,
}

/// Hard limits for deterministic graph expansion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExpansionBudget {
    /// Maximum claims, episodes, entities, and identities returned.
    pub max_nodes: usize,
    /// Maximum traversed claim/evidence and graph edges.
    pub max_edges: usize,
    /// Maximum evidence excerpts returned.
    pub max_evidence: usize,
    /// Maximum whitespace-token estimate across evidence excerpts.
    pub max_tokens: usize,
}

/// One bounded evidence excerpt returned by expansion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpandedEvidence {
    /// Immutable evidence identity and source attribution.
    pub evidence: EvidenceRef,
    /// Canonical event excerpt, bounded by the token budget.
    pub excerpt: String,
    /// Deterministic whitespace-token estimate charged to the budget.
    pub token_count: usize,
}

/// Deterministically ordered, budgeted expansion over memory and graph nodes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryExpansion {
    /// Seed claims admitted by the node budget.
    pub claim_ids: Vec<MemoryClaimId>,
    /// Evidence admitted by evidence, edge, and token budgets.
    pub evidence: Vec<ExpandedEvidence>,
    /// Episode nodes reached from evidence events.
    pub episode_ids: Vec<EpisodeId>,
    /// Entity nodes reached from evidence events.
    pub entity_ids: Vec<EntityId>,
    /// Canonical identities reached from entities.
    pub identity_ids: Vec<IdentityId>,
    /// Total node budget consumed.
    pub nodes_used: usize,
    /// Total edge budget consumed.
    pub edges_used: usize,
    /// Total token budget consumed.
    pub tokens_used: usize,
    /// True when at least one admissible candidate was skipped by a budget.
    pub truncated: bool,
}

impl MemoryRetraction {
    /// Construct an explicit event-retraction request.
    #[must_use]
    pub fn new(
        target_event_id: EventId,
        retraction_event_id: EventId,
        asserted_at_us: u64,
        effective_at_us: u64,
        reason: &str,
        projector_version: &str,
    ) -> Self {
        Self {
            target_event_id,
            retraction_event_id,
            asserted_at_us,
            effective_at_us,
            reason: reason.to_owned(),
            projector_version: projector_version.to_owned(),
        }
    }
}

pub(crate) fn stable_id(parts: &[&[u8]]) -> String {
    let mut hasher = Sha256::new();
    for (index, part) in parts.iter().enumerate() {
        if index > 0 {
            hasher.update([0]);
        }
        hasher.update(part);
    }
    let digest = hasher.finalize();
    let mut out = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}
