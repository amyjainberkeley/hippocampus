//! `BriefAuthor` trait — pluggable brief generator.
//!
//! Production uses `LlamaBriefAuthor` (Llama-3.2-1B int4 via Core ML),
//! deferred to a follow-on PR with ADR-0008 dep-gate review.
//! [`StubBriefAuthor`] here produces trivial briefs for tests + dev.

use mci_brain::EventRecord;
use thiserror::Error;

use crate::model::{Brief, BriefId, BriefState};

/// Errors from [`BriefAuthor::author`].
#[derive(Debug, Error)]
pub enum AuthorError {
    /// No events to generate a brief from.
    #[error("author: no events provided")]
    NoEvents,
    /// The generation backend failed.
    #[error("author: backend: {0}")]
    Backend(String),
}

/// Pluggable brief generator. Takes retrieved events + a topic string,
/// produces a [`Brief`] in `Draft` state.
///
/// Real `LlamaBriefAuthor` is DEFERRED — this trait + [`StubBriefAuthor`]
/// is the scaffold surface.
pub trait BriefAuthor: Send + Sync {
    /// Generate a brief from the given events and topic.
    ///
    /// The returned brief MUST be in [`BriefState::Draft`] with citations
    /// drawn from the input `EventRecord::event_id` values.
    fn author(&self, retrieval: &[EventRecord], topic: &str) -> Result<Brief, AuthorError>;
}

/// Stub brief author for tests + dev. Produces a trivial brief:
/// title = topic, body = newline-joined text snippets, citations =
/// all input event IDs.
#[derive(Debug, Default, Clone, Copy)]
pub struct StubBriefAuthor;

impl BriefAuthor for StubBriefAuthor {
    fn author(&self, retrieval: &[EventRecord], topic: &str) -> Result<Brief, AuthorError> {
        if retrieval.is_empty() {
            return Err(AuthorError::NoEvents);
        }

        let body = retrieval
            .iter()
            .map(|r| format!("- {}", r.text_snippet))
            .collect::<Vec<_>>()
            .join("\n");

        let citations = retrieval.iter().map(|r| r.event_id).collect();

        let now_us = retrieval
            .iter()
            .map(|r| r.ts_us)
            .max()
            .unwrap_or(0);

        Ok(Brief {
            id: BriefId(0),
            title: topic.to_owned(),
            body,
            citations,
            state: BriefState::Draft,
            created_ts_us: now_us,
            updated_ts_us: now_us,
            human_approver_id: None,
        })
    }
}
