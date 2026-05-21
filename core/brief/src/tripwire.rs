//! Hallucination tripwire — citation validator.
//!
//! [`validate_citations`] checks that every citation in a brief resolves
//! to a real event in the brain AND that the cited event's text relates
//! to the brief body (naive substring-noun match for now; semantic
//! overlap lands with the LLM in the Phase 5 follow-on PR).
//!
//! The tripwire is **structural**: [`crate::lifecycle::advance`] carries
//! the violation list on the `Approve` action and rejects non-empty
//! results. Bypassing requires a code change visible in review.

use mci_brain::{BrainStore, EventId};

use crate::model::Brief;

/// One citation violation detected by [`validate_citations`].
#[derive(Debug, Clone)]
pub struct CitationViolation {
    /// What kind of violation.
    pub kind: ViolationKind,
    /// Human-readable detail for the review UI / logs.
    pub detail: String,
}

/// Classification of citation violations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ViolationKind {
    /// A cited `EventId` does not exist in the brain store.
    UnresolvedCitation,
    /// Brief has body text but zero citations — no backing evidence.
    OrphanClaim,
    /// Cited event exists but its text has no detectable relationship
    /// to the brief body. NAIVE impl: substring match on extracted
    /// nouns. Production path: semantic overlap via on-device LLM.
    ContentMismatch,
}

/// Validate all citations in a brief against the brain store.
///
/// Returns an empty `Vec` when all citations pass. The caller passes
/// this result to [`crate::lifecycle::LifecycleAction::Approve`];
/// [`crate::lifecycle::advance`] rejects non-empty violations.
pub fn validate_citations(brief: &Brief, store: &dyn BrainStore) -> Vec<CitationViolation> {
    let mut violations = Vec::new();

    if !brief.body.is_empty() && brief.citations.is_empty() {
        violations.push(CitationViolation {
            kind: ViolationKind::OrphanClaim,
            detail: "brief has body text but zero citations".into(),
        });
        return violations;
    }

    let body_lower = brief.body.to_lowercase();
    let body_words = extract_content_words(&body_lower);

    for &event_id in &brief.citations {
        match store.get_event(event_id) {
            Ok(Some(event)) => {
                if !has_content_overlap(&body_words, &event.text) {
                    violations.push(CitationViolation {
                        kind: ViolationKind::ContentMismatch,
                        detail: format!(
                            "cited {event_id} exists but text has no detectable overlap with brief body"
                        ),
                    });
                }
            }
            Ok(None) => {
                violations.push(CitationViolation {
                    kind: ViolationKind::UnresolvedCitation,
                    detail: format!("cited {event_id} does not exist in brain store"),
                });
            }
            Err(e) => {
                violations.push(CitationViolation {
                    kind: ViolationKind::UnresolvedCitation,
                    detail: format!("failed to fetch {event_id}: {e}"),
                });
            }
        }
    }

    violations
}

/// Extract "content words" from lowercased text — words ≥4 chars that
/// aren't common stopwords. NAIVE but sufficient for the structural
/// tripwire; semantic overlap replaces this in the LLM PR.
fn extract_content_words(text: &str) -> Vec<&str> {
    const STOPWORDS: &[&str] = &[
        "the", "and", "that", "this", "with", "from", "have", "been",
        "were", "will", "would", "could", "should", "about", "which",
        "their", "there", "what", "when", "where", "into", "also",
        "then", "than", "them", "each", "other", "some", "more",
        "very", "just", "like", "only",
    ];
    text.split_whitespace()
        .filter(|w| w.len() >= 4)
        .filter(|w| !STOPWORDS.contains(w))
        .collect()
}

/// Check whether any content word from the brief body appears in the
/// event text. NAIVE substring match — production replaces with
/// semantic overlap scoring.
fn has_content_overlap(body_words: &[&str], event_text: &str) -> bool {
    if body_words.is_empty() || event_text.is_empty() {
        return body_words.is_empty() && event_text.is_empty();
    }
    let event_lower = event_text.to_lowercase();
    body_words.iter().any(|word| event_lower.contains(word))
}

/// Convenience: check whether a specific `EventId` is resolvable.
pub fn citation_exists(event_id: EventId, store: &dyn BrainStore) -> bool {
    matches!(store.get_event(event_id), Ok(Some(_)))
}
