//! ADR-0030 §3(c)(ii) — parsed-header cascade-equivalent for the
//! Mail.app emlx deep-hook path (V2-P8b).
//!
//! # Why this module exists (parallel arm to §3(c))
//!
//! ADR-0030 §3(c) specifies the **OCR-path** Mail-header check —
//! cascade-twice scans the top-N OCR'd lines of a Mail-foregrounded
//! frame for a `From:` line, extracts the eTLD+1, and refuses the
//! frame if the domain matches `sensitive_domains.toml`. That arm runs
//! at the helper boundary against rendered Mail.app pixels.
//!
//! V2-P8 introduces a **second** Mail surface: the always-on emlx
//! deep-hook that reads `~/Library/Mail/V<N>/.../*.emlx` directly via
//! `mci-mail-reader` (PR #243). The same trust-boundary discipline
//! must hold on this surface, but the input shape is different —
//! there is no top-N OCR'd line scan; instead the cascade gets
//! **typed RFC 5322 header values** parsed by `mail-parser`.
//!
//! This module is that second arm. §3(c)(ii) per the Mail-spike
//! memo §9 (`docs/research/mail-envelope-schema-2026-05-29.md`).
//!
//! # Drop-before-write semantics (LOAD-BEARING, CSO audit)
//!
//! [`cascade_equivalent`] is the **pre-write** check. It is called by
//! the brain-ingest mail pump (`apps/agent/src/mail_ingest.rs`) BEFORE
//! any emlx body byte is materialized into a brain [`crate::Event`]
//! row. The function inputs are the typed header subset; the output
//! is a [`MailCascadeDecision`] that the pump applies structurally:
//!
//! - [`MailCascadeDecision::Allow`] — body + headers persist as a
//!   normal Event row.
//! - [`MailCascadeDecision::HeaderOnly`] — body bytes are DROPPED at
//!   the pump; only a content-free audit marker row is persisted
//!   (sender eTLD+1 is the categorical match key — known sensitive
//!   domain — not user-identifying content; subject text is replaced
//!   with the literal placeholder [`REDACTED_SUBJECT`]; body bytes
//!   never reach `put_event`).
//! - [`MailCascadeDecision::Refuse`] — fail-safe; no row, no body,
//!   no subject, no headers reach the brain. Used when the emlx file
//!   has no parseable `From:` header (the §7 fail-safe-unknown
//!   default for unclassifiable bundles, transposed onto the
//!   parsed-header path).
//!
//! In ALL non-`Allow` outcomes the body bytes from the source emlx
//! never cross into `put_event`. This is the drop-before-write
//! discipline ADR-0013 §3 fail-safe-default-redact + ADR-0030 §3(c)
//! intent require — the redaction happens **before** the write, not
//! by a delete-after-write pass.
//!
//! # Defense-in-depth chain
//!
//! When [`cascade_equivalent`] returns `Allow` for a Mail emlx, the
//! pump must still feed the body through:
//!
//! 1. [`super::sensitive_domains::matches_sensitive_domain`] over any
//!    URL extracted from the body — drops to `HeaderOnly` if any URL
//!    host matches.
//! 2. [`super::sms_otp::redact_sms_shapes`] over the body text —
//!    redacts every match in-place; if any rule fired, the row is
//!    still persisted (the SMS-shape is replaced by
//!    `[REDACTED:SMS_OTP]` so source bytes do not survive).
//!
//! Those two sub-arms are the §3(a) + §3(b) discipline applied to
//! the emlx body in the pump (the OCR-path applies them to the
//! rendered top-N + body in the helper). This module owns ONLY the
//! §3(c)(ii) parsed-header arm.
//!
//! # Zero-network discipline (ADR-0001 + ADR-0016 §4.4)
//!
//! This module reads only [`super::sensitive_domains`] (which itself
//! is a compile-time-included TOML) and runs the SMS-shape regex set
//! over the subject string. No socket, no file read, no dynamic
//! update.
//!
//! # Relationship to existing §3(c) module
//!
//! [`super::mail_header`] is the §3(c) (OCR-path, rendered-line)
//! check. Both modules consult the same
//! [`super::sensitive_domains::matches_sensitive_domain`] +
//! [`super::sms_otp::redact_sms_shapes`] back-ends — the trust
//! boundary is the **single source of truth** for sensitive-domain
//! and OTP-shape recognition. The two modules differ only in input
//! shape (rendered OCR lines vs typed RFC 5322 headers).
//!
//! # Cross-check vs the Mail-spike memo
//!
//! The spike (`docs/research/mail-envelope-schema-2026-05-29.md` §9)
//! analyzes whether §3(c)'s "top-N OCR'd lines" framing literally
//! transfers to emlx ingest — and concludes it does NOT (RFC 5322
//! header position is not the rendered Mail.app preview position).
//! §3(c)(ii) below replaces the line-position framing with a typed
//! [`ParsedMailHeaders`] view; the domain table + OTP regex are
//! unchanged.

use super::mail_header::MailHeaders;
use super::sensitive_domains;
use super::sms_otp;

/// Placeholder string used in lieu of any rendered subject when the
/// cascade-equivalent decides the body must be dropped. Surface as a
/// constant so the corpus harness + CSO audit can grep for it.
pub const REDACTED_SUBJECT: &str = "[REDACTED:MAIL_HEADER_MATCH]";

/// Placeholder used as the brain Event `text` for a header-only audit
/// row. The sender eTLD+1 is appended after this token by the pump
/// (categorical, not user-identifying); the body is dropped.
pub const REDACTED_BODY_MARKER: &str = "[REDACTED:MAIL_HEADER_MATCH]";

/// Sentinel sender domain used when the emlx file did not surface a
/// parseable `From:` header. The fail-safe outcome — see
/// [`MailCascadeDecision::Refuse`] — does NOT persist any row, so
/// this constant is only surfaced in audit-log / corpus output.
pub const UNPARSEABLE_SENDER: &str = "<unparseable>";

/// Typed mail-header subset for the §3(c)(ii) cascade-equivalent.
///
/// Produced by `mci-mail-reader::parse::read_message` (typed RFC 5322
/// headers via `mail-parser`); the pump translates the
/// [`mci_mail_reader::ParsedMessage`] shape into this struct so the
/// brain crate has no compile-time dependency on `mci-mail-reader`.
///
/// # Field discipline
///
/// All domain fields hold the eTLD+1 portion of an email address
/// (everything after the last `@`). Lowercasing is the responsibility
/// of the caller — [`sensitive_domains::matches_sensitive_domain`]
/// itself is case-insensitive, but lowercasing at input keeps the
/// downstream telemetry counters from double-counting `Chase.com`
/// and `chase.com`.
///
/// `from_domain` is REQUIRED for an `Allow` decision; an empty value
/// means "no parseable `From:`" and forces a fail-safe `Refuse`
/// outcome.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedMailHeaders {
    /// eTLD+1 of the `From:` header (`chase.com` for
    /// `secure@chase.com`). Empty when the emlx file had no parseable
    /// `From:` header.
    pub from_domain: String,
    /// eTLD+1 of the `Reply-To:` header. `None` when absent.
    ///
    /// V2-P8b §3(c)(ii) checks `Reply-To:` in addition to `From:` to
    /// catch the phishing-shape memo §11 Q4 case: bank-impersonation
    /// mails commonly set `From: notify@chase.com` but
    /// `Reply-To: attacker@example.com`. ANY match across `From:` /
    /// `Reply-To:` / `Sender:` / `List-ID:` (subset) triggers a
    /// drop.
    pub reply_to_domain: Option<String>,
    /// eTLD+1 of the `Sender:` header. `None` when absent.
    pub sender_domain: Option<String>,
    /// Domain portion extracted from a `List-ID:` header (mailing-list
    /// identifier). `None` when absent.
    ///
    /// `List-ID:` is RFC 2919 — the value typically looks like
    /// `<list-name.example.com>` or `Plain Text <list-name.example.com>`.
    /// The pump extracts the bracket-quoted host and stores it here
    /// without the angle brackets.
    pub list_id_domain: Option<String>,
    /// Rendered `Subject:` line. Empty when the emlx had no
    /// `Subject:` header. Routed through
    /// [`sms_otp::redact_sms_shapes`] — a subject containing an
    /// OTP-shape (e.g. `Your code: 482910`) triggers a drop
    /// independent of the sender domain.
    pub subject: String,
}

/// Result of the §3(c)(ii) cascade-equivalent for one mail.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MailCascadeDecision {
    /// Mail is safe to persist with the full body + headers. The
    /// caller (mail-ingest pump) goes on to apply §3(a) + §3(b) over
    /// the body before final persist (defense-in-depth chain).
    Allow,
    /// Mail must be persisted as a content-free header-only audit
    /// row.
    ///
    /// - `sender_domain`: the categorical sender eTLD+1 that matched
    ///   the sensitive-domain table (or `UNPARSEABLE_SENDER` if the
    ///   `Refuse` path was taken upstream and downgraded to a
    ///   sentinel row).
    /// - `reason`: which sub-rule fired (counter discipline for the
    ///   CRS Telemetry-Gap analyst).
    ///
    /// The pump persists this as an Event row with:
    /// - `text = "[REDACTED:MAIL_HEADER_MATCH] from=<sender_domain>"`
    /// - `window_title = "[REDACTED:MAIL_HEADER_MATCH]"`
    /// - `url = None`
    /// - `cascade_reason = 0` (the body was dropped before the row
    ///   was constructed; the existing brain store invariant
    ///   `cascade_reason == 0` for any reachable Event is preserved)
    ///
    /// Body bytes from the source emlx never reach `put_event`.
    HeaderOnly {
        /// Categorical eTLD+1 that triggered the redaction.
        sender_domain: String,
        /// Which sub-rule fired (telemetry).
        reason: MailRedactionReason,
    },
    /// Fail-safe refusal — emlx file had no parseable `From:`
    /// header. No row reaches `put_event` at all; the pump increments
    /// its `frames_refused_no_parseable_sender` counter and moves on.
    ///
    /// This is the §3(c)(ii) analogue of ADR-0013 §7
    /// fail-safe-unknown: when the cascade cannot positively classify
    /// the input, the safe default is to drop entirely rather than
    /// persist any partial state.
    Refuse {
        /// Reason this mail was refused (always
        /// [`MailRedactionReason::UnparseableEnvelope`] in v1).
        reason: MailRedactionReason,
    },
}

/// Sub-rule code distinguishing which §3(c)(ii) sub-arm fired.
///
/// Conceptually parallel to the existing
/// [`super::super::ipc::RedactionReason`] enum but local to the
/// V2-P8b brain-ingest path — values here are NEVER emitted on the
/// helper-to-agent IPC wire (the mail-ingest pump runs entirely
/// inside `mci-agent`; no helper produces a `MailHeaderMatch` byte).
/// Keeping the enum local minimizes blast radius on the
/// wire-protected `RedactionReason` (which would otherwise need a
/// wire bump per `AGENT_PROTOCOL` §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MailRedactionReason {
    /// One of `From:` / `Reply-To:` / `Sender:` / `List-ID:` eTLD+1
    /// matched a `sensitive-domains.toml` entry.
    SensitiveSenderDomain,
    /// The rendered `Subject:` text matched a §3(a) SMS-OTP /
    /// banking-notification shape.
    SubjectOtpShape,
    /// The emlx file did not surface a parseable `From:` header.
    /// Fail-safe default: refuse to persist any row.
    UnparseableEnvelope,
}

impl MailRedactionReason {
    /// Stable lowercase-kebab string for audit / corpus / counter
    /// output. Persisted nowhere on the wire; surfaces only in
    /// content-free telemetry strings.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SensitiveSenderDomain => "mail-header-match:sensitive-sender-domain",
            Self::SubjectOtpShape => "mail-header-match:subject-otp-shape",
            Self::UnparseableEnvelope => "mail-header-match:unparseable-envelope",
        }
    }

    /// The top-level `PrivacyTombstone`-reason string the
    /// cascade-equivalent emits to audit logs. All three sub-rules
    /// collapse into the single `mail-header-match` class so the
    /// CSO sign-off + audit artifact have one stable string to match.
    #[must_use]
    pub const fn tombstone_reason(self) -> &'static str {
        "mail-header-match"
    }
}

/// Apply the §3(c)(ii) cascade-equivalent to one mail.
///
/// This is the pure-function pre-write check the brain-ingest mail
/// pump calls before constructing any brain [`crate::Event`] from an
/// emlx file. See the module-level docs for the full
/// drop-before-write contract.
///
/// # Decision order
///
/// 1. If `headers.from_domain` is empty → [`MailCascadeDecision::Refuse`]
///    with reason [`MailRedactionReason::UnparseableEnvelope`].
/// 2. If any of `from_domain`, `reply_to_domain`, `sender_domain`,
///    `list_id_domain` matches a sensitive-domain table entry →
///    [`MailCascadeDecision::HeaderOnly`] with reason
///    [`MailRedactionReason::SensitiveSenderDomain`] and
///    `sender_domain` = the eTLD+1 that fired (first hit, in the
///    fixed order above).
/// 3. If the subject matches a §3(a) SMS-shape →
///    [`MailCascadeDecision::HeaderOnly`] with reason
///    [`MailRedactionReason::SubjectOtpShape`] and `sender_domain`
///    = `headers.from_domain` (preserved as a categorical signal
///    even though it didn't fire the table).
/// 4. Otherwise → [`MailCascadeDecision::Allow`].
///
/// The early return on step (1) is the §7 fail-safe-unknown default
/// transposed to the parsed-header path: an emlx with no
/// `From:` is unclassifiable and the safe default is to drop.
///
/// # Performance
///
/// Each call performs O(domains-checked × table-suffix-walk) +
/// O(subject-length × regex-set). Both terms are sub-millisecond on
/// M-series hardware. The pump invokes this once per new emlx file
/// arrival.
#[must_use]
pub fn cascade_equivalent(headers: &ParsedMailHeaders) -> MailCascadeDecision {
    // (1) Fail-safe-unknown for missing From:.
    if headers.from_domain.is_empty() {
        return MailCascadeDecision::Refuse {
            reason: MailRedactionReason::UnparseableEnvelope,
        };
    }

    // (2) Sensitive-domain check across From / Reply-To / Sender /
    //     List-ID. First hit wins; the priority order — From first,
    //     then Reply-To, then Sender, then List-ID — keeps the
    //     audit row's `sender_domain` field stable across the
    //     phishing-shape memo §11 Q4 (Reply-To: bank, From: friendly)
    //     vs the bank-statement (From: bank, no Reply-To override).
    let candidates: [(Option<&str>, &str); 4] = [
        (Some(headers.from_domain.as_str()), "from"),
        (headers.reply_to_domain.as_deref(), "reply-to"),
        (headers.sender_domain.as_deref(), "sender"),
        (headers.list_id_domain.as_deref(), "list-id"),
    ];
    for (maybe_domain, _label) in candidates {
        if let Some(d) = maybe_domain {
            if !d.is_empty() && sensitive_domains::matches_sensitive_domain(d) {
                return MailCascadeDecision::HeaderOnly {
                    sender_domain: d.to_ascii_lowercase(),
                    reason: MailRedactionReason::SensitiveSenderDomain,
                };
            }
        }
    }

    // (3) Subject-line SMS-shape check. Even when no sender domain
    //     fires, an OTP-shape subject is enough to drop. The
    //     categorical From: is preserved so the audit row is not
    //     orphaned.
    if !headers.subject.is_empty() {
        let r = sms_otp::redact_sms_shapes(&headers.subject);
        if r.matched() {
            return MailCascadeDecision::HeaderOnly {
                sender_domain: headers.from_domain.to_ascii_lowercase(),
                reason: MailRedactionReason::SubjectOtpShape,
            };
        }
    }

    MailCascadeDecision::Allow
}

/// Convenience: convert [`ParsedMailHeaders`] into the §3(c)
/// (rendered-OCR-line) [`MailHeaders`] shape so callers that already
/// hold the typed-header view can also exercise the §3(c) module's
/// `should_drop_mail_frame` for parity testing in the corpus harness.
/// Production wiring does NOT cross-call; this helper exists so the
/// corpus can prove both arms agree on the H1 / H2 fixtures.
#[must_use]
pub fn to_mail_headers(p: &ParsedMailHeaders) -> MailHeaders {
    MailHeaders {
        from_domain: p.from_domain.clone(),
        list_id: p.list_id_domain.clone(),
        subject: p.subject.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(from: &str, subject: &str) -> ParsedMailHeaders {
        ParsedMailHeaders {
            from_domain: from.to_owned(),
            reply_to_domain: None,
            sender_domain: None,
            list_id_domain: None,
            subject: subject.to_owned(),
        }
    }

    // -----------------------------------------------------------
    // H1-class — bank sender → DROP (HeaderOnly)
    // -----------------------------------------------------------

    #[test]
    fn h1_bank_from_domain_drops_to_header_only() {
        let h = headers("chase.com", "Statement available");
        match cascade_equivalent(&h) {
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => {
                assert_eq!(sender_domain, "chase.com");
                assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
            }
            other => panic!("expected HeaderOnly, got {other:?}"),
        }
    }

    #[test]
    fn h1_bofa_subdomain_drops_to_header_only() {
        let h = headers("alerts.bankofamerica.com", "Important account notice");
        let d = cascade_equivalent(&h);
        assert!(
            matches!(
                d,
                MailCascadeDecision::HeaderOnly {
                    reason: MailRedactionReason::SensitiveSenderDomain,
                    ..
                }
            ),
            "expected HeaderOnly/SensitiveSenderDomain; got {d:?}"
        );
    }

    #[test]
    fn h1_fintech_paypal_drops() {
        let h = headers("paypal.com", "Receipt for your payment");
        assert!(matches!(
            cascade_equivalent(&h),
            MailCascadeDecision::HeaderOnly {
                reason: MailRedactionReason::SensitiveSenderDomain,
                ..
            }
        ));
    }

    // -----------------------------------------------------------
    // H2-class — non-sensitive sender → ALLOW
    // -----------------------------------------------------------

    #[test]
    fn h2_unknown_domain_safe_subject_allows() {
        let h = headers("newsletter.example.com", "Today's headlines");
        assert_eq!(cascade_equivalent(&h), MailCascadeDecision::Allow);
    }

    #[test]
    fn h2_friend_personal_mail_allows() {
        let h = headers("personal.example.org", "Sprint kickoff notes");
        assert_eq!(cascade_equivalent(&h), MailCascadeDecision::Allow);
    }

    #[test]
    fn h2_substring_only_chase_in_domain_allows() {
        // Right-anchored domain match — "notchase.com" is NOT chase.com.
        let h = headers("notchase.com", "Daily digest");
        assert_eq!(cascade_equivalent(&h), MailCascadeDecision::Allow);
    }

    // -----------------------------------------------------------
    // H3-class — SMS-OTP shape in subject → HeaderOnly
    // -----------------------------------------------------------

    #[test]
    fn h3_subject_otp_shape_drops_even_with_unknown_sender() {
        let h = headers("newsletter.example.com", "Your verification code is 482917");
        match cascade_equivalent(&h) {
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => {
                assert_eq!(sender_domain, "newsletter.example.com");
                assert_eq!(reason, MailRedactionReason::SubjectOtpShape);
            }
            other => panic!("expected HeaderOnly/SubjectOtpShape; got {other:?}"),
        }
    }

    #[test]
    fn h3_google_g_prefix_subject_drops() {
        let h = headers("notify.example.com", "G-018472 is your Google verification code");
        assert!(matches!(
            cascade_equivalent(&h),
            MailCascadeDecision::HeaderOnly {
                reason: MailRedactionReason::SubjectOtpShape,
                ..
            }
        ));
    }

    // -----------------------------------------------------------
    // H4-class — no parseable From: → Refuse (fail-safe)
    // -----------------------------------------------------------

    #[test]
    fn h4_empty_from_domain_refuses() {
        let h = headers("", "Anything at all here");
        assert_eq!(
            cascade_equivalent(&h),
            MailCascadeDecision::Refuse {
                reason: MailRedactionReason::UnparseableEnvelope
            }
        );
    }

    #[test]
    fn h4_empty_from_with_otp_subject_still_refuses() {
        // Fail-safe before any other arm fires — the parsed-header
        // path cannot positively classify a mail without a sender.
        let h = headers("", "Your verification code is 555000");
        assert_eq!(
            cascade_equivalent(&h),
            MailCascadeDecision::Refuse {
                reason: MailRedactionReason::UnparseableEnvelope
            }
        );
    }

    // -----------------------------------------------------------
    // H5-class — list-id matches sensitive table → HeaderOnly
    // -----------------------------------------------------------

    #[test]
    fn h5_list_id_chase_drops_to_header_only() {
        let h = ParsedMailHeaders {
            from_domain: "marketing.example.org".into(),
            reply_to_domain: None,
            sender_domain: None,
            list_id_domain: Some("chase.com".into()),
            subject: "Statement available".into(),
        };
        match cascade_equivalent(&h) {
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => {
                assert_eq!(sender_domain, "chase.com");
                assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
            }
            other => panic!("expected HeaderOnly/SensitiveSenderDomain via list-id; got {other:?}"),
        }
    }

    // -----------------------------------------------------------
    // Phishing-shape memo §11 Q4 — Reply-To bank, From friendly
    // -----------------------------------------------------------

    #[test]
    fn reply_to_bank_with_friendly_from_drops() {
        let h = ParsedMailHeaders {
            from_domain: "notify.example.com".into(),
            reply_to_domain: Some("chase.com".into()),
            sender_domain: None,
            list_id_domain: None,
            subject: "Reset your account".into(),
        };
        match cascade_equivalent(&h) {
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => {
                assert_eq!(sender_domain, "chase.com");
                assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
            }
            other => panic!("expected HeaderOnly via Reply-To; got {other:?}"),
        }
    }

    #[test]
    fn sender_header_bank_with_friendly_from_drops() {
        let h = ParsedMailHeaders {
            from_domain: "notify.example.com".into(),
            reply_to_domain: None,
            sender_domain: Some("chase.com".into()),
            list_id_domain: None,
            subject: "Reset your account".into(),
        };
        assert!(matches!(
            cascade_equivalent(&h),
            MailCascadeDecision::HeaderOnly {
                reason: MailRedactionReason::SensitiveSenderDomain,
                ..
            }
        ));
    }

    // -----------------------------------------------------------
    // Case-insensitivity (header eTLD+1 may not be pre-lowercased)
    // -----------------------------------------------------------

    #[test]
    fn upper_case_bank_domain_drops_to_lowercased_sender() {
        let h = headers("CHASE.COM", "Statement");
        match cascade_equivalent(&h) {
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => {
                assert_eq!(sender_domain, "chase.com", "lowercased on output");
                assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
            }
            other => panic!("expected HeaderOnly; got {other:?}"),
        }
    }

    // -----------------------------------------------------------
    // Telemetry strings are stable + content-free
    // -----------------------------------------------------------

    #[test]
    fn reason_strings_are_stable_kebab_case() {
        assert_eq!(
            MailRedactionReason::SensitiveSenderDomain.as_str(),
            "mail-header-match:sensitive-sender-domain"
        );
        assert_eq!(
            MailRedactionReason::SubjectOtpShape.as_str(),
            "mail-header-match:subject-otp-shape"
        );
        assert_eq!(
            MailRedactionReason::UnparseableEnvelope.as_str(),
            "mail-header-match:unparseable-envelope"
        );
    }

    #[test]
    fn tombstone_reason_collapses_to_one_class() {
        for r in [
            MailRedactionReason::SensitiveSenderDomain,
            MailRedactionReason::SubjectOtpShape,
            MailRedactionReason::UnparseableEnvelope,
        ] {
            assert_eq!(r.tombstone_reason(), "mail-header-match");
        }
    }

    #[test]
    fn to_mail_headers_round_trips_relevant_fields() {
        let p = ParsedMailHeaders {
            from_domain: "chase.com".into(),
            reply_to_domain: Some("ignored.example.com".into()),
            sender_domain: None,
            list_id_domain: Some("listy.example.com".into()),
            subject: "Statement available".into(),
        };
        let m = to_mail_headers(&p);
        assert_eq!(m.from_domain, "chase.com");
        assert_eq!(m.subject, "Statement available");
        assert_eq!(m.list_id.as_deref(), Some("listy.example.com"));
    }
}
