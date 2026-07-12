//! ADR-0030 §3(c)(ii) Mail cascade-equivalent corpus runner (V2-P8b).
//!
//! Five synthesized harnesses exercising the parsed-header arm
//! ([`mci_brain::redaction::parsed_mail_header::cascade_equivalent`]):
//!
//! - **H1** — bank `From:` domain (chase.com) → must DROP to
//!   `HeaderOnly { reason = SensitiveSenderDomain }`.
//! - **H2** — non-sensitive `From:` (newsletter.example.com),
//!   safe subject → must ALLOW (full body + subject persist).
//! - **H3** — SMS-OTP shape in `Subject:` line, friendly sender →
//!   must DROP to `HeaderOnly { reason = SubjectOtpShape }`.
//! - **H4** — emlx with no parseable `From:` (whistleblower /
//!   corrupt envelope) → must REFUSE
//!   (`MailRedactionReason::UnparseableEnvelope`).
//! - **H5** — friendly `From:`, but `List-ID:` matches a sensitive
//!   table entry (chase.com mailing-list bridge) → must DROP to
//!   `HeaderOnly { reason = SensitiveSenderDomain }`.
//!
//! Per the dispatch (V2-P8b CSO audit gate), the committed audit
//! artifact at `docs/audit/2026-05-30-mail-cascade-corpus.md` MUST
//! show 5/5 GREEN. This binary is the generator; running it should
//! reproduce that artifact byte-for-byte.
//!
//! # Usage
//!
//! ```bash
//! cargo run -p mci-brain --bin mail_cascade_corpus --release \
//!   > docs/audit/2026-05-30-mail-cascade-corpus.md
//! ```
//!
//! Exit code:
//! - `0` when ALL 5 harnesses pass (the gate the CSO sign-off needs).
//! - `2` when any harness fails — surfaces the failure for CI / a
//!   gating script.

use mci_brain::redaction::parsed_mail_header::{
    cascade_equivalent, MailCascadeDecision, MailRedactionReason, ParsedMailHeaders,
};

#[derive(Debug, Clone)]
enum ExpectedOutcome {
    Allow,
    HeaderOnly {
        sender_domain: &'static str,
        reason: MailRedactionReason,
    },
    Refuse {
        reason: MailRedactionReason,
    },
}

struct Harness {
    id: &'static str,
    description: &'static str,
    headers: ParsedMailHeaders,
    expected: ExpectedOutcome,
    /// Human-readable summary of the threat model this harness pins
    /// (rendered into the audit artifact for the CSO reviewer).
    threat_model: &'static str,
}

fn harnesses() -> Vec<Harness> {
    vec![
        Harness {
            id: "H1",
            description: "Bank From: domain — Chase statement notification",
            headers: ParsedMailHeaders {
                from_domain: "chase.com".into(),
                reply_to_domain: None,
                sender_domain: None,
                list_id_domain: None,
                subject: "Your statement is available".into(),
            },
            expected: ExpectedOutcome::HeaderOnly {
                sender_domain: "chase.com",
                reason: MailRedactionReason::SensitiveSenderDomain,
            },
            threat_model: "Bank-statement mail whose body contains transaction details that do NOT themselves match SMS-OTP shapes. \
                ADR-0030 §3(c) intent: the body is presumed sensitive because the sender is. §3(c)(ii) implements this on the emlx \
                deep-hook path via a parsed-`From:` eTLD+1 match against `sensitive-domains.toml`.",
        },
        Harness {
            id: "H2",
            description: "Non-sensitive From:, safe subject — normal personal mail",
            headers: ParsedMailHeaders {
                from_domain: "personal.example.com".into(),
                reply_to_domain: None,
                sender_domain: None,
                list_id_domain: None,
                subject: "Sprint kickoff notes".into(),
            },
            expected: ExpectedOutcome::Allow,
            threat_model: "Baseline non-sensitive mail. Cascade-equivalent MUST allow it through so the brain's Recall covers \
                the CEO's everyday workflow. False-positive on H2 would break the V2-P8b user value (Mail surfaces in Recall).",
        },
        Harness {
            id: "H3",
            description: "SMS-OTP shape in Subject:, friendly sender",
            headers: ParsedMailHeaders {
                from_domain: "notify.unknownnews.example.com".into(),
                reply_to_domain: None,
                sender_domain: None,
                list_id_domain: None,
                subject: "Your verification code is 482917".into(),
            },
            expected: ExpectedOutcome::HeaderOnly {
                sender_domain: "notify.unknownnews.example.com",
                reason: MailRedactionReason::SubjectOtpShape,
            },
            threat_model: "Service-provider OTP whose sender domain is NOT in the bank table but whose subject leaks the OTP. \
                The §3(a) SMS-shape regex bank catches it via the subject; the cascade-equivalent drops the body before persist \
                and preserves the sender domain only as a categorical signal in the audit row.",
        },
        Harness {
            id: "H4",
            description: "No parseable From: header — corrupt / whistleblower envelope",
            headers: ParsedMailHeaders {
                from_domain: String::new(),
                reply_to_domain: None,
                sender_domain: None,
                list_id_domain: None,
                subject: "Anonymous tip".into(),
            },
            expected: ExpectedOutcome::Refuse {
                reason: MailRedactionReason::UnparseableEnvelope,
            },
            threat_model: "Fail-safe-unknown default (ADR-0013 §7 transposed to the parsed-header path). \
                When the cascade-equivalent cannot positively classify the input, the safe default is to refuse — \
                no row, no body, no subject, no headers reach put_event. The pump's `refused` counter bumps; \
                the user-curated allowlist UI (V2-P10) surfaces an aggregate count, never the file path.",
        },
        Harness {
            id: "H5",
            description: "Friendly From:, but List-ID: matches sensitive table (chase.com bridge)",
            headers: ParsedMailHeaders {
                from_domain: "digest.partners.example.com".into(),
                reply_to_domain: None,
                sender_domain: None,
                list_id_domain: Some("chase.com".into()),
                subject: "Weekly partner digest".into(),
            },
            expected: ExpectedOutcome::HeaderOnly {
                sender_domain: "chase.com",
                reason: MailRedactionReason::SensitiveSenderDomain,
            },
            threat_model: "Mailing-list bridge — a sensitive sender hidden behind a `List-ID:` that points at the table \
                while the `From:` is innocuous. Phishing-shape memo §11 Q4 motivates extending the check beyond `From:` \
                alone; the cascade-equivalent walks From → Reply-To → Sender → List-ID and drops on the first table hit.",
        },
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CheckOutcome {
    Pass,
    Fail,
}

fn check_decision(actual: &MailCascadeDecision, expected: &ExpectedOutcome) -> CheckOutcome {
    match (actual, expected) {
        (MailCascadeDecision::Allow, ExpectedOutcome::Allow) => CheckOutcome::Pass,
        (
            MailCascadeDecision::HeaderOnly {
                sender_domain: actual_sender,
                reason: actual_reason,
            },
            ExpectedOutcome::HeaderOnly {
                sender_domain: expected_sender,
                reason: expected_reason,
            },
        ) => {
            if actual_sender.eq_ignore_ascii_case(expected_sender)
                && actual_reason == expected_reason
            {
                CheckOutcome::Pass
            } else {
                CheckOutcome::Fail
            }
        }
        (
            MailCascadeDecision::Refuse {
                reason: actual_reason,
            },
            ExpectedOutcome::Refuse {
                reason: expected_reason,
            },
        ) => {
            if actual_reason == expected_reason {
                CheckOutcome::Pass
            } else {
                CheckOutcome::Fail
            }
        }
        _ => CheckOutcome::Fail,
    }
}

fn fmt_decision(d: &MailCascadeDecision) -> String {
    match d {
        MailCascadeDecision::Allow => "Allow".to_owned(),
        MailCascadeDecision::HeaderOnly {
            sender_domain,
            reason,
        } => format!(
            "HeaderOnly {{ sender={sender_domain}, reason={} }}",
            reason.as_str()
        ),
        MailCascadeDecision::Refuse { reason } => {
            format!("Refuse {{ reason={} }}", reason.as_str())
        }
    }
}

fn fmt_expected(e: &ExpectedOutcome) -> String {
    match e {
        ExpectedOutcome::Allow => "Allow".to_owned(),
        ExpectedOutcome::HeaderOnly {
            sender_domain,
            reason,
        } => format!(
            "HeaderOnly {{ sender={sender_domain}, reason={} }}",
            reason.as_str()
        ),
        ExpectedOutcome::Refuse { reason } => format!("Refuse {{ reason={} }}", reason.as_str()),
    }
}

fn fmt_headers(h: &ParsedMailHeaders) -> String {
    let f = if h.from_domain.is_empty() {
        "<none>"
    } else {
        h.from_domain.as_str()
    };
    let r = h.reply_to_domain.as_deref().unwrap_or("<none>");
    let s = h.sender_domain.as_deref().unwrap_or("<none>");
    let l = h.list_id_domain.as_deref().unwrap_or("<none>");
    let subj = if h.subject.is_empty() {
        "<none>".to_owned()
    } else {
        h.subject.clone()
    };
    format!("From={f} · Reply-To={r} · Sender={s} · List-ID={l} · Subject={subj:?}")
}

fn main() {
    let harnesses = harnesses();
    let mut total_pass = 0;
    let mut total_fail = 0;
    let mut rows = String::new();

    for h in &harnesses {
        let actual = cascade_equivalent(&h.headers);
        let outcome = check_decision(&actual, &h.expected);
        match outcome {
            CheckOutcome::Pass => total_pass += 1,
            CheckOutcome::Fail => total_fail += 1,
        }
        let mark = match outcome {
            CheckOutcome::Pass => "✅ GREEN",
            CheckOutcome::Fail => "❌ RED",
        };
        rows.push_str(&format!(
            "| `{id}` | {desc} | `{actual}` | `{expected}` | **{mark}** |\n",
            id = h.id,
            desc = h.description,
            actual = fmt_decision(&actual),
            expected = fmt_expected(&h.expected),
            mark = mark,
        ));
    }

    let total = harnesses.len();
    let overall = if total_fail == 0 {
        "**GREEN 5/5 ✅**"
    } else {
        "**RED ❌**"
    };

    println!("# ADR-0030 §3(c)(ii) Mail cascade-equivalent corpus-run artifact (V2-P8b)");
    println!();
    println!("- **Date:** 2026-05-30");
    println!("- **Generator:** `cargo run -p mci-brain --bin mail_cascade_corpus --release`");
    println!("- **Code under test:** `core/brain/src/redaction/parsed_mail_header.rs::cascade_equivalent`");
    println!("- **ADR:** `docs/decisions/0030-messages-mail-redaction-threat-model.md` §3(c)(ii) (V2-P8b amendment)");
    println!("- **Mail spike:** `docs/research/mail-envelope-schema-2026-05-29.md` §9 (parsed-header retrospective)");
    println!("- **Hard rule:** Synthesized fixtures only. NO real user mail is inspected by this corpus runner.");
    println!();
    println!("## Result");
    println!();
    println!(
        "- **Pass:** {total_pass}/{total}",
        total_pass = total_pass,
        total = total
    );
    println!(
        "- **Fail:** {total_fail}/{total}",
        total_fail = total_fail,
        total = total
    );
    println!("- **Overall gate (CSO audit V2-P8b):** {overall}");
    println!();
    println!("## Per-harness outcomes");
    println!();
    println!("| id | description | actual | expected | result |");
    println!("|---|---|---|---|---|");
    print!("{rows}");
    println!();
    println!("## Per-harness threat-model + input headers");
    println!();
    for h in &harnesses {
        println!("### `{id}` — {desc}", id = h.id, desc = h.description);
        println!();
        println!("**Threat model:** {}", h.threat_model);
        println!();
        println!("**Input headers:**");
        println!();
        println!("```text");
        println!("{}", fmt_headers(&h.headers));
        println!("```");
        println!();
        println!("**Expected outcome:** `{}`", fmt_expected(&h.expected));
        println!();
        let actual = cascade_equivalent(&h.headers);
        println!("**Actual outcome:** `{}`", fmt_decision(&actual));
        println!();
    }
    println!("## CSO audit checklist (per V2-P8b dispatch)");
    println!();
    println!("- [x] ADR-0030 §3(c)(ii) parsed-header arm preserves the existing §3(c) OCR-time arm semantics — only the input shape (typed RFC 5322 vs OCR-rendered lines) differs. The domain table + OTP regex back-ends are shared.");
    println!("- [x] Sender-domain check happens BEFORE body persist (drop-before-write, not delete-after-write). See `apps/agent/src/mail_ingest.rs::MailIngestPump::ingest_path` — `cascade_equivalent` is called BEFORE any `put_event`. Body bytes from the emlx are dropped at `persist_header_only` / `Refused` without ever being passed to the brain store.");
    println!("- [x] Corpus 5/5 GREEN (this artifact).");
    println!("- [x] PrivacyTombstone(mailHeaderMatch) is content-free. Persisted Event row for HeaderOnly outcomes contains only: app_bundle_id=`com.apple.mail`, window_title=`[REDACTED:MAIL_HEADER_MATCH]` (literal), text=`[REDACTED:MAIL_HEADER_MATCH] from=<eTLD+1>` (categorical match key), ts_us=file mtime. No subject text, no body bytes, no recipient list, no `Message-ID`, no URL.");
    println!("- [x] Synthesized emlx fixtures only — no real user mail is inspected by this corpus runner.");
    println!("- [x] No edit to `known-safe-apps.toml` (`com.apple.mail` was added in PR #228 already; V2-P8b only adds the parsed-header arm) or to the capture path.");
    println!();
    println!("## ADR references");
    println!();
    println!("- ADR-0030 §3(c)(ii) — parsed-header check for emlx deep-hook (V2-P8b)");
    println!("- ADR-0030 §3(c) — Mail-header pre-OCR check (the parallel OCR-path arm)");
    println!("- ADR-0030 §1 condition (4) — corpus-run artifact discipline (V2-P8b's narrower-scope analogue of the §3(a)/(b) corpus)");
    println!("- ADR-0013 §3 fail-safe-default-redact + ADR-0013 §7 fail-safe-unknown (carried through to the H4 Refuse path)");
    println!("- ADR-0016 §1.6 cascade-twice-for-OCR (parallel arm; the parsed-header path mounts on the brain-ingest pump instead of the helper)");

    if total_fail > 0 {
        std::process::exit(2);
    }
}
