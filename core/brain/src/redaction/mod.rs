//! OCR-time redaction layer for `com.apple.MobileSMS` and `com.apple.mail`
//! per ADR-0030 §3(a)–(c).
//!
//! # Why this module exists
//!
//! The ADR-0013 cascade's pixel-time arms (`.secureInput`,
//! `kAXSecureTextFieldSubrole`, OS-blacked region, source-level denylist,
//! post-capture denylist, fail-safe-unknown) fire when the user is *entering*
//! a credential or when the *focused element is a secure field*. None of
//! them fire when the user is **passively viewing** rendered Messages or
//! Mail content. ADR-0030 specifies the additional OCR-time redaction
//! layer that must exist (and be measured against a committed corpus)
//! before either bundle can be added to
//! `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml`.
//!
//! # Scope of this PR (§3(a)–(c) + §3(f); §3(d) deferred, §3(e) doc-stated)
//!
//! - [`sms_otp::redact_sms_shapes`] — §3(a) SMS-OTP / banking-notification
//!   regex set covering Apple ID 2FA, US bank OTPs, generic carrier OTPs,
//!   password-reset codes, auth-app mirror notifications.
//! - [`sensitive_domains::matches_sensitive_domain`] — §3(b)
//!   `SensitiveDomainTable` accessor. Loads `docs/research/sensitive-domains.toml`
//!   at compile-time via `include_str!()`; parses domains + URL patterns
//!   into an immutable, lazily-initialized table.
//! - [`mail_header::should_drop_mail_frame`] — §3(c) Mail-header pre-OCR
//!   check. Refuses any frame whose rendered `From:` header matches a
//!   sensitive domain, regardless of body content.
//! - [`messages_plugin::redact_messages_plugin_event`] — §3(f) per-plugin
//!   cascade-equivalent for the V2-P7 Messages deep-hook plugin. Reuses
//!   §3(a) + §3(b) on a chat.db row's body and participants. Additive to
//!   §3(a)–(c); does not relax any existing semantics. See ADR-0032 for
//!   the deep-hook plugin contract this implements.
//!
//! # App-bundle gating (binding, ADR-0030 §3 + ADR-0015 §5)
//!
//! All three sub-arms are GATED at the call site by `app_bundle_id` —
//! they run only for `com.apple.MobileSMS` and `com.apple.mail` frames
//! (zero-cost on every other app's frames). The constants
//! [`MESSAGES_BUNDLE_ID`] and [`MAIL_BUNDLE_ID`] are the public bundle
//! identifiers; consumers compose them into their own gating logic.
//!
//! # ADR-0013 §3 fail-safe-default-redact preservation
//!
//! When [`sms_otp::redact_sms_shapes`] matches, the replacement token is a
//! literal `[REDACTED:SMS_OTP]` (or `[REDACTED:BANK_NOTIFICATION]` per
//! rule class). **No source bytes survive in the returned text.**
//! When [`mail_header::should_drop_mail_frame`] returns `true`, the
//! caller MUST drop the entire OCR event before body bytes are written
//! to storage (cascade-twice arm per ADR-0016 §1.6 + §4.2). The integration
//! point — the cascade-twice OCR-time arm in the helper — is the place
//! these sub-arms mount; this PR ships the stand-alone module + unit
//! tests + corpus-runner gate.
//!
//! # Zero-network discipline (ADR-0001 + ADR-0016 §4.4)
//!
//! Nothing here opens a network socket, loads a remote model, or reads
//! a file outside the compile-time-baked TOML. The redaction layer is
//! pure-Rust regex + static-table lookup.

pub mod mail_header;
pub mod messages_plugin;
pub mod parsed_mail_header;
pub mod sensitive_domains;
pub mod sms_otp;

/// Bundle id of macOS Messages — `com.apple.MobileSMS`. The §3(a) + §3(b)
/// sub-arms fire for frames whose `app_bundle_id` matches this value.
pub const MESSAGES_BUNDLE_ID: &str = "com.apple.MobileSMS";

/// Bundle id of macOS Mail — `com.apple.mail`. The §3(a) + §3(b) + §3(c)
/// sub-arms fire for frames whose `app_bundle_id` matches this value.
pub const MAIL_BUNDLE_ID: &str = "com.apple.mail";

/// True iff the bundle is in scope for the ADR-0030 §3(a)–(c) redaction
/// layer.
///
/// Composable helper for cascade-twice callers — equivalent to
/// `bundle == MESSAGES_BUNDLE_ID || bundle == MAIL_BUNDLE_ID`. Returning
/// `false` keeps the redaction layer zero-cost on every other app's frames
/// (the helper's hot path).
#[must_use]
pub fn bundle_is_in_scope(app_bundle_id: &str) -> bool {
    app_bundle_id == MESSAGES_BUNDLE_ID || app_bundle_id == MAIL_BUNDLE_ID
}

/// Result of applying the §3(a) SMS-OTP / banking-notification regex set
/// to one piece of OCR'd text.
///
/// `fired_rules` is a list of stable rule ids (e.g. `"apple-id-otp"`,
/// `"bank-issuer-prefix"`, `"otp-proximity"`) carried separately from
/// the redacted text so the caller can route a telemetry counter
/// (`ocr_text_secret_match_count` per CRS Telemetry-Gap analyst) without
/// re-running the regex set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedactionResult {
    /// The original text with every match replaced by the rule-class
    /// replacement token (`[REDACTED:SMS_OTP]` or
    /// `[REDACTED:BANK_NOTIFICATION]`). No source bytes from a matched
    /// region survive.
    pub redacted_text: String,
    /// Stable rule ids that fired. Empty when no rule matched. Order
    /// follows the cascade evaluation order (Tier 1 issuer-prefix shapes
    /// first, then proximity, then generic OTP shapes).
    pub fired_rules: Vec<&'static str>,
}

impl RedactionResult {
    /// True iff at least one rule fired — equivalent to
    /// `!self.fired_rules.is_empty()`. Convenience for the cascade-twice
    /// caller deciding whether to emit a `PrivacyTombstone(reason=6)`
    /// (ADR-0013 §4 + ADR-0016 §1.6).
    #[must_use]
    pub fn matched(&self) -> bool {
        !self.fired_rules.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_scope_covers_only_messages_and_mail() {
        assert!(bundle_is_in_scope(MESSAGES_BUNDLE_ID));
        assert!(bundle_is_in_scope(MAIL_BUNDLE_ID));
        assert!(bundle_is_in_scope("com.apple.MobileSMS"));
        assert!(bundle_is_in_scope("com.apple.mail"));
        // Every other bundle is out-of-scope — the redaction layer is
        // zero-cost on the helper's hot path for those frames.
        for outside in [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.microsoft.VSCode",
            "com.apple.Terminal",
            "com.apple.MAIL", // case-sensitive — Mail is lower-case
            "",
        ] {
            assert!(
                !bundle_is_in_scope(outside),
                "bundle {outside:?} must be out-of-scope"
            );
        }
    }

    #[test]
    fn redaction_result_matched_mirrors_fired_rules() {
        let empty = RedactionResult {
            redacted_text: "hello".into(),
            fired_rules: vec![],
        };
        assert!(!empty.matched());

        let hit = RedactionResult {
            redacted_text: "[REDACTED:SMS_OTP]".into(),
            fired_rules: vec!["apple-id-otp"],
        };
        assert!(hit.matched());
    }
}
