//! ADR-0030 cascade-equivalent for the Phase 6 PR 5 attribution
//! enrichers (`current_calendar_event`, `current_listening_track`,
//! `current_contact`).
//!
//! # Why this module exists
//!
//! Phase 6 PR 5 added three zero-entitlement-cost attribution fields
//! on `core::capture::WorkflowContext` (SH Fork D1, ratified at
//! `AGENT_QUESTIONS.md` F-RATIFICATION-2026-05-31):
//!
//! | Field | Source | May carry user content? |
//! |---|---|---|
//! | `current_calendar_event.subject` | EventKit `EKEvent.title` | YES |
//! | `current_listening_track.title`  | `MPNowPlayingInfoCenter`  | YES |
//! | `current_listening_track.artist` | `MPNowPlayingInfoCenter`  | YES |
//! | `current_contact.identifier`     | `CNContact.identifier`    | NO (opaque) |
//!
//! Calendar invites can carry `"Your verification code is 123456"` in
//! the subject line; podcast episode titles can contain phone numbers;
//! both shapes are rare but possible. ADR-0013 §3 fail-safe-default-
//! redact says any user-content surface running into brain persistence
//! MUST run through the cascade-equivalent regex bank first. This
//! module is that hook.
//!
//! The `current_contact.identifier` field is opaque (no name / phone /
//! email survives on the snapshot), so its cascade-equivalent is a
//! documented no-op per CSO sign-off row 7. The function signature
//! still takes a `&mut ContactRef` so the call site is uniform and
//! future fields (if any) flow through here.
//!
//! # Decision shape
//!
//! Mirrors the per-plugin contract from
//! [`super::messages_plugin::redact_messages_plugin_event`] (ADR-0032
//! §3) — re-uses [`super::sms_otp::redact_sms_shapes`] as defense-in-
//! depth + emits a `fired_rules` tally for the CRS Telemetry-Gap
//! analyst's `attribution_redactions_count{field=…}` counter. Drop /
//! redact decision is per-field; one field's match never collapses a
//! sibling field's data.

use super::sms_otp;
use crate::redaction::RedactionResult;

/// Per-field decision for the three Phase 6 PR 5 attribution
/// enrichers. The caller MUST consult the booleans below before
/// persistence — see field docs for the contract.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AttributionCascadeDecision {
    /// `true` when `current_calendar_event.subject` was rewritten by
    /// the §3(a) SMS-OTP regex bank. The caller substitutes the
    /// rewritten string in place before brain persistence; the source
    /// bytes from a matched span do NOT survive.
    pub calendar_subject_rewritten: bool,
    /// `true` when `current_listening_track.title` was rewritten.
    pub track_title_rewritten: bool,
    /// `true` when `current_listening_track.artist` was rewritten.
    pub track_artist_rewritten: bool,
    /// Rules that fired across all four fields, in stable order
    /// (`calendar.subject` first, then `track.title`, then
    /// `track.artist`). Surfaces in the
    /// `attribution_redactions_count{rule=…}` telemetry counter
    /// (content-free per ADR-0015 §4.6).
    pub fired_rules: Vec<&'static str>,
}

impl AttributionCascadeDecision {
    /// True iff at least one field was rewritten. Convenience for
    /// the brain-ingest caller deciding whether to bump the
    /// `attribution_redactions_count` counter.
    #[must_use]
    pub fn any_rewritten(&self) -> bool {
        self.calendar_subject_rewritten
            || self.track_title_rewritten
            || self.track_artist_rewritten
    }
}

/// Apply the cascade-equivalent regex bank to the
/// `current_calendar_event.subject` field. Rewrites in place; returns
/// the [`RedactionResult`] so the caller can route the per-rule
/// telemetry counter.
///
/// Per CSO sign-off row 5 (PR body): this function MUST be called on
/// every populated calendar subject before brain persistence. The
/// integration site at `mci_agent.rs` calls this on the IPC-received
/// `WorkflowContext.current_calendar_event` before forwarding the
/// snapshot down the brain-ingest path.
#[must_use]
pub fn redact_calendar_subject(subject: &mut String) -> RedactionResult {
    let result = sms_otp::redact_sms_shapes(subject);
    if result.matched() {
        // Replace the source bytes with the redacted text — no
        // source bytes from a matched span survive in the field.
        *subject = result.redacted_text.clone();
    }
    result
}

/// Apply the cascade-equivalent regex bank to the
/// `current_listening_track.title` field. Rewrites in place per the
/// same discipline as [`redact_calendar_subject`].
///
/// Per CSO sign-off row 6 (PR body).
#[must_use]
pub fn redact_track_title(title: &mut String) -> RedactionResult {
    let result = sms_otp::redact_sms_shapes(title);
    if result.matched() {
        *title = result.redacted_text.clone();
    }
    result
}

/// Apply the cascade-equivalent regex bank to the
/// `current_listening_track.artist` field. Rewrites in place per the
/// same discipline as [`redact_calendar_subject`].
///
/// Per CSO sign-off row 6 (PR body).
#[must_use]
pub fn redact_track_artist(artist: &mut String) -> RedactionResult {
    let result = sms_otp::redact_sms_shapes(artist);
    if result.matched() {
        *artist = result.redacted_text.clone();
    }
    result
}

/// Apply the full cascade-equivalent for the Phase 6 PR 5
/// attribution enrichers in one pass.
///
/// # Per-field semantics
///
/// - `calendar_subject` — rewritten in place via §3(a) regex bank.
/// - `track_title` / `track_artist` — same treatment.
/// - `contact_identifier` — documented no-op (CSO sign-off row 7).
///   The argument is accepted for API uniformity; the function does
///   not inspect the bytes.
///
/// # `None` semantics
///
/// Any `None` field is a no-op (nothing to redact). The decision
/// flags for that field stay `false`.
#[must_use]
pub fn redact_attribution_fields(
    calendar_subject: Option<&mut String>,
    track_title: Option<&mut String>,
    track_artist: Option<&mut String>,
    contact_identifier: Option<&str>,
) -> AttributionCascadeDecision {
    let mut decision = AttributionCascadeDecision::default();

    if let Some(subj) = calendar_subject {
        let r = redact_calendar_subject(subj);
        if r.matched() {
            decision.calendar_subject_rewritten = true;
            decision.fired_rules.extend(r.fired_rules);
        }
    }
    if let Some(title) = track_title {
        let r = redact_track_title(title);
        if r.matched() {
            decision.track_title_rewritten = true;
            decision.fired_rules.extend(r.fired_rules);
        }
    }
    if let Some(artist) = track_artist {
        let r = redact_track_artist(artist);
        if r.matched() {
            decision.track_artist_rewritten = true;
            decision.fired_rules.extend(r.fired_rules);
        }
    }
    // Contact identifier is opaque — documented no-op per CSO
    // sign-off row 7. Accepted for API uniformity.
    let _ = contact_identifier;

    decision
}

#[cfg(test)]
mod tests {
    use super::*;

    // ------------------------------------------------------------------
    // Per-field redaction — calendar subject
    // ------------------------------------------------------------------

    #[test]
    fn calendar_subject_with_sms_otp_shape_is_rewritten() {
        // Calendar invite subject containing an SMS-OTP shape — rare
        // but possible (auth-app event reminder, banking 2FA invite).
        let mut subject = String::from(
            "Your verification code is 123456 — Apple ID"
        );
        let r = redact_calendar_subject(&mut subject);
        assert!(r.matched(), "SMS-OTP-shaped subject must be rewritten");
        assert!(
            !subject.contains("123456"),
            "source digits must not survive: {subject:?}"
        );
    }

    #[test]
    fn calendar_subject_innocuous_is_untouched() {
        let original = "Weekly 1:1 with manager".to_string();
        let mut subject = original.clone();
        let r = redact_calendar_subject(&mut subject);
        assert!(!r.matched());
        assert_eq!(subject, original);
    }

    #[test]
    fn calendar_subject_empty_is_safe_noop() {
        let mut subject = String::new();
        let r = redact_calendar_subject(&mut subject);
        assert!(!r.matched());
        assert_eq!(subject, "");
    }

    // ------------------------------------------------------------------
    // Per-field redaction — track title / artist
    // ------------------------------------------------------------------

    #[test]
    fn track_title_with_otp_shape_is_rewritten() {
        // Hypothetical podcast episode title carrying an OTP phrase.
        let mut title = String::from(
            "Episode 42: Your OTP is 654321"
        );
        let r = redact_track_title(&mut title);
        assert!(r.matched(), "OTP-shaped track title must be rewritten");
        assert!(!title.contains("654321"));
    }

    #[test]
    fn track_artist_innocuous_is_untouched() {
        let original = "The Daily".to_string();
        let mut artist = original.clone();
        let r = redact_track_artist(&mut artist);
        assert!(!r.matched());
        assert_eq!(artist, original);
    }

    // ------------------------------------------------------------------
    // Composite decision
    // ------------------------------------------------------------------

    #[test]
    fn composite_decision_aggregates_all_three_fields() {
        let mut subject = "Apple ID code is 111111".to_string();
        let mut title = "Reset code 222222 from your bank".to_string();
        let mut artist = "Daily News Podcast".to_string();
        let decision = redact_attribution_fields(
            Some(&mut subject),
            Some(&mut title),
            Some(&mut artist),
            Some("ABCD-1234-EFGH"), // opaque identifier — no-op
        );
        assert!(decision.calendar_subject_rewritten);
        assert!(decision.track_title_rewritten);
        assert!(!decision.track_artist_rewritten); // innocuous
        assert!(decision.any_rewritten());
        assert!(!decision.fired_rules.is_empty());
        // Source digits do not survive in either rewritten field.
        assert!(!subject.contains("111111"));
        assert!(!title.contains("222222"));
        // Innocuous artist is unchanged.
        assert_eq!(artist, "Daily News Podcast");
    }

    #[test]
    fn composite_decision_all_none_is_clean() {
        let decision = redact_attribution_fields(None, None, None, None);
        assert!(!decision.any_rewritten());
        assert!(decision.fired_rules.is_empty());
    }

    #[test]
    fn contact_identifier_is_documented_no_op() {
        // The opaque-identifier no-op contract per CSO sign-off
        // row 7: even when the identifier contains a digit run that
        // would otherwise look OTP-shaped, the function does NOT
        // inspect or alter the identifier bytes.
        let id = "9C2D0F12-3456-789A-BCDE-F00BAA112233".to_string();
        let decision =
            redact_attribution_fields(None, None, None, Some(&id));
        assert!(!decision.any_rewritten());
        assert!(decision.fired_rules.is_empty());
    }

    // ------------------------------------------------------------------
    // Idempotence — rewriting twice is stable
    // ------------------------------------------------------------------

    #[test]
    fn rewriting_twice_is_stable() {
        let mut subject = "Apple ID code is 999111".to_string();
        let _ = redact_calendar_subject(&mut subject);
        let after_first = subject.clone();
        let r2 = redact_calendar_subject(&mut subject);
        assert!(!r2.matched(), "second pass on already-redacted text must not match");
        assert_eq!(subject, after_first);
    }
}
