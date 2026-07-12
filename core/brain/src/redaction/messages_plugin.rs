//! ADR-0030 §3(f) — Messages.app deep-hook plugin redaction arm.
//!
//! This module is the cascade-equivalent for the
//! `mci-messages-reader` deep-hook plugin (`adapters/macos/mci-messages-reader/`,
//! V2-P7). Where ADR-0030 §3(a)–(c) gate the **OCR-time** path
//! (pixels → Vision → text → cascade-twice), §3(f) gates the
//! **plugin-time** path (chat.db row → `MessagesPluginEvent` → cascade-equivalent
//! → optional brain ingest).
//!
//! # Relationship to §3(a)/(b)/(c)
//!
//! §3(f) is **additive**, not a relaxation. It re-uses the same regex set
//! ([`super::sms_otp::redact_sms_shapes`]) and the same domain table
//! ([`super::sensitive_domains::matches_sensitive_domain`]) — every shape
//! the OCR-time path drops, the plugin-time path drops too. The only
//! change is the trigger:
//!
//! | Arm | Trigger | Redactor surface |
//! |---|---|---|
//! | §3(a) | OCR'd text from a Messages/Mail frame | Body text |
//! | §3(b) | OCR'd text containing a sensitive URL or domain | Body text |
//! | §3(c) | OCR'd `From:` header from a Mail frame | Header pre-OCR check |
//! | **§3(f)** | **chat.db row from the Messages deep-hook plugin** | **Body + sender/participants + URL** |
//!
//! # The deep-hook plugin contract this implements (ADR-0032)
//!
//! Per ADR-0032 §3, every per-plugin cascade-equivalent must:
//!
//! 1. Reuse the existing §3(a)/(b) redactors as defense-in-depth.
//! 2. Make a per-event drop / redact decision **before** brain ingest.
//! 3. Surface a `fired_rules` tally for the CRS Telemetry-Gap analyst.
//! 4. Be zero-cost on every non-plugin frame (the helper's hot path).
//! 5. Carry NO additional content surface beyond what the plugin already
//!    has access to.
//!
//! This module satisfies all five.
//!
//! # Default-OFF flag (V2-P10 ships allowlist UI)
//!
//! [`MessagesPluginConfig::DEFAULT`] ships with `plugin_enabled: false`
//! and `allow_all_participants: true`. The plugin's ingest is gated on
//! the explicit user opt-in that V2-P10's onboarding UI lands. V2-P10
//! also introduces the per-participant allowlist; until then the
//! cascade-equivalent runs the §3(a) regex + §3(b) URL check on EVERY
//! participant's message — the broadest, most conservative posture.

use super::{sensitive_domains, sms_otp};

/// One plugin-emitted message event, projected from a `chat.db` row.
///
/// `body` is `None` when the source message has no rendered text
/// (attachment-only / system messages). The cascade-equivalent treats
/// `None` as `drop_event = true` with reason `PluginNoBody` — nothing
/// to redact, nothing to ingest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagesPluginEvent {
    /// Remote participants in the originating chat. Each entry is the
    /// raw `handle.id` (phone, email, or service handle). The
    /// cascade-equivalent runs each through
    /// [`sensitive_domains::matches_sensitive_domain`] to catch the
    /// `bank-alerts@chase.com`-style participant case.
    pub participants: Vec<String>,
    /// `message.text` from `chat.db`. `None` for attachment-only rows.
    pub body: Option<String>,
    /// `message.service` — `"iMessage"`, `"SMS"`, or `"RCS"`. Carried
    /// verbatim so the per-class telemetry counter can split (e.g.
    /// `plugin_redactions_count{service="sms"}`); does NOT change the
    /// cascade decision.
    pub service: String,
    /// `1` when the user sent the message; `0` when received. Outgoing
    /// messages still go through the same cascade — the user can paste
    /// an OTP to a friend, and ADR-0013 §3 fail-safe-default-redact
    /// applies regardless of direction.
    pub is_from_me: bool,
}

/// Per-plugin configuration knobs. Default values reflect the V2-P7
/// "default-OFF + allow-all-participants until V2-P10" posture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagesPluginConfig {
    /// Master switch. When `false`, the cascade-equivalent reports
    /// `drop_event = true` with reason
    /// [`MessagesPluginDropReason::PluginDisabled`] on every event —
    /// no content reaches the brain. V2-P10 flips this to `true`
    /// behind an explicit user opt-in.
    pub plugin_enabled: bool,
    /// When `true`, every participant is implicitly allowed; the
    /// per-participant denylist [`Self::participant_denylist`] is the
    /// only opt-out. When V2-P10 ships, this flips to `false` and the
    /// per-participant [`Self::participant_allowlist`] becomes
    /// authoritative.
    pub allow_all_participants: bool,
    /// V2-P10 surface — explicit per-participant allow list. Unused
    /// until V2-P10 lands the onboarding UI; the field exists today so
    /// the cascade plumbing is forward-compatible.
    pub participant_allowlist: Vec<String>,
    /// User-curated participant denylist. Any event whose
    /// participants intersect this set is dropped with reason
    /// [`MessagesPluginDropReason::ParticipantDenylisted`].
    pub participant_denylist: Vec<String>,
}

impl Default for MessagesPluginConfig {
    fn default() -> Self {
        Self::DEFAULT
    }
}

impl MessagesPluginConfig {
    /// V2-P7 default: plugin off, allow-all-participants, empty
    /// allow/denylists. V2-P10 will replace this with user-driven
    /// configuration from `~/Library/Application Support/MCI/user-allowlist.toml`.
    pub const DEFAULT: Self = Self {
        plugin_enabled: false,
        allow_all_participants: true,
        participant_allowlist: Vec::new(),
        participant_denylist: Vec::new(),
    };
}

/// Reasons the cascade-equivalent drops an event entirely (in priority
/// order — the first applicable reason wins).
///
/// `DropReason` distinct values surface in the per-class telemetry
/// counter the CRS Telemetry-Gap analyst consumes; the values are
/// content-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessagesPluginDropReason {
    /// `plugin_enabled = false`. The master switch has not been
    /// flipped on by the V2-P10 onboarding flow.
    PluginDisabled,
    /// `body = None` — nothing to redact, nothing to ingest.
    PluginNoBody,
    /// One or more participants are on the
    /// [`MessagesPluginConfig::participant_denylist`].
    ParticipantDenylisted,
    /// `allow_all_participants = false` AND none of the participants
    /// is on the explicit allowlist (V2-P10 path; never fires today).
    ParticipantNotAllowlisted,
    /// A participant address (phone OR email) matches the
    /// [`sensitive_domains`] table — e.g. `alerts@chase.com`.
    /// Treat the whole message as bank-side sensitive content.
    SensitiveParticipantDomain,
    /// The body contains a sensitive URL or domain match per §3(b).
    /// E.g. a Messages forward of `https://secure.chase.com/reset?...`.
    SensitiveUrlInBody,
}

/// Decision returned by the cascade-equivalent.
///
/// The brain-ingest caller MUST:
///
/// - If `drop_event = true` → emit a content-free
///   `PrivacyTombstone(reason=plugin_redacted)` (or equivalent) and
///   skip ingest entirely.
/// - Otherwise → ingest the message using [`Self::redacted_body`] (NOT
///   the source body — the SMS-OTP regex set may have rewritten spans
///   in place).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagesPluginDecision {
    /// `true` when the event must be dropped before persistence.
    pub drop_event: bool,
    /// Reason for the drop, when `drop_event = true`. `None` when the
    /// event is being ingested.
    pub drop_reason: Option<MessagesPluginDropReason>,
    /// The body to ingest. Carries the §3(a) SMS-OTP regex
    /// replacement tokens in place of any matched OTP/banking shape.
    /// Empty string when the event is being dropped — the brain
    /// ingest path never sees this content.
    pub redacted_body: String,
    /// Rules that fired during the §3(a) SMS-OTP regex pass.
    /// Surfaces in the `plugin_redactions_count{rule=…}` telemetry
    /// counter (content-free per ADR-0015 §4.6).
    pub fired_rules: Vec<&'static str>,
}

/// Apply ADR-0030 §3(f) cascade-equivalent to one
/// [`MessagesPluginEvent`].
///
/// Decision order (first applicable wins):
///
/// 1. **Master switch.** `plugin_enabled = false` → drop with
///    [`MessagesPluginDropReason::PluginDisabled`].
/// 2. **Body presence.** `body = None` → drop with
///    [`MessagesPluginDropReason::PluginNoBody`].
/// 3. **Participant denylist.** Any participant ∈
///    `participant_denylist` → drop with
///    [`MessagesPluginDropReason::ParticipantDenylisted`].
/// 4. **Participant allowlist** (V2-P10 — currently no-op when
///    `allow_all_participants = true`). With explicit allowlists, an
///    event whose participants are none of the allowed entries → drop
///    with [`MessagesPluginDropReason::ParticipantNotAllowlisted`].
/// 5. **Sensitive participant domain.** Any participant address
///    (phone OR email) matches the §3(b) sensitive-domain table →
///    drop with [`MessagesPluginDropReason::SensitiveParticipantDomain`].
/// 6. **Sensitive URL in body.** Any URL or domain inside the body
///    matches the §3(b) table → drop with
///    [`MessagesPluginDropReason::SensitiveUrlInBody`].
/// 7. **§3(a) SMS-OTP regex redaction.** Replace every match
///    in-place; return `redacted_body` with the substitutions applied
///    and `fired_rules` populated. Even if the regex fires, the event
///    is NOT dropped at this step — the matched spans are scrubbed in
///    place per the same discipline the OCR-time arm uses (token
///    substitution preserves the surrounding text).
#[must_use]
pub fn redact_messages_plugin_event(
    evt: &MessagesPluginEvent,
    cfg: &MessagesPluginConfig,
) -> MessagesPluginDecision {
    // (1) Master switch.
    if !cfg.plugin_enabled {
        return MessagesPluginDecision {
            drop_event: true,
            drop_reason: Some(MessagesPluginDropReason::PluginDisabled),
            redacted_body: String::new(),
            fired_rules: Vec::new(),
        };
    }

    // (2) Body presence.
    let Some(body) = evt.body.as_deref() else {
        return MessagesPluginDecision {
            drop_event: true,
            drop_reason: Some(MessagesPluginDropReason::PluginNoBody),
            redacted_body: String::new(),
            fired_rules: Vec::new(),
        };
    };

    // (3) Participant denylist. The denylist is small (user-curated);
    // a linear scan is fine, and case-folding the comparison matches
    // the user's mental model ("I added jane@example.com but the row
    // shows JANE@EXAMPLE.COM").
    if any_participant_matches(&evt.participants, &cfg.participant_denylist) {
        return MessagesPluginDecision {
            drop_event: true,
            drop_reason: Some(MessagesPluginDropReason::ParticipantDenylisted),
            redacted_body: String::new(),
            fired_rules: Vec::new(),
        };
    }

    // (4) Participant allowlist (V2-P10). When allow_all_participants
    // is true (the V2-P7 default per `MessagesPluginConfig::DEFAULT`),
    // this gate is a no-op. V2-P10 flips the flag and the explicit
    // allowlist becomes authoritative; an event whose participants
    // miss the allowlist is dropped.
    if !cfg.allow_all_participants
        && !any_participant_matches(&evt.participants, &cfg.participant_allowlist)
    {
        return MessagesPluginDecision {
            drop_event: true,
            drop_reason: Some(MessagesPluginDropReason::ParticipantNotAllowlisted),
            redacted_body: String::new(),
            fired_rules: Vec::new(),
        };
    }

    // (5) Sensitive participant domain. The participant string may be
    // a phone, a bare email, or a service handle. The
    // §3(b) accessor handles both `email@domain` and bare hosts.
    for p in &evt.participants {
        if !p.is_empty() && sensitive_domains::matches_sensitive_domain(p) {
            return MessagesPluginDecision {
                drop_event: true,
                drop_reason: Some(MessagesPluginDropReason::SensitiveParticipantDomain),
                redacted_body: String::new(),
                fired_rules: Vec::new(),
            };
        }
    }

    // (6) Sensitive URL in body. Lightly scan the body for whitespace-
    // separated tokens that look like URLs or bare hosts and probe
    // each against the §3(b) accessor. The accessor itself handles
    // empty / non-URL tokens cheaply.
    for token in body_tokens(body) {
        if looks_like_url_or_host(token) && sensitive_domains::matches_sensitive_domain(token) {
            return MessagesPluginDecision {
                drop_event: true,
                drop_reason: Some(MessagesPluginDropReason::SensitiveUrlInBody),
                redacted_body: String::new(),
                fired_rules: Vec::new(),
            };
        }
    }

    // (7) §3(a) SMS-OTP regex redaction. Token substitution in place;
    // the event is INGESTED but the matched spans are scrubbed first.
    let r = sms_otp::redact_sms_shapes(body);
    MessagesPluginDecision {
        drop_event: false,
        drop_reason: None,
        redacted_body: r.redacted_text,
        fired_rules: r.fired_rules,
    }
}

/// True iff any participant (case-folded) appears in `set`.
fn any_participant_matches(participants: &[String], set: &[String]) -> bool {
    if set.is_empty() {
        return false;
    }
    let lower: Vec<String> = set.iter().map(|s| s.to_ascii_lowercase()).collect();
    participants
        .iter()
        .any(|p| lower.iter().any(|s| s.eq_ignore_ascii_case(p)))
}

/// Cheap whitespace tokenization. Splits on ASCII whitespace AND
/// trims trailing punctuation that commonly bookend URLs in chat
/// (`.`, `,`, `;`, `)`, `]`, `>`, `"`, `'`).
fn body_tokens(body: &str) -> impl Iterator<Item = &str> {
    body.split(|c: char| c.is_ascii_whitespace())
        .map(|t| {
            t.trim_matches(|c: char| matches!(c, '.' | ',' | ';' | ')' | ']' | '>' | '"' | '\''))
        })
        .filter(|t| !t.is_empty())
}

/// Cheap heuristic: a token is a URL-like or bare-host string when
/// it contains `://` OR contains a `.` and at least one ASCII letter
/// AND no whitespace. False positives are fine here — the §3(b)
/// accessor is the real check; this just keeps the cost down on the
/// hot path.
fn looks_like_url_or_host(token: &str) -> bool {
    if token.contains("://") {
        return true;
    }
    token.contains('.') && token.chars().any(|c| c.is_ascii_alphabetic())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn evt(body: Option<&str>, participants: &[&str]) -> MessagesPluginEvent {
        MessagesPluginEvent {
            participants: participants.iter().map(|s| (*s).to_owned()).collect(),
            body: body.map(str::to_owned),
            service: "iMessage".to_owned(),
            is_from_me: false,
        }
    }

    fn enabled_cfg() -> MessagesPluginConfig {
        MessagesPluginConfig {
            plugin_enabled: true,
            ..MessagesPluginConfig::DEFAULT
        }
    }

    // ----- (1) Master switch -----

    #[test]
    fn default_config_disables_ingest() {
        let d = redact_messages_plugin_event(
            &evt(Some("hello"), &["+15551234567"]),
            &MessagesPluginConfig::DEFAULT,
        );
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::PluginDisabled)
        );
        assert!(d.redacted_body.is_empty());
    }

    // ----- (2) No body -----

    #[test]
    fn attachment_only_drops_with_no_body_reason() {
        let d = redact_messages_plugin_event(&evt(None, &["+15551234567"]), &enabled_cfg());
        assert!(d.drop_event);
        assert_eq!(d.drop_reason, Some(MessagesPluginDropReason::PluginNoBody));
    }

    // ----- (3) Participant denylist -----

    #[test]
    fn participant_denylist_drops() {
        let cfg = MessagesPluginConfig {
            plugin_enabled: true,
            allow_all_participants: true,
            participant_allowlist: vec![],
            participant_denylist: vec!["+15551234567".into()],
        };
        let d = redact_messages_plugin_event(&evt(Some("hi"), &["+15551234567"]), &cfg);
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::ParticipantDenylisted)
        );
    }

    #[test]
    fn participant_denylist_case_insensitive() {
        let cfg = MessagesPluginConfig {
            plugin_enabled: true,
            allow_all_participants: true,
            participant_allowlist: vec![],
            participant_denylist: vec!["JANE@EXAMPLE.COM".into()],
        };
        let d = redact_messages_plugin_event(&evt(Some("hi"), &["jane@example.com"]), &cfg);
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::ParticipantDenylisted)
        );
    }

    // ----- (4) Participant allowlist (V2-P10) -----

    #[test]
    fn allowlist_required_when_not_allow_all() {
        let cfg = MessagesPluginConfig {
            plugin_enabled: true,
            allow_all_participants: false,
            participant_allowlist: vec!["+15551234567".into()],
            participant_denylist: vec![],
        };
        // Disallowed participant.
        let d = redact_messages_plugin_event(&evt(Some("hi"), &["+15559999999"]), &cfg);
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::ParticipantNotAllowlisted)
        );
        // Allowed participant.
        let d = redact_messages_plugin_event(&evt(Some("hi"), &["+15551234567"]), &cfg);
        assert!(!d.drop_event);
    }

    // ----- (5) Sensitive participant domain -----

    #[test]
    fn sensitive_participant_email_drops() {
        let d = redact_messages_plugin_event(
            &evt(Some("Statement available"), &["alerts@chase.com"]),
            &enabled_cfg(),
        );
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::SensitiveParticipantDomain)
        );
    }

    #[test]
    fn normal_phone_participant_does_not_drop() {
        let d = redact_messages_plugin_event(
            &evt(Some("Hey see you at 7"), &["+15551234567"]),
            &enabled_cfg(),
        );
        assert!(!d.drop_event);
    }

    // ----- (6) Sensitive URL in body -----

    #[test]
    fn sensitive_url_in_body_drops() {
        let d = redact_messages_plugin_event(
            &evt(
                Some("Check the alert: https://secure.chase.com/login"),
                &["+15551234567"],
            ),
            &enabled_cfg(),
        );
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::SensitiveUrlInBody)
        );
    }

    #[test]
    fn bare_sensitive_domain_in_body_drops() {
        let d = redact_messages_plugin_event(
            &evt(Some("Open chase.com to verify."), &["+15551234567"]),
            &enabled_cfg(),
        );
        assert!(d.drop_event);
        assert_eq!(
            d.drop_reason,
            Some(MessagesPluginDropReason::SensitiveUrlInBody)
        );
    }

    #[test]
    fn unrelated_url_in_body_does_not_drop() {
        let d = redact_messages_plugin_event(
            &evt(
                Some("Read this: https://example.com/blog"),
                &["+15551234567"],
            ),
            &enabled_cfg(),
        );
        assert!(!d.drop_event);
    }

    // ----- (7) §3(a) SMS-OTP regex redaction in place -----

    #[test]
    fn sms_otp_shape_is_redacted_but_ingested() {
        let d = redact_messages_plugin_event(
            &evt(
                Some("482917 is your verification code. Don't share it."),
                &["+15551234567"],
            ),
            &enabled_cfg(),
        );
        assert!(!d.drop_event, "SMS-OTP redaction is in-place, not a drop");
        assert!(
            !d.redacted_body.contains("482917"),
            "OTP digits must not survive in {:?}",
            d.redacted_body
        );
        assert!(!d.fired_rules.is_empty());
    }

    #[test]
    fn bank_notification_shape_is_redacted_but_ingested() {
        let d = redact_messages_plugin_event(
            &evt(
                Some("Bank of America: Did you make a charge for $482.19 at AMAZON? Reply YES or NO."),
                &["+15551234567"],
            ),
            &enabled_cfg(),
        );
        assert!(!d.drop_event);
        assert!(!d.redacted_body.contains("$482.19"));
        assert!(!d.fired_rules.is_empty());
    }

    #[test]
    fn personal_chat_passes_through_with_no_rules() {
        let d = redact_messages_plugin_event(
            &evt(Some("Pick up milk on the way home?"), &["+15551234567"]),
            &enabled_cfg(),
        );
        assert!(!d.drop_event);
        assert_eq!(d.redacted_body, "Pick up milk on the way home?");
        assert!(d.fired_rules.is_empty());
    }

    // ----- Empty / edge inputs -----

    #[test]
    fn empty_body_string_is_ingested_with_empty_redacted_body() {
        let d = redact_messages_plugin_event(&evt(Some(""), &["+15551234567"]), &enabled_cfg());
        // Empty Some("") body is *technically* present — the cascade
        // runs the regex (no match) and the body is ingested as ""
        // by the brain-side caller.
        assert!(!d.drop_event);
        assert_eq!(d.redacted_body, "");
    }

    #[test]
    fn empty_participants_list_does_not_drop_when_body_safe() {
        let d = redact_messages_plugin_event(&evt(Some("ping"), &[]), &enabled_cfg());
        // No participants → no denylist match, no domain match, no
        // allowlist gate (allow_all = true). Body is safe → not dropped.
        assert!(!d.drop_event);
    }

    // ----- Helpers -----

    #[test]
    fn body_tokens_strips_trailing_punctuation() {
        let toks: Vec<&str> = body_tokens("see https://example.com/x.").collect();
        assert_eq!(toks, vec!["see", "https://example.com/x"]);
    }

    #[test]
    fn looks_like_url_or_host_recognizes_common_shapes() {
        assert!(looks_like_url_or_host("https://example.com"));
        assert!(looks_like_url_or_host("chase.com"));
        assert!(looks_like_url_or_host("login.microsoftonline.com"));
        assert!(!looks_like_url_or_host("hello"));
        assert!(!looks_like_url_or_host("123"));
    }
}
