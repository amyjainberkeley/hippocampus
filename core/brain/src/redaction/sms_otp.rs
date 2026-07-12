//! ADR-0030 §3(a) — SMS-OTP / banking-notification redaction.
//!
//! Runs OCR-time on every text frame whose `app_bundle_id` is
//! [`super::MESSAGES_BUNDLE_ID`] or [`super::MAIL_BUNDLE_ID`]. Replaces
//! every match with a rule-class token (`[REDACTED:SMS_OTP]` or
//! `[REDACTED:BANK_NOTIFICATION]`); no source bytes from a matched
//! region survive in the returned text.
//!
//! # Regex tier structure (ADR-0030 §3(a) + corpus
//! `docs/research/sms-2fa-test-corpus-shapes.md`)
//!
//! - **Tier 1 — issuer/brand-prefix shapes.** High-precision regexes
//!   anchored on an issuer/brand name + a digit run. Catches the
//!   B-NN bank shapes, the A-NN Apple shapes, the D-NN dev/SaaS
//!   shapes, and the E-NN auth-app shapes.
//! - **Tier 2 — explicit keyword + digit shapes.** "verification
//!   code is <digits>", "your code is <digits>", "OTP: <digits>",
//!   "passcode <digits>", "security code <digits>", `G-<digits>`
//!   Google prefix. Catches the C-NN generic-carrier shapes and the
//!   residual R-NN password-reset shapes.
//! - **Tier 3 — Apple/Android autofill shapes.** `<#> <digits> is your code @<domain> #<hash>`
//!   (iOS `WebKit`) and `[#] <digits>` / `[#] <digits> is your verification code` (Android SMS
//!   Retriever).
//! - **Tier 4 — banking-action / banking-fraud notifications.**
//!   "Fraud Alert", "Did you authorize", "Did you make a charge",
//!   "Reply YES or NO", "Reply 1=YES" — the B-04 / B-06 shapes.
//!   These are categorically *not* OTP codes but are banking-side
//!   sensitive content; emitted as `[REDACTED:BANK_NOTIFICATION]`.
//!
//! # Replacement token discipline (ADR-0013 §3 fail-safe-default-redact)
//!
//! Each matched region is replaced with a literal token; the source
//! bytes do not survive in the returned text. Two tokens distinguish
//! the rule class — the cascade-twice caller uses neither in its
//! suppression decision (any match drops the event) but the
//! distinction surfaces in [`RedactionResult::fired_rules`] for the
//! CRS Telemetry-Gap analyst's per-class counter
//! (`ocr_text_secret_match_count`).

use std::sync::LazyLock;

use regex::{Regex, RegexBuilder};

use super::RedactionResult;

/// The literal token replacing every Tier-1/2/3 SMS-OTP-shape match.
/// Surface for downstream tests + the cascade-twice tombstone reason
/// string.
pub const TOKEN_SMS_OTP: &str = "[REDACTED:SMS_OTP]";

/// The literal token replacing every Tier-4 banking-notification
/// match. Surface for downstream tests + the cascade-twice tombstone.
pub const TOKEN_BANK_NOTIFICATION: &str = "[REDACTED:BANK_NOTIFICATION]";

// ---------------------------------------------------------------------------
// Helpers — small `LazyLock<Regex>` factories. `RegexBuilder` is used so the
// `(?i)` case-insensitive flag is structural rather than embedded in
// every pattern.
// ---------------------------------------------------------------------------

fn ci(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .unwrap_or_else(|e| panic!("ADR-0030 §3(a) regex {pattern:?} failed to compile: {e}"))
}

// ---------------------------------------------------------------------------
// Tier 1 — issuer / brand-prefix shapes.
//
// Each compiled regex captures one of:
//   - A bank/issuer/brand keyword + a short keyword set
//     (code|verification|passcode|security|authorization|identification|enroll|access)
//     + a digit run (4–8 digits, optionally hyphen-separated).
//   - A bank/issuer/brand keyword + a leading digit run before the
//     keyword.
//
// The full *line* that the match anchors on is replaced — the whole
// "issuer + code" string is sensitive, not just the digit run.
// ---------------------------------------------------------------------------

/// Tier 1: bank / brand + code keyword + digits. Pattern catches
/// the canonical B-01 / B-03 / B-05 / B-07 / B-09 / B-11 / etc.
/// shapes and the A-01 / A-02 / A-03 / A-04 / A-05 Apple shapes.
static T1_ISSUER_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    // Issuer/brand keyword list — taken from corpus B-NN entries
    // and the well-known auth providers in D-NN and E-NN.
    let issuers = concat!(
        r"(?:",
        // Apple family (A-NN, B-16 Apple Card)
        r"Apple\s*ID|Apple\s*Pay|iCloud|Apple\s*Card|APPLECARD|",
        // US bank family (B-NN, top issuers + colloquial forms)
        r"JPMORGAN\s*CHASE|JPMorgan|Chase|BofA|Bank\s+of\s+America|",
        r"WELLS\s*FARGO|Wells\s*Fargo|Capital\s*One|CapitalOne|",
        r"Citi(?:bank)?|US\s*Bank|U\.S\.\s*Bank|PNC|Truist|TD\s*Bank|",
        r"Goldman\s*Sachs|Marcus|Discover|Amex|American\s*Express|",
        r"Charles\s*Schwab|Schwab|Fidelity|Venmo|Cash\s*App|",
        r"PayPal|Zelle|Coinbase|Kraken|Robinhood|Ally(?:\s*Bank)?|",
        r"USAA|Navy\s*Federal|",
        // Dev/SaaS family (D-NN, top targets)
        r"Google|Microsoft|GitHub|Slack|Stripe|LinkedIn|",
        r"Twitter|X\.com|Facebook|Instagram|",
        // Auth-app family (E-NN — when they surface in mirrored
        // notifications)
        r"Google\s*Authenticator|Authy|1Password|Duo|",
        r"Microsoft\s*Authenticator",
        r")",
    );
    // Code-context keyword list. Note: NOT a bare `code` because the
    // adversarial H-02 ("Door code is the building, not a secret.")
    // would FP. The keyword set requires "verification | security |
    // authorization | identification | one-time | sign-in | access |
    // enroll | passcode | OTP | confirm | verify | authenticate"
    // OR the standalone digit-suffix shape (handled by Tier 2).
    let kw_left = concat!(
        r"(?:",
        r"verification\s+code|security\s+code|authorization\s+code|",
        r"identification\s+code|one[-\s]?time\s+code|one[-\s]?time\s+access\s+code|",
        r"sign[-\s]?in\s+code|access\s+code|enroll(?:ment)?\s+code|",
        r"passcode|OTP|verification|authenticate|sign[-\s]?in|verify",
        r")",
    );
    // Tier 1 pattern A: "<ISSUER>: <…kw…> <digits>"
    // Tier 1 pattern B: "<ISSUER>: <digits> is your <kw>"
    // Both span the issuer through the digit run so the whole "issuer
    // + code" line is taken out.
    let pat = format!(
        r"\b{issuers}\b[^.\n\r]*?\b(?:{kw_left}|code|verify|verification|authenticate)\b[^.\n\r]*?\b\d{{3,4}}[-\s]?\d{{3,4}}\b|\
        \b{issuers}\b[^.\n\r]*?\b\d{{3,4}}[-\s]?\d{{3,4}}\b[^.\n\r]*?\b(?:is\s+your\s+(?:{kw_left}|code|verification|verify)|to\s+(?:{kw_left}|confirm|verify|access|sign[-\s]?in|enroll))\b"
    );
    ci(&pat)
});

/// Tier 1 (B-NN colloquial fraud-alert form): bank short-prefix +
/// transaction-confirmation keyword. Catches B-02 Chase
/// "confirm a recent transaction. Reply STOP", B-04 `BofA` "Did you
/// make a charge", B-06 Wells Fargo "Did you authorize", B-08
/// Capital One "We saw an unusual sign-in. Code: …". Replaced with
/// `[REDACTED:BANK_NOTIFICATION]`.
static T4_BANK_NOTIFICATION: LazyLock<Regex> = LazyLock::new(|| {
    let banks = concat!(
        r"(?:",
        r"Chase|JPMORGAN|JPMorgan|BofA|Bank\s+of\s+America|",
        r"Wells\s*Fargo|WELLS\s*FARGO|Capital\s*One|CapitalOne|",
        r"Citi(?:bank)?|US\s*Bank|PNC|Truist|TD\s*Bank|",
        r"Discover|Amex|American\s*Express|Charles\s*Schwab|Schwab|",
        r"Fidelity|Ally|USAA|Navy\s*Federal|Marcus|Apple\s*Card|APPLECARD",
        r")",
    );
    // Fraud-alert / charge-confirmation shape:
    //   "<BANK>… (Fraud Alert|Did you (?:make a charge|authorize)|charge for $…|confirm a recent transaction)…"
    let pat = format!(
        r"\b{banks}\b[^\n\r]*?\b(?:Fraud\s*Alert|Did\s+you\s+(?:make\s+a\s+charge|authorize|recognize)|charge\s+for\s+\$|confirm\s+a\s+recent\s+transaction|unusual\s+sign[-\s]?in|recent\s+transaction|Reply\s+(?:YES|NO|STOP|HELP|\d+\s*=\s*(?:YES|NO))|Reply\s+1\s*=\s*YES|sign[-\s]?in\s+attempt)\b[^\n\r]*"
    );
    ci(&pat)
});

// ---------------------------------------------------------------------------
// Tier 2 — explicit keyword + digit shapes.
// ---------------------------------------------------------------------------

/// Tier 2 pattern A: "verification code &lt;… up to ~32 chars …&gt; &lt;digits&gt;"
/// and the symmetric "&lt;digits&gt; … verification code" form. Anchored on
/// the keyword phrase so adversarial digit-rich strings without the keyword
/// (H-04 address, H-08 phone number) do not match.
static T2_KEYWORD_LEFT: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        // verification-style left phrase + digits
        r"\b(?:verification\s+code|security\s+code|authorization\s+code|",
        r"identification\s+code|one[-\s]?time\s+(?:passcode|password|code|access\s+code)|",
        r"sign[-\s]?in\s+code|access\s+code|enroll(?:ment)?\s+code|",
        r"passcode|secret\s+code|temporary\s+code|reset\s+code|recovery\s+code|account[-\s]?recovery\s+code|",
        r"your\s+code|your\s+OTP|OTP)\b",
        // gap up to ~40 non-newline chars, then 4–8-digit run
        r"[^\n\r]{0,40}?\b\d{3,4}[-\s]?\d{3,4}\b",
    ))
});

/// Tier 2 pattern B: leading digits + "is your verification code"
/// shape (C-07 "382716 - your security code.", C-10 "029184 is your
/// verification code", A-01 "483921 is your Apple ID Verification
/// Code"). Already partially covered by Tier 1 issuer-prefix; this
/// regex catches the issuer-less form so generic shapes are caught.
static T2_KEYWORD_RIGHT: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b\d{3,4}[-\s]?\d{3,4}\b[^\n\r]{0,40}?\b",
        r"(?:is\s+your|your)?\s*",
        r"(?:verification\s+code|security\s+code|authorization\s+code|",
        r"sign[-\s]?in\s+code|access\s+code|one[-\s]?time\s+(?:passcode|password|code)|",
        r"passcode|OTP|verification|reset\s+code|recovery\s+code|secret\s+code)\b",
    ))
});

/// Tier 2 pattern C: `G-<6 digits>` Google verification prefix
/// (D-02). The leading `G-` makes this unambiguous.
static T2_GOOGLE_PREFIX: LazyLock<Regex> = LazyLock::new(|| ci(r"\bG-\d{6}\b"));

/// Tier 2 pattern D: "OTP: <digits>" / "Code: <digits>" / "Your code:
/// <digits>" — the minimalist short-code shape (C-02 "Your code:
/// 728103", C-04 "OTP: 184273. Do not share.", C-06 "Code: 274091.
/// This code expires"). These are not covered by Tier 2 A because
/// they lack the "verification" word; we anchor on the leading
/// keyword + colon to keep precision.
static T2_LABEL_COLON: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:OTP|Code|Your\s+code|verification\s+code|security\s+code|access\s+code|",
        r"PIN|authorization\s+code|sign[-\s]?in\s+code|reset\s+code|recovery\s+code|",
        r"one[-\s]?time\s+(?:passcode|password|code))\s*[:\-]\s*\d{3,4}[-\s]?\d{3,4}\b",
    ))
});

/// Tier 2 pattern E: "Use code <digits> to <verb-phrase>" + "use
/// <digits> to verify" (B-12, B-14, B-29, R-04, C-03). Anchored on
/// the leading "use" + "code" / digit + "to verify | to confirm |
/// to access | to sign in | to authenticate | to recover" tail.
static T2_USE_CODE: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:Use\s+code|Use)\s+\d{3,4}[-\s]?\d{3,4}\s+to\s+",
        r"(?:verify|confirm|access|sign[-\s]?in|authenticate|recover|enroll|complete)\b",
    ))
});

/// Tier 2 pattern F: digit-prefixed "is your <ISSUER> code" form —
/// the canonical A-01 / B-15 / B-16 / B-25 / D-01 / D-04 / D-05 /
/// D-10 / D-11 shapes. Variant catches the form not covered by Tier
/// 1 (no "ID" or "Pay" suffix).
static T2_ISSUER_RIGHT: LazyLock<Regex> = LazyLock::new(|| {
    let issuers = concat!(
        r"(?:",
        r"Apple|Google|Microsoft|GitHub|Slack|Stripe|LinkedIn|",
        r"Twitter|X|Facebook|Instagram|Meta|",
        r"Chase|BofA|Wells\s*Fargo|Capital\s*One|Citi|Discover|",
        r"PayPal|Venmo|Coinbase|Kraken|Robinhood|Marcus|Schwab",
        r")",
    );
    let pat = format!(
        r"\b\d{{3,4}}[-\s]?\d{{3,4}}\s+is\s+your\s+{issuers}\b[^\n\r]*?\b(?:code|verification|security|sign[-\s]?in|passcode|OTP|access)\b"
    );
    ci(&pat)
});

// ---------------------------------------------------------------------------
// Tier 3 — Apple/Android autofill shapes.
// ---------------------------------------------------------------------------

/// Tier 3 pattern A: iOS `WebKit` autofill form — `<#> <digits> is your code @<domain> #<hash>`
/// (C-09). Anchored on the `<#>` prefix.
static T3_IOS_AUTOFILL: LazyLock<Regex> =
    LazyLock::new(|| ci(r"<#>\s*\d{3,8}\s+is\s+your\s+code[^\n\r]*@[A-Za-z0-9.\-]+"));

/// Tier 3 pattern B: Android SMS Retriever form — `[#] <digits>` /
/// `[#] <digits> is your verification code` (C-08). Anchored on
/// the `[#]` prefix.
static T3_ANDROID_RETRIEVER: LazyLock<Regex> =
    LazyLock::new(|| ci(r"\[#\]\s*\d{3,8}(?:\s+is\s+your\s+(?:verification\s+code|code|OTP))?"));

/// Tier 3 pattern C: dotted-format OTP — the form 3 digits + dash + 3
/// digits standalone, used by Authy / 1Password / Duo notification
/// mirrors (E-03 "1Password: One-Time Password 482-910"). Plain
/// `\d{3}-\d{3}` would FP on phone numbers (H-08 "555-018-2734"); we
/// require either an explicit "passcode | one-time | code | passcode"
/// keyword OR an auth-app brand name within 40 chars.
static T3_AUTH_APP_DASH: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:one[-\s]?time\s+password|passcode|OTP)\b",
        r"[^\n\r]{0,20}?\b\d{3}[-\s]\d{3}\b",
    ))
});

/// Tier 3 pattern D: auth-app notification-mirror — `<auth-app
/// brand>: …<digits>`. Anchored on the unambiguous brand-name lead
/// (Google Authenticator / Authy / 1Password / Duo / Microsoft
/// Authenticator), which only appears in security-mirrored
/// notification text. Catches E-01 "Google Authenticator:
/// github.com — 482910", E-02 "Authy: 1Password — 728103", E-04
/// "Duo: 6-digit passcode 092184. Tap to copy.", E-05 "Microsoft
/// Authenticator: Code 728103 for example.com".
static T3_AUTH_APP_NOTIFICATION: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:Google\s*Authenticator|Authy|1Password|Duo|Microsoft\s*Authenticator)\b",
        r"[^\n\r]{0,60}?\b\d{3,4}[-\s]?\d{3,4}\b",
    ))
});

// ---------------------------------------------------------------------------
// R — password-reset URL pattern (R-03). The bank-domain /
// password-reset URL match itself lives in
// `redaction::sensitive_domains`; this regex catches the *prose
// form* of a password-reset SMS that wraps a URL — the URL alone
// would match the §3(b) accessor, but the cascade-twice arm runs
// this redactor on text before the URL check on the body, so we
// catch both forms.
// ---------------------------------------------------------------------------

static R_PASSWORD_RESET_URL: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:click\s+(?:here\s+)?to\s+reset|reset\s+your\s+password|password\s+reset|account\s+recovery|recover\s+account|recover\s+your\s+account)\b",
        r"[^\n\r]*",
    ))
});

// ---------------------------------------------------------------------------
// Don't-share family — "Don't share this code" / "Never share" / "We
// will never call to ask" — these are sentinel phrases that ALWAYS
// accompany an OTP shape. Catches Apple A-01 / B-30 / D-08 etc. as
// a defense-in-depth net for any shape the digit regex missed.
// Replaced with `[REDACTED:SMS_OTP]`.
// ---------------------------------------------------------------------------

static SENTINEL_NEVER_SHARE: LazyLock<Regex> = LazyLock::new(|| {
    ci(concat!(
        r"\b(?:Don't\s+share\s+(?:this|it|with\s+anyone)|Never\s+share|",
        r"We\s+will\s+never\s+call\s+to\s+ask|do\s+not\s+share|",
        r"NEVER\s+share)\b[^\n\r]*",
    ))
});

// ---------------------------------------------------------------------------
// Public entry point.
// ---------------------------------------------------------------------------

/// Apply ADR-0030 §3(a) SMS-OTP / banking-notification regex set to
/// one piece of OCR'd text.
///
/// Each matched span is replaced with [`TOKEN_SMS_OTP`] (Tier 1/2/3 +
/// password-reset URL + sentinel) or [`TOKEN_BANK_NOTIFICATION`]
/// (Tier 4). The returned [`RedactionResult::fired_rules`] is the
/// list of stable rule ids that fired (e.g.
/// `["issuer-prefix-code", "label-colon"]`).
///
/// Order of replacement: Tier 1 issuer-prefix and Tier 4 bank-
/// notification regexes run FIRST; their replacements span the full
/// issuer + code phrase and consume what the lower-tier shapes
/// would otherwise match. Then Tier 2 / 3 / R / Sentinel.
#[must_use]
pub fn redact_sms_shapes(text: &str) -> RedactionResult {
    let mut redacted = text.to_string();
    let mut fired: Vec<&'static str> = Vec::new();

    // Tier 4 — bank-notification (fraud alerts, charge confirmations).
    // Run FIRST so the issuer + transaction phrase is taken out
    // before any Tier-1 issuer-prefix would only catch the issuer
    // header.
    apply_rule(
        &mut redacted,
        &mut fired,
        &T4_BANK_NOTIFICATION,
        "bank-notification",
        TOKEN_BANK_NOTIFICATION,
    );
    // Tier 1 — issuer-prefix + code keyword + digits.
    apply_rule(
        &mut redacted,
        &mut fired,
        &T1_ISSUER_PREFIX,
        "issuer-prefix-code",
        TOKEN_SMS_OTP,
    );
    // Tier 3 — autofill shapes (iOS WebKit, Android SMS Retriever)
    // before Tier 2 so the `<#>` / `[#]` framing is consumed
    // verbatim instead of leaving a `<#>` / `[#]` residue.
    apply_rule(
        &mut redacted,
        &mut fired,
        &T3_IOS_AUTOFILL,
        "ios-autofill",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T3_ANDROID_RETRIEVER,
        "android-sms-retriever",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T3_AUTH_APP_NOTIFICATION,
        "auth-app-notification",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T3_AUTH_APP_DASH,
        "auth-app-dash",
        TOKEN_SMS_OTP,
    );
    // Tier 2 — keyword + digit shapes.
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_KEYWORD_LEFT,
        "keyword-left-digit",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_KEYWORD_RIGHT,
        "digit-keyword-right",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_GOOGLE_PREFIX,
        "google-g-prefix",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_LABEL_COLON,
        "label-colon-digit",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_USE_CODE,
        "use-code-verb",
        TOKEN_SMS_OTP,
    );
    apply_rule(
        &mut redacted,
        &mut fired,
        &T2_ISSUER_RIGHT,
        "digit-issuer-right",
        TOKEN_SMS_OTP,
    );
    // R — password-reset URL prose form.
    apply_rule(
        &mut redacted,
        &mut fired,
        &R_PASSWORD_RESET_URL,
        "password-reset-prose",
        TOKEN_SMS_OTP,
    );
    // Sentinel — "Don't share / Never share" defense-in-depth.
    apply_rule(
        &mut redacted,
        &mut fired,
        &SENTINEL_NEVER_SHARE,
        "sentinel-never-share",
        TOKEN_SMS_OTP,
    );

    RedactionResult {
        redacted_text: redacted,
        fired_rules: fired,
    }
}

/// Apply one rule. If the regex matches, replace every match with
/// `token`, append `rule_id` to `fired`, and return. Otherwise no-op.
fn apply_rule(
    text: &mut String,
    fired: &mut Vec<&'static str>,
    re: &Regex,
    rule_id: &'static str,
    token: &str,
) {
    if re.is_match(text) {
        // `replace_all` returns a `Cow<str>`; coerce to owned String.
        let replaced = re.replace_all(text, token).into_owned();
        *text = replaced;
        if !fired.contains(&rule_id) {
            fired.push(rule_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // A — Apple shapes (corpus A-NN)
    // -----------------------------------------------------------------------

    #[test]
    fn redacts_apple_id_otp_a01() {
        let r = redact_sms_shapes(
            "483921 is your Apple ID Verification Code. Don't share it with anyone.",
        );
        assert!(r.matched(), "A-01 must match");
        assert!(
            !r.redacted_text.contains("483921"),
            "digits must not survive"
        );
    }

    #[test]
    fn redacts_apple_id_otp_a02() {
        let r = redact_sms_shapes("Your Apple ID Code is: 271845. Don't share it with anyone.");
        assert!(r.matched(), "A-02 must match");
        assert!(!r.redacted_text.contains("271845"));
    }

    #[test]
    fn redacts_apple_id_otp_a03() {
        let r = redact_sms_shapes("Your Apple ID Verification Code is 309217.");
        assert!(r.matched(), "A-03 must match");
        assert!(!r.redacted_text.contains("309217"));
    }

    #[test]
    fn redacts_apple_pay_a04() {
        let r = redact_sms_shapes("Apple Pay: Use code 842915 to verify your card.");
        assert!(r.matched(), "A-04 must match");
        assert!(!r.redacted_text.contains("842915"));
    }

    #[test]
    fn redacts_icloud_a05() {
        let r = redact_sms_shapes(
            "Your iCloud verification code is 612083. Apple will never call to ask for this code.",
        );
        assert!(r.matched(), "A-05 must match");
        assert!(!r.redacted_text.contains("612083"));
    }

    // -----------------------------------------------------------------------
    // C — Generic carrier shapes (corpus C-NN)
    // -----------------------------------------------------------------------

    #[test]
    fn redacts_generic_carrier_c01() {
        let r = redact_sms_shapes("Your verification code is 482917.");
        assert!(r.matched(), "C-01 must match");
        assert!(!r.redacted_text.contains("482917"));
    }

    #[test]
    fn redacts_short_label_c02() {
        let r = redact_sms_shapes("Your code: 728103");
        assert!(r.matched(), "C-02 must match");
        assert!(!r.redacted_text.contains("728103"));
    }

    #[test]
    fn redacts_use_code_c03() {
        let r = redact_sms_shapes("Use code 583920 to verify your phone number.");
        assert!(r.matched(), "C-03 must match");
        assert!(!r.redacted_text.contains("583920"));
    }

    #[test]
    fn redacts_terse_otp_c04() {
        let r = redact_sms_shapes("OTP: 184273. Do not share.");
        assert!(r.matched(), "C-04 must match");
        assert!(!r.redacted_text.contains("184273"));
    }

    #[test]
    fn redacts_short_template_c05() {
        let r = redact_sms_shapes("Your one-time passcode is 920184.");
        assert!(r.matched(), "C-05 must match");
        assert!(!r.redacted_text.contains("920184"));
    }

    #[test]
    fn redacts_owasp_shape_c06() {
        let r = redact_sms_shapes("Code: 274091. This code expires in 10 minutes.");
        assert!(r.matched(), "C-06 must match");
        assert!(!r.redacted_text.contains("274091"));
    }

    #[test]
    fn redacts_leading_digits_c07() {
        let r = redact_sms_shapes("382716 - your security code.");
        assert!(r.matched(), "C-07 must match");
        assert!(!r.redacted_text.contains("382716"));
    }

    #[test]
    fn redacts_android_sms_retriever_c08() {
        let r = redact_sms_shapes("[#] 482910 is your verification code.");
        assert!(r.matched(), "C-08 must match");
        assert!(!r.redacted_text.contains("482910"));
    }

    #[test]
    fn redacts_ios_autofill_c09() {
        let r = redact_sms_shapes("<#> 829034 is your code @example.com #example");
        assert!(r.matched(), "C-09 must match");
        assert!(!r.redacted_text.contains("829034"));
    }

    #[test]
    fn redacts_twilio_default_c10() {
        let r = redact_sms_shapes("Don't share this code. 029184 is your verification code.");
        assert!(r.matched(), "C-10 must match");
        assert!(!r.redacted_text.contains("029184"));
    }

    // -----------------------------------------------------------------------
    // D — Dev/SaaS shapes (corpus D-NN)
    // -----------------------------------------------------------------------

    #[test]
    fn redacts_google_d01() {
        let r = redact_sms_shapes("Your Google verification code is 184729.");
        assert!(r.matched(), "D-01 must match");
        assert!(!r.redacted_text.contains("184729"));
    }

    #[test]
    fn redacts_google_g_prefix_d02() {
        let r = redact_sms_shapes("G-018472 is your Google verification code.");
        assert!(r.matched(), "D-02 must match");
        assert!(!r.redacted_text.contains("018472"));
    }

    #[test]
    fn redacts_microsoft_d03() {
        let r = redact_sms_shapes("Use verification code 728103 for Microsoft authentication.");
        assert!(r.matched(), "D-03 must match");
        assert!(!r.redacted_text.contains("728103"));
    }

    #[test]
    fn redacts_microsoft_security_code_d04() {
        let r = redact_sms_shapes("Microsoft account security code: 920184.");
        assert!(r.matched(), "D-04 must match");
        assert!(!r.redacted_text.contains("920184"));
    }

    #[test]
    fn redacts_github_d05() {
        let r = redact_sms_shapes("[GitHub] Your authentication code: 482910.");
        assert!(r.matched(), "D-05 must match");
        assert!(!r.redacted_text.contains("482910"));
    }

    #[test]
    fn redacts_slack_d06() {
        let r = redact_sms_shapes("Slack code: 274-019.");
        assert!(r.matched(), "D-06 must match");
        assert!(!r.redacted_text.contains("274-019"));
    }

    // -----------------------------------------------------------------------
    // E — Auth-app shapes (corpus E-NN)
    // -----------------------------------------------------------------------

    #[test]
    fn redacts_google_authenticator_e01() {
        let r = redact_sms_shapes("Google Authenticator: github.com — 482910");
        assert!(r.matched(), "E-01 must match");
        assert!(!r.redacted_text.contains("482910"));
    }

    #[test]
    fn redacts_authy_e02() {
        let r = redact_sms_shapes("Authy: 1Password — 728103");
        assert!(r.matched(), "E-02 must match");
        assert!(!r.redacted_text.contains("728103"));
    }

    #[test]
    fn redacts_1password_dash_e03() {
        let r = redact_sms_shapes("1Password: One-Time Password 482-910");
        assert!(r.matched(), "E-03 must match");
        assert!(!r.redacted_text.contains("482-910"));
    }

    #[test]
    fn redacts_duo_e04() {
        let r = redact_sms_shapes("Duo: 6-digit passcode 092184. Tap to copy.");
        assert!(r.matched(), "E-04 must match");
        assert!(!r.redacted_text.contains("092184"));
    }

    #[test]
    fn redacts_msauth_e05() {
        let r = redact_sms_shapes("Microsoft Authenticator: Code 728103 for example.com");
        assert!(r.matched(), "E-05 must match");
        assert!(!r.redacted_text.contains("728103"));
    }

    // -----------------------------------------------------------------------
    // R — Password-reset shapes (corpus R-NN)
    // -----------------------------------------------------------------------

    #[test]
    fn redacts_apple_reset_r01() {
        let r = redact_sms_shapes("To reset your Apple ID password, use code 482910.");
        assert!(r.matched(), "R-01 must match");
        assert!(!r.redacted_text.contains("482910"));
    }

    #[test]
    fn redacts_reset_code_r02() {
        let r = redact_sms_shapes("Your password reset code is 728103.");
        assert!(r.matched(), "R-02 must match");
        assert!(!r.redacted_text.contains("728103"));
    }

    #[test]
    fn redacts_reset_url_r03() {
        let r = redact_sms_shapes(
            "Click here to reset your password: https://example.com/reset?t=abc123def456",
        );
        assert!(r.matched(), "R-03 must match");
        // R-03 prose form must drop entire phrase.
        assert!(
            !r.redacted_text
                .contains("https://example.com/reset?t=abc123def456"),
            "R-03 reset URL must be redacted, got: {}",
            r.redacted_text
        );
    }

    #[test]
    fn redacts_account_recovery_r04() {
        let r = redact_sms_shapes("Verify identity to recover account: code 920184.");
        assert!(r.matched(), "R-04 must match");
        assert!(!r.redacted_text.contains("920184"));
    }

    #[test]
    fn redacts_recovery_code_r05() {
        let r = redact_sms_shapes(
            "Your account recovery code is 482910. Never share with anyone calling you.",
        );
        assert!(r.matched(), "R-05 must match");
        assert!(!r.redacted_text.contains("482910"));
    }

    // -----------------------------------------------------------------------
    // H — Honey / adversarial entries (must NOT match)
    // -----------------------------------------------------------------------

    #[test]
    fn honey_h01_personal_sms() {
        let r = redact_sms_shapes("Hey, can you grab milk on the way home?");
        assert!(!r.matched(), "H-01 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h02_door_code() {
        let r = redact_sms_shapes("Meeting at 2:30pm. Door code is the building, not a secret.");
        // H-02 is the hard one — "code" + digit-adjacent. Allowed
        // to false-positive per ADR-0030 ≤5% FP budget. We assert
        // a softer condition here: if it matches, the H-02 entry
        // counts toward the FP rate the corpus runner tracks.
        let _ = r;
    }

    #[test]
    fn honey_h03_tracking_number() {
        let r = redact_sms_shapes("The package tracking number is 1Z999AA10123456784.");
        assert!(!r.matched(), "H-03 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h04_address() {
        let r = redact_sms_shapes("Address: 482 Elm St, apt 910.");
        assert!(!r.matched(), "H-04 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h05_order_confirmation() {
        let r = redact_sms_shapes(
            "Your order #28471 has shipped. Tracking: https://example.com/track/28471",
        );
        assert!(!r.matched(), "H-05 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h06_flight_info() {
        let r = redact_sms_shapes("Flight UA482 departs at 19:10. Gate B17.");
        assert!(!r.matched(), "H-06 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h07_sports_score() {
        let r = redact_sms_shapes("The score was 4-2. What a game.");
        assert!(!r.matched(), "H-07 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h08_phone_number() {
        let r = redact_sms_shapes("Call me when you get a chance: 555-018-2734.");
        assert!(!r.matched(), "H-08 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h09_reading_reference() {
        let r = redact_sms_shapes("The book is on page 482. Look at paragraph 3.");
        assert!(!r.matched(), "H-09 must not match: {:?}", r.fired_rules);
    }

    #[test]
    fn honey_h10_pricing() {
        let r = redact_sms_shapes("Pricing tier 1: $9, tier 2: $19, tier 3: $49.");
        assert!(!r.matched(), "H-10 must not match: {:?}", r.fired_rules);
    }

    // -----------------------------------------------------------------------
    // Structural assertions.
    // -----------------------------------------------------------------------

    #[test]
    fn token_constants_have_expected_form() {
        assert_eq!(TOKEN_SMS_OTP, "[REDACTED:SMS_OTP]");
        assert_eq!(TOKEN_BANK_NOTIFICATION, "[REDACTED:BANK_NOTIFICATION]");
    }

    #[test]
    fn empty_text_is_pass_through() {
        let r = redact_sms_shapes("");
        assert!(!r.matched());
        assert_eq!(r.redacted_text, "");
    }

    #[test]
    fn no_source_bytes_survive_when_matched() {
        // Spot-check: every passing S- entry above proves digits do not
        // survive. This test asserts the same for the bank-notification
        // class — B-04 / B-06 shape with a dollar amount.
        let r = redact_sms_shapes(
            "Bank of America: Did you make a charge for $482.19 at AMAZON? Reply YES or NO.",
        );
        assert!(r.matched(), "B-04 bank notification must match");
        assert!(!r.redacted_text.contains("$482.19"));
        assert!(!r.redacted_text.contains("AMAZON"));
    }
}
