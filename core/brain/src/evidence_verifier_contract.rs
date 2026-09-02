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
    if value
        .chars()
        .any(|character| matches!(character, '\0' | '\n' | '\r'))
    {
        return Err(EvidenceContractError::InvalidClaimField(field));
    }
    Ok(value.to_owned())
}

/// One UTF-8-safe excerpt derived by the host from a canonical event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceSpan<'a> {
    event_id: EventId,
    event_content_sha256: String,
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
    ) -> Result<Self, EvidenceContractError> {
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
        Ok(Self {
            event_id,
            event_content_sha256: sha256_hex(full_event_text.as_bytes()),
            byte_range: byte_start..byte_end,
            exact_text,
        })
    }

    /// Canonical event identity.
    #[must_use]
    pub const fn event_id(&self) -> EventId {
        self.event_id
    }

    /// SHA-256 of the complete canonical event text, not only the excerpt.
    #[must_use]
    pub fn event_content_sha256(&self) -> &str {
        &self.event_content_sha256
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
}

impl<'a> EvidenceSet<'a> {
    /// Preserve host ranking order and assign implicit slots `0..len`.
    pub fn new(spans: Vec<EvidenceSpan<'a>>) -> Result<Self, EvidenceContractError> {
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
        for span in &spans {
            let range = span.byte_range();
            if !identities.insert((span.event_id().0, range.start, range.end)) {
                return Err(EvidenceContractError::DuplicateEvidenceSpan);
            }
        }
        Ok(Self { spans })
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
}

impl EvidenceSlotVerdict {
    fn confidence(&self) -> f32 {
        match self {
            Self::Supported { confidence, .. }
            | Self::Contradicted { confidence, .. }
            | Self::Insufficient { confidence } => *confidence,
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
}

/// Immutable source citation created only from a host-owned evidence span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedCitation {
    event_id: EventId,
    event_content_sha256: String,
    byte_range: Range<usize>,
    exact_text: String,
}

impl VerifiedCitation {
    /// Canonical event identity.
    #[must_use]
    pub const fn event_id(&self) -> EventId {
        self.event_id
    }

    /// SHA-256 of the complete canonical event text.
    #[must_use]
    pub fn event_content_sha256(&self) -> &str {
        &self.event_content_sha256
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
    pub fn validate_against_event(&self, event_id: EventId, full_event_text: &str) -> bool {
        self.event_id == event_id
            && self.event_content_sha256 == sha256_hex(full_event_text.as_bytes())
            && full_event_text.get(self.byte_range.clone()) == Some(self.exact_text.as_str())
    }
}

impl From<&EvidenceSpan<'_>> for VerifiedCitation {
    fn from(span: &EvidenceSpan<'_>) -> Self {
        Self {
            event_id: span.event_id,
            event_content_sha256: span.event_content_sha256.clone(),
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
    /// The requested source range was empty, inverted, or out of bounds.
    #[error("invalid evidence byte range")]
    InvalidEvidenceRange,
    /// The requested range split a UTF-8 code point.
    #[error("evidence byte range is not on character boundaries")]
    NonCharacterBoundary,
    /// The requested source range contained only whitespace.
    #[error("evidence span is empty after trimming")]
    EmptyEvidenceSpan,
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
