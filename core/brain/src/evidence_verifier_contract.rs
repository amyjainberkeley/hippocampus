//! Host-owned contract for claim-level evidence verification.
//!
//! A model may classify a structured claim and select bounded slot numbers.
//! It never supplies provenance. The host creates each slot from canonical
//! event bytes and binds selected slots back to immutable citations.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::ops::Range;

use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{EventId, EvidenceVerifierError};

/// Maximum number of canonical evidence spans available to one verifier call.
pub const MAX_VERIFIER_EVIDENCE_SLOTS: usize = 8;
/// Maximum UTF-8 byte length of one structured claim field.
pub const MAX_CLAIM_FIELD_BYTES: usize = 1_024;
/// Maximum UTF-8 byte length of one model-visible evidence span.
pub const MAX_EVIDENCE_SPAN_BYTES: usize = 4_096;
const MAX_ORIGIN_FIELD_BYTES: usize = 256;

/// One proposed subject-predicate-object relation in a local scope.
///
/// This type enforces one structured tuple and rejects control characters. A
/// future answer decomposer is still responsible for splitting semantically
/// compound prose before constructing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProposedClaim {
    subject: String,
    predicate: String,
    object: String,
    scope: String,
}

impl ProposedClaim {
    /// Construct one normalized structured claim.
    pub fn new(
        subject: &str,
        predicate: &str,
        object: &str,
        scope: &str,
    ) -> Result<Self, EvidenceContractError> {
        Ok(Self {
            subject: normalized_claim_field("subject", subject)?,
            predicate: normalized_claim_field("predicate", predicate)?,
            object: normalized_claim_field("object", object)?,
            scope: normalized_claim_field("scope", scope)?,
        })
    }

    /// Entity or topic the claim is about.
    #[must_use]
    pub fn subject(&self) -> &str {
        &self.subject
    }

    /// Relation asserted by the claim.
    #[must_use]
    pub fn predicate(&self) -> &str {
        &self.predicate
    }

    /// Value asserted by the claim.
    #[must_use]
    pub fn object(&self) -> &str {
        &self.object
    }

    /// Local/project visibility scope of the claim.
    #[must_use]
    pub fn scope(&self) -> &str {
        &self.scope
    }
}

fn normalized_claim_field(
    field: &'static str,
    value: &str,
) -> Result<String, EvidenceContractError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(EvidenceContractError::EmptyClaimField(field));
    }
    if value.len() > MAX_CLAIM_FIELD_BYTES {
        return Err(EvidenceContractError::ClaimFieldTooLarge {
            field,
            actual: value.len(),
            maximum: MAX_CLAIM_FIELD_BYTES,
        });
    }
    if value
        .chars()
        .any(|character| matches!(character, '\0' | '\n' | '\r'))
    {
        return Err(EvidenceContractError::InvalidClaimField(field));
    }
    Ok(value.to_owned())
}

/// Host-owned identity and authorization scope for canonical evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceOrigin {
    brain_id: String,
    scope: String,
    source_kind: String,
}

impl EvidenceOrigin {
    /// Construct bounded provenance metadata. These values come from the host,
    /// never from model output.
    pub fn new(
        brain_id: &str,
        scope: &str,
        source_kind: &str,
    ) -> Result<Self, EvidenceContractError> {
        Ok(Self {
            brain_id: normalized_origin_field("brain_id", brain_id)?,
            scope: normalized_origin_field("scope", scope)?,
            source_kind: normalized_origin_field("source_kind", source_kind)?,
        })
    }

    /// Stable local brain or device identity that owns the event.
    #[must_use]
    pub fn brain_id(&self) -> &str {
        &self.brain_id
    }

    /// Privacy or project scope authorized for the event.
    #[must_use]
    pub fn scope(&self) -> &str {
        &self.scope
    }

    /// Capture or connector source kind.
    #[must_use]
    pub fn source_kind(&self) -> &str {
        &self.source_kind
    }
}

fn normalized_origin_field(
    field: &'static str,
    value: &str,
) -> Result<String, EvidenceContractError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(EvidenceContractError::EmptyOriginField(field));
    }
    if value.len() > MAX_ORIGIN_FIELD_BYTES {
        return Err(EvidenceContractError::OriginFieldTooLarge {
            field,
            actual: value.len(),
            maximum: MAX_ORIGIN_FIELD_BYTES,
        });
    }
    if value
        .chars()
        .any(|character| matches!(character, '\0' | '\n' | '\r'))
    {
        return Err(EvidenceContractError::InvalidOriginField(field));
    }
    Ok(value.to_owned())
}

/// One UTF-8-safe excerpt derived by the host from a canonical event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceSpan<'a> {
    event_id: EventId,
    origin: EvidenceOrigin,
    event_content_sha256: String,
    provenance_sha256: String,
    byte_range: Range<usize>,
    exact_text: &'a str,
}

impl<'a> EvidenceSpan<'a> {
    /// Bind a nonempty byte range to the full canonical event digest.
    pub fn new(
        event_id: EventId,
        full_event_text: &'a str,
        byte_start: usize,
        byte_end: usize,
        origin: &EvidenceOrigin,
    ) -> Result<Self, EvidenceContractError> {
        if event_id.0 == 0 {
            return Err(EvidenceContractError::UnpersistedEventId);
        }
        if byte_start >= byte_end || byte_end > full_event_text.len() {
            return Err(EvidenceContractError::InvalidEvidenceRange);
        }
        if !full_event_text.is_char_boundary(byte_start)
            || !full_event_text.is_char_boundary(byte_end)
        {
            return Err(EvidenceContractError::NonCharacterBoundary);
        }
        let exact_text = &full_event_text[byte_start..byte_end];
        if exact_text.trim().is_empty() {
            return Err(EvidenceContractError::EmptyEvidenceSpan);
        }
        if exact_text.len() > MAX_EVIDENCE_SPAN_BYTES {
            return Err(EvidenceContractError::EvidenceSpanTooLarge {
                actual: exact_text.len(),
                maximum: MAX_EVIDENCE_SPAN_BYTES,
            });
        }
        Ok(Self {
            event_id,
            origin: origin.clone(),
            event_content_sha256: sha256_hex(full_event_text.as_bytes()),
            provenance_sha256: provenance_sha256(event_id, origin, full_event_text),
            byte_range: byte_start..byte_end,
            exact_text,
        })
    }

    /// Canonical event identity.
    #[must_use]
    pub const fn event_id(&self) -> EventId {
        self.event_id
    }

    /// Host-owned brain, scope, and source identity.
    #[must_use]
    pub const fn origin(&self) -> &EvidenceOrigin {
        &self.origin
    }

    /// SHA-256 of the complete canonical event text, not only the excerpt.
    #[must_use]
    pub fn event_content_sha256(&self) -> &str {
        &self.event_content_sha256
    }

    /// Digest binding event identity, origin metadata, and canonical bytes.
    #[must_use]
    pub fn provenance_sha256(&self) -> &str {
        &self.provenance_sha256
    }

    /// UTF-8-safe byte range inside the canonical event text.
    #[must_use]
    pub fn byte_range(&self) -> Range<usize> {
        self.byte_range.clone()
    }

    /// Exact source bytes represented by the range.
    #[must_use]
    pub const fn exact_text(&self) -> &str {
        self.exact_text
    }
}

/// Bounded ranked evidence presented to one claim verifier invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceSet<'a> {
    spans: Vec<EvidenceSpan<'a>>,
    brain_id: String,
    claim_scope: String,
}

impl<'a> EvidenceSet<'a> {
    /// Preserve host ranking order and assign implicit slots `0..len` while
    /// enforcing one brain and the proposed claim's exact authorization scope.
    pub fn new(
        claim: &ProposedClaim,
        authorized_brain_id: &str,
        spans: Vec<EvidenceSpan<'a>>,
    ) -> Result<Self, EvidenceContractError> {
        if spans.is_empty() {
            return Err(EvidenceContractError::EmptyEvidenceSet);
        }
        if spans.len() > MAX_VERIFIER_EVIDENCE_SLOTS {
            return Err(EvidenceContractError::TooManyEvidenceSpans {
                actual: spans.len(),
                maximum: MAX_VERIFIER_EVIDENCE_SLOTS,
            });
        }
        let mut identities = HashSet::with_capacity(spans.len());
        let brain_id = normalized_origin_field("authorized_brain_id", authorized_brain_id)?;
        let observed_brains = spans
            .iter()
            .map(|span| span.origin.brain_id.as_str())
            .collect::<HashSet<_>>();
        if observed_brains.len() > 1 {
            return Err(EvidenceContractError::MixedEvidenceBrains);
        }
        if spans[0].origin.brain_id != brain_id {
            return Err(EvidenceContractError::EvidenceBrainMismatch);
        }
        for span in &spans {
            if span.origin.scope != claim.scope {
                return Err(EvidenceContractError::EvidenceScopeMismatch);
            }
            let range = span.byte_range();
            if !identities.insert((span.event_id().0, range.start, range.end)) {
                return Err(EvidenceContractError::DuplicateEvidenceSpan);
            }
        }
        Ok(Self {
            spans,
            brain_id,
            claim_scope: claim.scope.clone(),
        })
    }

    /// Number of model-visible evidence slots.
    #[must_use]
    pub fn len(&self) -> usize {
        self.spans.len()
    }

    /// Whether the set contains no evidence. Valid constructed sets are never
    /// empty; this method exists for conventional collection inspection.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.spans.is_empty()
    }

    /// Iterate over host-ranked evidence slots without exposing mutation.
    #[must_use]
    pub fn iter(&self) -> impl ExactSizeIterator<Item = &EvidenceSpan<'a>> {
        self.spans.iter()
    }

    /// Confirm this evidence set is still being used for the authorized claim
    /// scope it was constructed against.
    #[must_use]
    pub fn validates_claim_scope(&self, claim: &ProposedClaim) -> bool {
        self.claim_scope == claim.scope
            && self.spans.iter().all(|span| {
                span.origin.scope == claim.scope && span.origin.brain_id == self.brain_id
            })
    }

    /// Bind a model judgment to host-owned immutable provenance.
    pub fn bind(
        &self,
        verdict: EvidenceSlotVerdict,
    ) -> Result<BoundEvidenceVerdict, EvidenceContractError> {
        let confidence = verdict.confidence();
        if !confidence.is_finite() || !(0.0..=1.0).contains(&confidence) {
            return Err(EvidenceContractError::InvalidConfidence);
        }
        match verdict {
            EvidenceSlotVerdict::Supported { citation_slots, .. } => {
                Ok(BoundEvidenceVerdict::Supported {
                    confidence,
                    citations: self.bind_slots(citation_slots)?,
                })
            }
            EvidenceSlotVerdict::Contradicted { citation_slots, .. } => {
                Ok(BoundEvidenceVerdict::Contradicted {
                    confidence,
                    citations: self.bind_slots(citation_slots)?,
                })
            }
            EvidenceSlotVerdict::Insufficient { .. } => {
                Ok(BoundEvidenceVerdict::Insufficient { confidence })
            }
            EvidenceSlotVerdict::Abstained {
                strongest_class_confidence,
            } => Ok(BoundEvidenceVerdict::Abstained {
                strongest_class_confidence,
            }),
        }
    }

    fn bind_slots(
        &self,
        mut slots: Vec<usize>,
    ) -> Result<Vec<VerifiedCitation>, EvidenceContractError> {
        if slots.is_empty() {
            return Err(EvidenceContractError::MissingCitationSlots);
        }
        slots.sort_unstable();
        for pair in slots.windows(2) {
            if pair[0] == pair[1] {
                return Err(EvidenceContractError::DuplicateCitationSlot(pair[0]));
            }
        }
        slots
            .into_iter()
            .map(|slot| {
                let span = self
                    .spans
                    .get(slot)
                    .ok_or(EvidenceContractError::UnknownCitationSlot(slot))?;
                Ok(VerifiedCitation::from(span))
            })
            .collect()
    }
}

/// Model output before the host binds selected slots to provenance.
#[derive(Debug, Clone, PartialEq)]
pub enum EvidenceSlotVerdict {
    /// The evidence set supports the proposed claim.
    Supported {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
        /// Host-assigned evidence slots required by the judgment.
        citation_slots: Vec<usize>,
    },
    /// The evidence set directly contradicts the proposed claim.
    Contradicted {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
        /// Host-assigned evidence slots required by the judgment.
        citation_slots: Vec<usize>,
    },
    /// The evidence set cannot safely decide the proposed claim.
    Insufficient {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
    },
    /// The model preferred support or contradiction, but host qualification
    /// thresholds did not authorize that judgment.
    Abstained {
        /// Probability of the strongest non-authorized model class.
        strongest_class_confidence: f32,
    },
}

impl EvidenceSlotVerdict {
    fn confidence(&self) -> f32 {
        match self {
            Self::Supported { confidence, .. }
            | Self::Contradicted { confidence, .. }
            | Self::Insufficient { confidence } => *confidence,
            Self::Abstained {
                strongest_class_confidence,
            } => *strongest_class_confidence,
        }
    }
}

/// Host-bound claim-verification result.
#[derive(Debug, Clone, PartialEq)]
pub enum BoundEvidenceVerdict {
    /// Supported with complete immutable citations.
    Supported {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
        /// Every canonical span required by the judgment.
        citations: Vec<VerifiedCitation>,
    },
    /// Contradicted with complete immutable citations.
    Contradicted {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
        /// Every canonical span required by the judgment.
        citations: Vec<VerifiedCitation>,
    },
    /// The evidence set cannot safely decide the claim.
    Insufficient {
        /// Calibrated confidence in `[0, 1]`.
        confidence: f32,
    },
    /// Host policy refused to authorize the model's strongest class.
    Abstained {
        /// Probability of the strongest non-authorized model class.
        strongest_class_confidence: f32,
    },
}

/// Immutable source citation created only from a host-owned evidence span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedCitation {
    event_id: EventId,
    origin: EvidenceOrigin,
    event_content_sha256: String,
    provenance_sha256: String,
    byte_range: Range<usize>,
    exact_text: String,
}

impl VerifiedCitation {
    /// Canonical event identity.
    #[must_use]
    pub const fn event_id(&self) -> EventId {
        self.event_id
    }

    /// Host-owned brain, scope, and source identity.
    #[must_use]
    pub const fn origin(&self) -> &EvidenceOrigin {
        &self.origin
    }

    /// SHA-256 of the complete canonical event text.
    #[must_use]
    pub fn event_content_sha256(&self) -> &str {
        &self.event_content_sha256
    }

    /// Digest binding event identity, origin metadata, and canonical bytes.
    #[must_use]
    pub fn provenance_sha256(&self) -> &str {
        &self.provenance_sha256
    }

    /// Exact UTF-8 byte range in the canonical event text.
    #[must_use]
    pub fn byte_range(&self) -> Range<usize> {
        self.byte_range.clone()
    }

    /// Exact cited source text.
    #[must_use]
    pub fn exact_text(&self) -> &str {
        &self.exact_text
    }

    /// Revalidate identity, full-event digest, range, and exact text.
    #[must_use]
    pub fn validate_against_event(
        &self,
        event_id: EventId,
        origin: &EvidenceOrigin,
        full_event_text: &str,
    ) -> bool {
        self.event_id == event_id
            && self.origin == *origin
            && self.event_content_sha256 == sha256_hex(full_event_text.as_bytes())
            && self.provenance_sha256 == provenance_sha256(event_id, origin, full_event_text)
            && full_event_text.get(self.byte_range.clone()) == Some(self.exact_text.as_str())
    }
}

impl From<&EvidenceSpan<'_>> for VerifiedCitation {
    fn from(span: &EvidenceSpan<'_>) -> Self {
        Self {
            event_id: span.event_id,
            origin: span.origin.clone(),
            event_content_sha256: span.event_content_sha256.clone(),
            provenance_sha256: span.provenance_sha256.clone(),
            byte_range: span.byte_range.clone(),
            exact_text: span.exact_text.to_owned(),
        }
    }
}

/// Local model boundary for claim-level verification.
pub trait ClaimEvidenceVerifier: Send + Sync + std::fmt::Debug {
    /// Classify one structured claim and select only host-assigned slots.
    fn verify_claim(
        &self,
        claim: &ProposedClaim,
        evidence: &EvidenceSet<'_>,
    ) -> Result<EvidenceSlotVerdict, EvidenceVerifierError>;
}

/// Fail-closed shape errors before or after model inference.
#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum EvidenceContractError {
    /// A required structured claim field was empty.
    #[error("empty proposed-claim field: {0}")]
    EmptyClaimField(&'static str),
    /// A structured claim field contained a line break or NUL.
    #[error("invalid proposed-claim field: {0}")]
    InvalidClaimField(&'static str),
    /// A structured claim field exceeded its pre-tokenization byte cap.
    #[error("proposed-claim field {field} is too large: {actual}; maximum is {maximum}")]
    ClaimFieldTooLarge {
        /// Field name.
        field: &'static str,
        /// Supplied UTF-8 byte length.
        actual: usize,
        /// Maximum UTF-8 byte length.
        maximum: usize,
    },
    /// Required host-owned origin metadata was empty.
    #[error("empty evidence-origin field: {0}")]
    EmptyOriginField(&'static str),
    /// Host-owned origin metadata contained a line break or NUL.
    #[error("invalid evidence-origin field: {0}")]
    InvalidOriginField(&'static str),
    /// Host-owned origin metadata exceeded its byte cap.
    #[error("evidence-origin field {field} is too large: {actual}; maximum is {maximum}")]
    OriginFieldTooLarge {
        /// Field name.
        field: &'static str,
        /// Supplied UTF-8 byte length.
        actual: usize,
        /// Maximum UTF-8 byte length.
        maximum: usize,
    },
    /// The requested source range was empty, inverted, or out of bounds.
    #[error("invalid evidence byte range")]
    InvalidEvidenceRange,
    /// The event has not received a stable persisted store identity.
    #[error("evidence event ID must be nonzero")]
    UnpersistedEventId,
    /// The requested range split a UTF-8 code point.
    #[error("evidence byte range is not on character boundaries")]
    NonCharacterBoundary,
    /// The requested source range contained only whitespace.
    #[error("evidence span is empty after trimming")]
    EmptyEvidenceSpan,
    /// A model-visible evidence span exceeded its pre-tokenization byte cap.
    #[error("evidence span is too large: {actual}; maximum is {maximum}")]
    EvidenceSpanTooLarge {
        /// Supplied UTF-8 byte length.
        actual: usize,
        /// Maximum UTF-8 byte length.
        maximum: usize,
    },
    /// A verifier call requires at least one evidence span.
    #[error("evidence set is empty")]
    EmptyEvidenceSet,
    /// The model input would exceed the fixed evidence-slot budget.
    #[error("too many evidence spans: {actual}; maximum is {maximum}")]
    TooManyEvidenceSpans {
        /// Supplied span count.
        actual: usize,
        /// Fixed maximum span count.
        maximum: usize,
    },
    /// The same canonical event range appeared more than once.
    #[error("duplicate evidence span")]
    DuplicateEvidenceSpan,
    /// Evidence came from a scope not authorized for the claim.
    #[error("evidence scope does not match proposed-claim scope")]
    EvidenceScopeMismatch,
    /// One verifier call mixed evidence from distinct local brains.
    #[error("evidence set mixes multiple brain identities")]
    MixedEvidenceBrains,
    /// Evidence did not come from the brain identity authorized by the caller.
    #[error("evidence brain does not match the caller-authorized brain")]
    EvidenceBrainMismatch,
    /// Model confidence was NaN, infinite, or outside `[0, 1]`.
    #[error("invalid evidence confidence")]
    InvalidConfidence,
    /// Support or contradiction omitted source attribution.
    #[error("support or contradiction requires at least one citation slot")]
    MissingCitationSlots,
    /// The model selected one slot more than once.
    #[error("duplicate citation slot: {0}")]
    DuplicateCitationSlot(usize),
    /// The model selected a slot outside the host-created evidence set.
    #[error("unknown citation slot: {0}")]
    UnknownCitationSlot(usize),
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        write!(&mut output, "{byte:02x}").expect("writing to a String cannot fail");
    }
    output
}

fn provenance_sha256(event_id: EventId, origin: &EvidenceOrigin, full_event_text: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"hippocampus:evidence:v1\0");
    digest.update(event_id.0.to_be_bytes());
    digest.update([0]);
    digest.update(origin.brain_id.as_bytes());
    digest.update([0]);
    digest.update(origin.scope.as_bytes());
    digest.update([0]);
    digest.update(origin.source_kind.as_bytes());
    digest.update([0]);
    digest.update(full_event_text.as_bytes());
    let bytes = digest.finalize();
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("writing to a String cannot fail");
    }
    output
}
