//! ADR-0030 §3(c) — Mail-header pre-OCR check.
//!
//! Where Messages has a single content area, Mail has a structured
//! `From:`/`To:`/`Cc:`/`Bcc:`/`Subject:` envelope that surfaces in
//! the rendered window before the body. The cascade-twice pipeline
//! gains a **Mail-header pre-OCR check**: before the body is
//! concatenated into the `OCREvent.ocr_text` payload, the cascade
//! tests the sender's eTLD+1 against [`super::sensitive_domains`]
//! and the rendered `Subject:` against [`super::sms_otp`].
//!
//! When [`should_drop_mail_frame`] returns `true`, the caller MUST
//! drop the entire OCR event — no body OCR'd text reaches the wire,
//! no keyframe is written, a `PrivacyTombstone(reason=6)` is
//! emitted. This is the **structural drop** the §6 ⚠️ block in
//! `docs/research/recall-coverage-gap-2026-05-26.md` called out:
//! a Mail frame whose `From:` is `secure@chase.com` containing
//! transaction details that don't themselves match any §3(a) SMS
//! shape or §3(b) URL pattern — the body is still presumed
//! sensitive because the sender is.
//!
//! # Defense-in-depth chain (ADR-0030 §3(c) "Defense-in-depth chain
//! on Mail frames")
//!
//! On every Mail frame the cascade-twice OCR-time arm runs (in
//! order):
//!
//! 1. **[`should_drop_mail_frame`] header check** (this module) —
//!    domain match on the sender OR Subject-line SMS-OTP shape.
//!    Drops the entire event if either fires.
//! 2. **[`super::sensitive_domains::matches_sensitive_domain`] URL /
//!    domain check** on the body — drops if any URL or domain
//!    inside the body matches the sensitive-domain table.
//! 3. **[`super::sms_otp::redact_sms_shapes`] SMS-shape check** on
//!    the body — redacts every match in-place; if any match fired,
//!    the cascade emits a tombstone and the event is dropped
//!    upstream.
//! 4. **ADR-0013 §7 fail-safe-unknown default** — any unclassifiable
//!    frame is suppressed.
//!
//! Any one of these firing drops the event.

use super::sensitive_domains;
use super::sms_otp;

/// Parsed mail-header subset relevant to the §3(c) check.
///
/// Production wiring: the cascade-twice arm extracts these fields
/// from the OCR'd top-N lines of a Mail-foregrounded frame (default
/// N=8 per ADR-0030 §3(c) point 2). RFC 5322 `From:` header
/// rendering — `From: "Real Name" <user@domain>` — is parsed by the
/// upstream extractor; this struct carries the already-extracted
/// domain portion.
///
/// # Field discipline
///
/// - `from_domain` is the eTLD+1 of the sender's email address.
///   Lowercased upstream is recommended but not required —
///   [`super::sensitive_domains::matches_sensitive_domain`] is
///   case-insensitive.
/// - `subject` is the rendered Subject line text — passed through
///   the SMS-shape regex set so subject-only shapes ("Your code:
///   482910") are caught even when no sensitive domain matches.
/// - `list_id` is the `List-ID:` mailing-list header. Reserved for
///   future use (e.g. allowlisting newsletters) — this PR does NOT
///   consult it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MailHeaders {
    /// The `eTLD+1` of the sender's email address (`From:` header).
    /// `chase.com` for `secure@chase.com`, `apple.com` for
    /// `noreply@id.apple.com`. Empty string is allowed when the
    /// OCR pass cannot recover the From line; the check then falls
    /// through to the Subject regex.
    pub from_domain: String,
    /// `List-ID:` header value, if present. Reserved for a future
    /// newsletter-allowlist refinement.
    pub list_id: Option<String>,
    /// Rendered `Subject:` line text. Passed to the SMS-OTP regex
    /// set; if any rule fires, the event drops.
    pub subject: String,
}

/// Decide whether a Mail-foregrounded frame must be dropped at the
/// cascade-twice arm.
///
/// Returns `true` iff EITHER:
///
/// - `headers.from_domain` matches a known sensitive domain
///   ([`super::sensitive_domains::matches_sensitive_domain`]), OR
/// - `headers.subject` matches an SMS-OTP / banking-notification
///   shape ([`super::sms_otp::redact_sms_shapes`]).
///
/// The caller MUST drop the entire event before any body bytes are
/// written when this returns `true`. The match is structural —
/// only the header/subject lines are inspected; body bytes are
/// dropped before any other cascade or storage logic touches them.
///
/// # Performance
///
/// The check runs in sub-millisecond time on M-series hardware: no
/// Vision call, no IO, no allocation beyond [`String::to_string`]
/// inside [`sms_otp::redact_sms_shapes`].
#[must_use]
pub fn should_drop_mail_frame(headers: &MailHeaders) -> bool {
    // §3(c) point 3 — sender-domain match.
    if !headers.from_domain.is_empty()
        && sensitive_domains::matches_sensitive_domain(&headers.from_domain)
    {
        return true;
    }
    // §3(c) belt-and-suspenders — subject-line SMS-OTP shape.
    if !headers.subject.is_empty() {
        let r = sms_otp::redact_sms_shapes(&headers.subject);
        if r.matched() {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(from: &str, subject: &str) -> MailHeaders {
        MailHeaders {
            from_domain: from.to_owned(),
            list_id: None,
            subject: subject.to_owned(),
        }
    }

    #[test]
    fn drops_bank_sender_domain_chase() {
        assert!(should_drop_mail_frame(&h(
            "chase.com",
            "Statement available"
        )));
    }

    #[test]
    fn drops_bank_sender_domain_bofa() {
        assert!(should_drop_mail_frame(&h(
            "alerts.bankofamerica.com",
            "Important account notice",
        )));
    }

    #[test]
    fn drops_apple_id_sender_domain() {
        assert!(should_drop_mail_frame(&h(
            "appleid.apple.com",
            "Recent activity",
        )));
    }

    #[test]
    fn drops_fintech_sender() {
        assert!(should_drop_mail_frame(&h(
            "paypal.com",
            "Receipt for your payment",
        )));
    }

    #[test]
    fn drops_auth_provider_sender() {
        assert!(should_drop_mail_frame(&h(
            "accounts.google.com",
            "Security alert",
        )));
    }

    #[test]
    fn drops_subject_otp_shape_even_with_unknown_sender() {
        assert!(should_drop_mail_frame(&h(
            "newsletter.example.com",
            "Your verification code is 482917",
        )));
    }

    #[test]
    fn drops_subject_password_reset_phrase() {
        assert!(should_drop_mail_frame(&h(
            "support.example.org",
            "Reset your password",
        )));
    }

    #[test]
    fn allows_normal_mail_unknown_sender_safe_subject() {
        assert!(!should_drop_mail_frame(&h(
            "newsletter.example.com",
            "Today's headlines"
        )));
        assert!(!should_drop_mail_frame(&h(
            "team.example.org",
            "Sprint kickoff notes",
        )));
    }

    #[test]
    fn allows_when_from_and_subject_both_empty() {
        assert!(!should_drop_mail_frame(&h("", "")));
    }

    #[test]
    fn allows_empty_from_with_safe_subject() {
        assert!(!should_drop_mail_frame(&h("", "Lunch tomorrow at 12:30")));
    }

    #[test]
    fn drops_empty_from_when_subject_has_otp() {
        assert!(should_drop_mail_frame(&h(
            "",
            "G-018472 is your Google verification code"
        )));
    }

    #[test]
    fn allows_unrelated_domain_chase_substring() {
        // Right-anchored domain match — "notchase.com" is NOT chase.com.
        assert!(!should_drop_mail_frame(&h("notchase.com", "Daily digest")));
        // The "chase.com" string appearing only in the rendered body
        // is not the From-header — this module is structural about
        // which field is checked.
        assert!(!should_drop_mail_frame(&h(
            "trusted.example.com",
            "We saw a chase.com URL in your inbox"
        )));
    }
}
