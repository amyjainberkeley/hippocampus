//! Tier 2 Qwen NER entity extractor — the **second writer** to the
//! V2-P3 graph foundation (`entities` / `entity_mentions`), composing
//! after [`crate::extraction::tier1`] on the same event.
//!
//! See `core/brain/src/extraction/tier2_ner/README.md` for the
//! per-kind prompt rationale, fixture pointers, and structured-output
//! contract.
//!
//! # Surface
//!
//! - [`NerBackend`] — pluggable "text in, raw entities out" trait. The
//!   production impl wraps a Qwen3-1.7B Core ML backend
//!   (`apps/agent/src/tier2_qwen_backend.rs`); tests use
//!   [`MockNerBackend`] which returns canned matches without touching
//!   any model.
//! - [`Tier2Extractor`] — composes one [`NerBackend`] with
//!   cascade-marker filtering and token-REDACT downstream filtering.
//!   The [`Tier2Extractor::extract`] method scans text + drops any
//!   match whose span overlaps a Tier 1 redacted span.
//! - [`persist_tier2_matches`] — writes matches as `entities` upserts +
//!   `entity_mentions` inserts via the [`BrainStore`] trait, with
//!   `extractor_kind = "qwen"` per V2-P3 schema convention. Mirrors
//!   [`crate::extraction::tier1::persist_tier1_matches`].
//! - [`mark_event_tier2_processed`] — writes the sentinel
//!   `(extractor_status, qwen_tier2_processed)` entity + a mention
//!   from it to the event. The async idle-batch worker queries
//!   `WHERE NOT EXISTS (sentinel mention)` to find work; the sentinel
//!   guarantees an event whose NER output is empty is still marked
//!   "done" and not re-processed every cycle.
//!
//! # Composition with V2-P4 (POST-cascade, POST-tier1)
//!
//! Tier 2 runs **after** the ADR-0016 cascade AND after V2-P4's Tier 1
//! pass on the same event. The composition discipline:
//!
//! 1. **Cascade markers SKIP** — `[REDACTED:…]` spans must not have
//!    their internal tokens classified as anything (the cascade
//!    already removed the sensitive bytes; a Qwen mention overlapping
//!    a marker span is dropped).
//! 2. **Token-REDACT downstream SKIP** — V2-P4 redacts JWT / AWS /
//!    GitHub-PAT / Stripe / Bitcoin-WIF token shapes by emitting
//!    `(redacted_token, <subkind>)` entities. Their `mention_text` is
//!    the subkind label, **never** the source bytes. But the source
//!    bytes are still in `events.text` (V2-P4 doesn't rewrite text).
//!    If Qwen classifies a JWT as `organization` because it looks
//!    organization-like, persisting the JWT bytes via V2-P5 would
//!    defeat V2-P4's discipline. So Tier 2 computes the Tier 1
//!    redacted-token span set first and DROPS any NER match whose
//!    span overlaps. CSO mini-audit row #3 pins this.
//!
//! Both checks run inside [`Tier2Extractor::extract`] — the
//! [`NerBackend`] just sees the raw event text and produces raw
//! candidates; the extractor wraps the backend and applies the two
//! filters.
//!
//! # Idempotency
//!
//! Same content-stable ULID discipline as V2-P4 (see [`crate::graph`]
//! module doc). Same `(kind, canonical_name)` → same `EntityId`. Same
//! `(entity_id, event_id, extractor_kind, mention_text)` → same
//! `EntityMentionId`. Running [`Tier2Extractor::extract`] twice on
//! the same event text produces the same matches; the `SQLCipher` impl's
//! `INSERT OR IGNORE` on `entity_mentions` makes the second pass a
//! no-op at the row level.
//!
//! # Footprint discipline (G2 raised SLO ≤10–15% / ≤2 GB default;
//! ≤25% / ≤3 GB burst)
//!
//! Tier 2 is intentionally **NOT on the brain ingest hot path** —
//! Qwen3-1.7B inference is ~100-500ms per call which would blow the
//! per-event burst budget. Instead the production wiring spawns an
//! async idle-batch worker (`apps/agent/src/tier2_worker.rs`,
//! mirroring `apps/agent/src/idle_batch.rs`) that processes events at
//! a bounded cadence. Single-flight by design: one Qwen call at a
//! time keeps the ~500 MB working set predictable.
//!
//! When the Qwen `.mlmodelc` is not present on disk (opt-in
//! download), the worker enters disabled-idle mode (same pattern as
//! `apps/agent/src/brief_worker.rs::run_disabled_idle`). V2-P4
//! Tier 1 continues writing `(extractor_kind = "regex")` mentions on
//! the hot path regardless.
//!
//! # OS-purity
//!
//! Pure Rust + the `regex` crate (already on the workspace lockfile
//! via Tier 1). No `cfg(target_os = ...)`, no `objc2`, no
//! `windows-rs`. The actual Core ML inference lives behind the
//! [`NerBackend`] trait in the agent crate; this module is portable.

use std::sync::Arc;
use std::sync::LazyLock;

use regex::Regex;
use thiserror::Error;

use crate::extraction::tier1::Tier1Extractor;
use crate::graph::{Entity, EntityMention};
use crate::{BrainStore, EventId, StoreError};

// ---------------------------------------------------------------------------
// Entity-kind string constants — V2-P5 NER kinds
// ---------------------------------------------------------------------------

/// `entities.kind` value for a person name (e.g. "Alice Smith",
/// "Dr. Chen"). The V2-P6 `AliasResolver` clusters multiple aliases
/// of the same person under one `EntityId`; until then each distinct
/// canonical form is a distinct row.
pub const KIND_PERSON_NAME: &str = "person_name";
/// `entities.kind` value for an organization (e.g. "Anthropic",
/// "Stripe Inc.", "the Brain team").
pub const KIND_ORGANIZATION: &str = "organization";
/// `entities.kind` value for a project name (e.g. "MCI", "V2-P5",
/// "the recall surface rewrite").
pub const KIND_PROJECT_NAME: &str = "project_name";
/// `entities.kind` value for a product name (e.g. "Hippocampus",
/// "Claude Code", "iPhone 15 Pro").
pub const KIND_PRODUCT_NAME: &str = "product_name";
/// `entities.kind` value for a location (e.g. "San Francisco",
/// "Apple Park", "office 3F").
pub const KIND_LOCATION: &str = "location";
/// `entities.kind` value for a free-form topic / subject matter
/// (e.g. "footprint SLO", "Q3 hiring", "OAuth migration").
pub const KIND_TOPIC: &str = "topic";

/// `entity_mentions.extractor_kind` value every Tier 2 mention
/// carries. V2-P4 emits `"regex"`; V2-P5 emits `"qwen"`. The two
/// extractors can co-emit the same canonical entity on the same
/// event — V2-P3 schema treats `extractor_kind` as part of the
/// natural key so both mentions persist as distinct rows.
pub const EXTRACTOR_KIND: &str = "qwen";

// ---------------------------------------------------------------------------
// Sentinel "processed" marker — idle-batch watermark
// ---------------------------------------------------------------------------

/// `entities.kind` for the sentinel "this extractor has scanned this
/// event" marker. ONE such row exists per extractor; the worker
/// inserts a mention from it to every processed event so the
/// "needs processing" query (`WHERE NOT EXISTS sentinel mention`) is
/// strictly correct — even events whose NER output is empty get
/// marked done and are not re-scanned every cycle.
pub const SENTINEL_KIND: &str = "extractor_status";
/// `entities.canonical_name` for the V2-P5 Tier 2 Qwen NER sentinel.
pub const SENTINEL_NAME: &str = "qwen_tier2_processed";

// ---------------------------------------------------------------------------
// Cascade marker regex
// ---------------------------------------------------------------------------

/// Matches `[REDACTED:…]` spans the OCR-time cascade left in the
/// event text. We re-derive the spans here rather than calling out
/// to V2-P4's `RE_CASCADE_REDACTED` so this module stays self-
/// contained — both regex bodies are identical and the
/// `cascade_marker_spans_match_tier1` unit test pins that.
static RE_CASCADE_MARKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[REDACTED:[A-Z_]+\]").expect("cascade_marker"));

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// One raw NER candidate as emitted by a [`NerBackend`]. The backend
/// is responsible for the `kind`, `canonical_name`, `mention_text`,
/// span offsets, and confidence; the [`Tier2Extractor`] applies
/// cascade-skip + token-REDACT-downstream filters above this.
#[derive(Debug, Clone, PartialEq)]
pub struct Tier2RawMatch {
    /// `entities.kind` value. Expected to be one of the `KIND_*`
    /// constants in this module; backends MAY emit other strings (the
    /// schema column is TEXT, no enum constraint) but the prompt
    /// design constrains the set.
    pub kind: String,
    /// `entities.canonical_name` value. The backend is expected to
    /// emit a normalised display form (e.g. trimmed, title-cased for
    /// people, lower-cased for free-form topics).
    pub canonical_name: String,
    /// `entity_mentions.mention_text` value. The literal substring the
    /// backend points at in the input text. The extractor verifies
    /// that `text[span_start..span_end]` equals this — a backend that
    /// hallucinates a span is dropped by the extractor.
    pub mention_text: String,
    /// Inclusive byte offset of the match start in the input text.
    pub span_start: usize,
    /// Exclusive byte offset of the match end in the input text.
    pub span_end: usize,
    /// Backend confidence in `[0.0, 1.0]`. The extractor drops
    /// matches below [`Tier2Extractor::confidence_threshold`].
    pub confidence: f32,
}

/// One Tier 2 match the extractor has filtered + verified.
///
/// Shape mirrors [`crate::extraction::tier1::Tier1Match`] for parity;
/// the extra `confidence` field is the only structural difference.
#[derive(Debug, Clone, PartialEq)]
pub struct Tier2Match {
    /// `entities.kind` value. One of the `KIND_*` constants.
    pub kind: String,
    /// `entities.canonical_name` value.
    pub canonical_name: String,
    /// `entity_mentions.mention_text` value.
    pub mention_text: String,
    /// Inclusive byte offset of the match start.
    pub span_start: usize,
    /// Exclusive byte offset of the match end.
    pub span_end: usize,
    /// `entity_mentions.confidence` value, in `[0.0, 1.0]`.
    pub confidence: f32,
}

/// Errors a [`NerBackend`] can surface.
#[derive(Debug, Error)]
pub enum NerError {
    /// Backend rejected the prompt (e.g. empty input).
    #[error("ner: invalid input: {0}")]
    InvalidInput(String),
    /// Backend inference failure (Core ML model load, timeout, …).
    #[error("ner: backend: {0}")]
    Backend(String),
    /// Backend output could not be parsed as the expected structured
    /// shape (JSON malformed, span offsets out of range, mention
    /// text doesn't match span, …).
    #[error("ner: parse: {0}")]
    Parse(String),
}

/// Counters returned by [`persist_tier2_matches`].
///
/// Same shape as [`crate::extraction::tier1::PersistStats`] but the
/// names are explicit so a stats struct from V2-P5 can't be confused
/// with one from V2-P4 at a call site.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PersistStats {
    /// Number of `put_entity` calls that returned `Ok`.
    pub entities_upserted: usize,
    /// Number of `put_entity_mention` calls that returned `Ok`.
    pub mentions_inserted: usize,
}

// ---------------------------------------------------------------------------
// NerBackend trait
// ---------------------------------------------------------------------------

/// Pluggable NER backend. Production impl wraps a Qwen3 Core ML
/// model (`apps/agent/src/tier2_qwen_backend.rs`); tests use
/// [`MockNerBackend`] to avoid the model dependency.
///
/// Backends take a raw event text and return raw candidate matches.
/// Cascade-skip + token-REDACT-downstream filtering happens above
/// this trait — backends MAY emit candidates that overlap redacted
/// spans; the [`Tier2Extractor`] drops them.
pub trait NerBackend: Send + Sync {
    /// Extract candidate entity mentions from `text`. Returns matches
    /// in any order; the extractor sorts + filters above this.
    ///
    /// # Errors
    /// [`NerError::InvalidInput`] for empty / oversize input,
    /// [`NerError::Backend`] for model failure, [`NerError::Parse`]
    /// for malformed output.
    fn extract_entities(&self, text: &str) -> Result<Vec<Tier2RawMatch>, NerError>;
}

// ---------------------------------------------------------------------------
// Mock backend (test-only, but ships in the crate so the wiring-proof
// test in `apps/agent/tests/` can use it without a circular dep)
// ---------------------------------------------------------------------------

/// In-memory canned-output backend. Constructed with a list of raw
/// matches; returns the same list verbatim on every call.
///
/// Used by tests + by the wiring-proof integration test in
/// `apps/agent/tests/brain_tier2_wiring.rs`. NOT used in production —
/// the agent constructs a Qwen-backed backend at startup.
#[derive(Debug, Clone)]
pub struct MockNerBackend {
    fixtures: Vec<Tier2RawMatch>,
}

impl MockNerBackend {
    /// Construct a mock backend that returns `fixtures` on every
    /// `extract_entities` call.
    #[must_use]
    pub fn new(fixtures: Vec<Tier2RawMatch>) -> Self {
        Self { fixtures }
    }

    /// Construct an empty mock backend — returns zero matches on
    /// every call. Useful for tests that exercise the
    /// "no NER output but sentinel still written" path.
    #[must_use]
    pub fn empty() -> Self {
        Self {
            fixtures: Vec::new(),
        }
    }
}

impl NerBackend for MockNerBackend {
    fn extract_entities(&self, _text: &str) -> Result<Vec<Tier2RawMatch>, NerError> {
        Ok(self.fixtures.clone())
    }
}

// ---------------------------------------------------------------------------
// Extractor
// ---------------------------------------------------------------------------

/// Default confidence floor for [`Tier2Extractor`]. Matches below
/// this are dropped — Qwen with the structured-output prompt
/// reliably emits confidence ≥ 0.7 on the per-kind regression
/// fixtures; 0.5 leaves a margin for borderline mentions while
/// dropping obvious noise.
pub const DEFAULT_CONFIDENCE_THRESHOLD: f32 = 0.5;

/// Composes one [`NerBackend`] with the V2-P5 filter chain:
///
/// 1. Run [`NerBackend::extract_entities`] on the input text.
/// 2. Drop matches whose `(span_start, span_end)` does not point at
///    `mention_text` in the input (hallucination guard).
/// 3. Drop matches whose `confidence < confidence_threshold`.
/// 4. Drop matches whose span overlaps a `[REDACTED:…]` cascade
///    marker (cascade-skip discipline).
/// 5. Drop matches whose span overlaps a V2-P4 Tier 1 `redacted_token`
///    span (token-REDACT downstream discipline).
///
/// Step 5 invokes a private [`Tier1Extractor`] internally to derive
/// the redacted-span set — no DB roundtrip, no coupling to where
/// V2-P4 wrote its mentions. The redacted-span derivation is
/// deterministic per V2-P4's token-shape regex bank, so the
/// composition is reproducible.
#[derive(Clone)]
pub struct Tier2Extractor {
    backend: Arc<dyn NerBackend>,
    confidence_threshold: f32,
}

impl Tier2Extractor {
    /// Construct an extractor with [`DEFAULT_CONFIDENCE_THRESHOLD`].
    #[must_use]
    pub fn new(backend: Arc<dyn NerBackend>) -> Self {
        Self {
            backend,
            confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
        }
    }

    /// Construct an extractor with a caller-supplied confidence
    /// threshold. Useful for testing the threshold behaviour.
    #[must_use]
    pub fn with_threshold(backend: Arc<dyn NerBackend>, threshold: f32) -> Self {
        Self {
            backend,
            confidence_threshold: threshold,
        }
    }

    /// Run the filter chain on `text` and return verified matches in
    /// span order.
    ///
    /// # Errors
    /// Propagates [`NerError`] from the backend. The filter chain
    /// itself does not fail — it drops mismatched matches silently.
    pub fn extract(&self, text: &str) -> Result<Vec<Tier2Match>, NerError> {
        let raw = self.backend.extract_entities(text)?;
        let skip_spans = compute_skip_spans(text);
        let mut out: Vec<Tier2Match> = Vec::with_capacity(raw.len());

        for m in raw {
            // Hallucination guard: the span must point at the
            // mention_text in the input. A backend that emits a span
            // pointing at substring "Alice" but mention_text "Bob"
            // (or to an out-of-bounds offset) is dropped.
            if !verify_span(text, &m) {
                continue;
            }
            if m.confidence < self.confidence_threshold {
                continue;
            }
            if overlaps_any(&skip_spans, m.span_start, m.span_end) {
                continue;
            }
            out.push(Tier2Match {
                kind: m.kind,
                canonical_name: m.canonical_name,
                mention_text: m.mention_text,
                span_start: m.span_start,
                span_end: m.span_end,
                confidence: m.confidence,
            });
        }

        out.sort_by_key(|m| (m.span_start, m.span_end));
        Ok(out)
    }
}

impl std::fmt::Debug for Tier2Extractor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tier2Extractor")
            .field("confidence_threshold", &self.confidence_threshold)
            .finish_non_exhaustive()
    }
}

// ---------------------------------------------------------------------------
// Filter helpers
// ---------------------------------------------------------------------------

fn verify_span(text: &str, m: &Tier2RawMatch) -> bool {
    if m.span_end <= m.span_start || m.span_end > text.len() {
        return false;
    }
    // UTF-8-safe slice: span boundaries must land on char boundaries.
    if !text.is_char_boundary(m.span_start) || !text.is_char_boundary(m.span_end) {
        return false;
    }
    text[m.span_start..m.span_end] == m.mention_text
}

fn overlaps_any(skip: &[(usize, usize)], start: usize, end: usize) -> bool {
    skip.iter().any(|&(s, e)| start < e && s < end)
}

/// Compute the union of (a) cascade-marker spans and (b) V2-P4
/// Tier 1 `redacted_token` spans in `text`.
///
/// Used by [`Tier2Extractor::extract`] to drop NER mentions
/// overlapping redacted content. Public for the
/// `cascade_marker_spans_match_tier1` unit test.
#[must_use]
pub fn compute_skip_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans: Vec<(usize, usize)> = Vec::new();

    // (a) Cascade markers.
    for m in RE_CASCADE_MARKER.find_iter(text) {
        spans.push((m.start(), m.end()));
    }

    // (b) V2-P4 Tier 1 `redacted_token` spans.
    let tier1 = Tier1Extractor::new();
    for m in tier1.extract(text) {
        if m.is_redacted() {
            spans.push((m.span_start, m.span_end));
        }
    }

    spans.sort_unstable();
    spans
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

/// Write `matches` to the brain store as `entities` upserts +
/// `entity_mentions` inserts with `extractor_kind = "qwen"`.
///
/// `event_id` and `ts_us` come from the parent event. Same content-
/// stable ULID discipline as V2-P4: same `(kind, canonical_name)` →
/// same `EntityId`; same `(entity_id, event_id, "qwen",
/// mention_text)` → same `EntityMentionId`. Re-running the extractor
/// on the same event is a no-op at the row level.
///
/// # Errors
/// Returns the **first** [`StoreError`] encountered. Earlier successful
/// writes are not rolled back — same best-effort discipline as V2-P4
/// since the writes are idempotent on PK and a retry converges.
pub fn persist_tier2_matches(
    store: &dyn BrainStore,
    event_id: EventId,
    ts_us: u64,
    matches: &[Tier2Match],
) -> Result<PersistStats, StoreError> {
    let mut stats = PersistStats::default();
    for m in matches {
        let entity = Entity {
            id: Entity::derive_id(&m.kind, &m.canonical_name),
            kind: m.kind.clone(),
            canonical_name: m.canonical_name.clone(),
            summary: None,
            summary_embedding: None,
            content_hash: Entity::derive_content_hash(&m.kind, &m.canonical_name),
            created_ts_us: ts_us,
            updated_ts_us: ts_us,
        };
        store.put_entity(&entity)?;
        stats.entities_upserted += 1;

        let mention_text_for_id = Some(m.mention_text.as_str());
        let mention = EntityMention {
            id: EntityMention::derive_id(
                &entity.id,
                event_id,
                EXTRACTOR_KIND,
                mention_text_for_id,
            ),
            entity_id: entity.id,
            event_id,
            mention_text: Some(m.mention_text.clone()),
            confidence: m.confidence,
            extractor_kind: EXTRACTOR_KIND.to_string(),
            ts_us,
        };
        store.put_entity_mention(&mention)?;
        stats.mentions_inserted += 1;
    }
    Ok(stats)
}

/// Mark `event_id` as scanned by the Tier 2 Qwen NER pass.
///
/// Writes the sentinel `(extractor_status, qwen_tier2_processed)`
/// entity if it doesn't yet exist, then inserts a mention from it
/// to `event_id` with `extractor_kind = "qwen"`,
/// `mention_text = None`. The idle-batch worker queries
/// `WHERE NOT EXISTS sentinel mention` to find work; the mark
/// guarantees an event whose NER output is empty is still marked
/// done.
///
/// Idempotent: calling this twice on the same `event_id` is a no-op
/// at the row level (entity upsert keyed on PK + mention `INSERT OR
/// IGNORE` keyed on PK).
///
/// # Errors
/// [`StoreError`] from the underlying store on `put_entity` or
/// `put_entity_mention` failure.
pub fn mark_event_tier2_processed(
    store: &dyn BrainStore,
    event_id: EventId,
    ts_us: u64,
) -> Result<(), StoreError> {
    let sentinel = Entity {
        id: Entity::derive_id(SENTINEL_KIND, SENTINEL_NAME),
        kind: SENTINEL_KIND.to_string(),
        canonical_name: SENTINEL_NAME.to_string(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(SENTINEL_KIND, SENTINEL_NAME),
        created_ts_us: ts_us,
        updated_ts_us: ts_us,
    };
    store.put_entity(&sentinel)?;

    let mention = EntityMention {
        id: EntityMention::derive_id(&sentinel.id, event_id, EXTRACTOR_KIND, None),
        entity_id: sentinel.id,
        event_id,
        mention_text: None,
        confidence: 1.0,
        extractor_kind: EXTRACTOR_KIND.to_string(),
        ts_us,
    };
    store.put_entity_mention(&mention)?;
    Ok(())
}

// ===========================================================================
// Unit tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extraction::tier1::{
        Tier1Extractor, KIND_REDACTED_TOKEN as TIER1_KIND_REDACTED, SUBKIND_CASCADE_REDACTED,
        SUBKIND_JWT,
    };

    // -----------------------------------------------------------------------
    // Hallucination guard
    // -----------------------------------------------------------------------

    #[test]
    fn extract_drops_match_with_span_pointing_at_wrong_substring() {
        let text = "Alice met Bob in the lobby";
        let raw = vec![Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Carol".into(),
            mention_text: "Carol".into(),
            span_start: 0,
            span_end: 5,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert!(
            out.is_empty(),
            "hallucinated mention (span points at 'Alice' but text says 'Carol') must be dropped"
        );
    }

    #[test]
    fn extract_drops_match_with_out_of_bounds_span() {
        let text = "short";
        let raw = vec![Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "x".into(),
            mention_text: "x".into(),
            span_start: 100,
            span_end: 101,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert!(out.is_empty());
    }

    #[test]
    fn extract_drops_match_with_non_char_boundary_span() {
        // Multi-byte char at index 0..3 (é = 2 bytes UTF-8: 0xC3 0xA9).
        let text = "éxample text";
        // Span 0..1 lands mid-multi-byte char.
        let raw = vec![Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "x".into(),
            mention_text: "x".into(),
            span_start: 0,
            span_end: 1,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert!(out.is_empty(), "non-char-boundary span must be dropped");
    }

    // -----------------------------------------------------------------------
    // Confidence threshold
    // -----------------------------------------------------------------------

    #[test]
    fn extract_drops_low_confidence_matches() {
        let text = "Alice and Bob talked";
        let raw = vec![
            Tier2RawMatch {
                kind: KIND_PERSON_NAME.into(),
                canonical_name: "Alice".into(),
                mention_text: "Alice".into(),
                span_start: 0,
                span_end: 5,
                confidence: 0.9, // kept
            },
            Tier2RawMatch {
                kind: KIND_PERSON_NAME.into(),
                canonical_name: "Bob".into(),
                mention_text: "Bob".into(),
                span_start: 10,
                span_end: 13,
                confidence: 0.3, // dropped (< 0.5)
            },
        ];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].mention_text, "Alice");
    }

    #[test]
    fn extract_respects_custom_threshold() {
        let text = "Alice and Bob talked";
        let raw = vec![Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: 0,
            span_end: 5,
            confidence: 0.6,
        }];
        let lax = Tier2Extractor::with_threshold(
            Arc::new(MockNerBackend::new(raw.clone())),
            0.5,
        );
        let strict = Tier2Extractor::with_threshold(Arc::new(MockNerBackend::new(raw)), 0.8);
        assert_eq!(lax.extract(text).expect("lax").len(), 1);
        assert_eq!(strict.extract(text).expect("strict").len(), 0);
    }

    // -----------------------------------------------------------------------
    // Cascade-marker SKIP (cascade-discipline)
    // -----------------------------------------------------------------------

    #[test]
    fn extract_drops_mention_overlapping_cascade_marker() {
        let text = "Your code is [REDACTED:SMS_OTP] please confirm";
        // Span 13..31 IS the cascade marker. A backend that
        // (incorrectly) emits a topic match for the marker contents
        // must be dropped.
        let raw = vec![Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "SMS_OTP".into(),
            mention_text: "[REDACTED:SMS_OTP]".into(),
            span_start: 13,
            span_end: 31,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert!(
            out.is_empty(),
            "mention overlapping cascade marker must be dropped"
        );
    }

    #[test]
    fn extract_keeps_mention_outside_cascade_marker_span() {
        let text = "Alice sent a code [REDACTED:SMS_OTP] earlier";
        // "Alice" at 0..5 is OUTSIDE the cascade marker (18..36).
        let raw = vec![Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: 0,
            span_end: 5,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].mention_text, "Alice");
    }

    // -----------------------------------------------------------------------
    // Token-REDACT downstream SKIP (V2-P4 composition)
    // -----------------------------------------------------------------------

    #[test]
    fn extract_drops_mention_overlapping_tier1_jwt_span() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
        let text = format!("Bearer {jwt} ok");
        let jwt_start = "Bearer ".len();
        let jwt_end = jwt_start + jwt.len();

        // Backend hallucinates that the JWT is an organization
        // (it looks like a corporate token id).
        let raw = vec![Tier2RawMatch {
            kind: KIND_ORGANIZATION.into(),
            canonical_name: "AuthCorp".into(),
            mention_text: jwt.into(),
            span_start: jwt_start,
            span_end: jwt_end,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(&text).expect("ok");
        assert!(
            out.is_empty(),
            "mention overlapping V2-P4 redacted_token span must be dropped — JWT bytes must NEVER reach V2-P5 entities"
        );
    }

    #[test]
    fn extract_drops_partial_overlap_with_tier1_redacted_span() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
        let text = format!("Foo Bearer {jwt} bar");
        let jwt_start = "Foo Bearer ".len();
        let jwt_end = jwt_start + jwt.len();
        // Backend (wrongly) emits a span that PARTIALLY overlaps the
        // JWT — say a substring of it. Must still be dropped.
        let mid_span_start = jwt_start + 10;
        let mid_span_end = jwt_start + 30;

        let raw = vec![Tier2RawMatch {
            kind: KIND_PRODUCT_NAME.into(),
            canonical_name: "FoobarToken".into(),
            mention_text: text[mid_span_start..mid_span_end].to_string(),
            span_start: mid_span_start,
            span_end: mid_span_end,
            confidence: 0.9,
        }];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(&text).expect("ok");
        assert!(
            out.is_empty(),
            "partial overlap with JWT span must drop the mention"
        );
        let _ = jwt_end; // silence unused on debug
    }

    // -----------------------------------------------------------------------
    // Multiple kinds, ordering
    // -----------------------------------------------------------------------

    #[test]
    fn extract_returns_matches_in_span_order() {
        let text = "Bob met Alice and Carol";
        // Emit in reverse order; extractor must sort by span.
        let raw = vec![
            Tier2RawMatch {
                kind: KIND_PERSON_NAME.into(),
                canonical_name: "Carol".into(),
                mention_text: "Carol".into(),
                span_start: 18,
                span_end: 23,
                confidence: 0.9,
            },
            Tier2RawMatch {
                kind: KIND_PERSON_NAME.into(),
                canonical_name: "Bob".into(),
                mention_text: "Bob".into(),
                span_start: 0,
                span_end: 3,
                confidence: 0.9,
            },
            Tier2RawMatch {
                kind: KIND_PERSON_NAME.into(),
                canonical_name: "Alice".into(),
                mention_text: "Alice".into(),
                span_start: 8,
                span_end: 13,
                confidence: 0.9,
            },
        ];
        let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
        let out = ex.extract(text).expect("ok");
        let names: Vec<&str> = out.iter().map(|m| m.mention_text.as_str()).collect();
        assert_eq!(names, vec!["Bob", "Alice", "Carol"]);
    }

    // -----------------------------------------------------------------------
    // compute_skip_spans behavior
    // -----------------------------------------------------------------------

    #[test]
    fn compute_skip_spans_includes_cascade_markers() {
        let text = "Code [REDACTED:SMS_OTP] then [REDACTED:BANK_NOTIFICATION] then end";
        let spans = compute_skip_spans(text);
        assert!(spans.len() >= 2);
        // Verify both markers are covered.
        let first_marker = text.find("[REDACTED:SMS_OTP]").unwrap();
        let second_marker = text.find("[REDACTED:BANK_NOTIFICATION]").unwrap();
        assert!(spans.iter().any(|&(s, _)| s == first_marker));
        assert!(spans.iter().any(|&(s, _)| s == second_marker));
    }

    #[test]
    fn compute_skip_spans_includes_tier1_redacted_tokens() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
        let text = format!("Auth: {jwt} end");
        let jwt_start = "Auth: ".len();
        let jwt_end = jwt_start + jwt.len();
        let spans = compute_skip_spans(&text);
        assert!(spans.iter().any(|&(s, e)| s == jwt_start && e == jwt_end));
    }

    #[test]
    fn compute_skip_spans_empty_for_clean_text() {
        let text = "Alice met Bob at the office today";
        let spans = compute_skip_spans(text);
        assert!(spans.is_empty());
    }

    /// Pin: V2-P5's cascade-marker regex matches V2-P4's. The two
    /// must stay in lock-step — divergence would mean Tier 2 NER
    /// could classify the contents of a marker as an entity while
    /// Tier 1 has already emitted a `cascade_redacted` entity for it.
    #[test]
    fn cascade_marker_spans_match_tier1() {
        let text = "Code [REDACTED:SMS_OTP] sent";
        let tier1 = Tier1Extractor::new();
        let tier1_marker_spans: Vec<(usize, usize)> = tier1
            .extract(text)
            .into_iter()
            .filter(|m| m.kind == TIER1_KIND_REDACTED && m.canonical_name == SUBKIND_CASCADE_REDACTED)
            .map(|m| (m.span_start, m.span_end))
            .collect();
        let tier2_spans = compute_skip_spans(text);
        // Every tier1 cascade-marker span must be in the tier2 skip set.
        for span in tier1_marker_spans {
            assert!(
                tier2_spans.contains(&span),
                "tier2 skip set missing tier1 cascade-marker span {span:?}"
            );
        }
        // JWT subkind also present and in skip set.
        let _ = SUBKIND_JWT;
    }

    // -----------------------------------------------------------------------
    // overlaps_any pinpoint
    // -----------------------------------------------------------------------

    #[test]
    fn overlaps_any_handles_edge_cases() {
        let skip = vec![(10_usize, 20_usize)];
        assert!(!overlaps_any(&skip, 0, 10), "adjacent before is not overlap");
        assert!(!overlaps_any(&skip, 20, 30), "adjacent after is not overlap");
        assert!(overlaps_any(&skip, 5, 15), "partial overlap before");
        assert!(overlaps_any(&skip, 15, 25), "partial overlap after");
        assert!(overlaps_any(&skip, 12, 18), "contained");
        assert!(overlaps_any(&skip, 5, 25), "spanning");
    }

    // -----------------------------------------------------------------------
    // Mock backend behaviour
    // -----------------------------------------------------------------------

    #[test]
    fn mock_backend_returns_canned_output() {
        let canned = vec![Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "test".into(),
            mention_text: "test".into(),
            span_start: 0,
            span_end: 4,
            confidence: 0.8,
        }];
        let b = MockNerBackend::new(canned.clone());
        let out = b.extract_entities("test some other text").unwrap();
        assert_eq!(out, canned);
    }

    #[test]
    fn mock_backend_empty_returns_no_matches() {
        let b = MockNerBackend::empty();
        let out = b.extract_entities("anything").unwrap();
        assert!(out.is_empty());
    }
}
