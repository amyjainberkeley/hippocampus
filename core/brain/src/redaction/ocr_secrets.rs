//! The secret checks every source passes before anything is stored, and the
//! scrub every way out applies: the capture helper's regex patterns, copied
//! verbatim, plus the two detectors a plain regex cannot express: credit-card
//! numbers (Luhn) and one-time codes (a keyword nearby).
//!
//! `SuppressionCascade.containsSecretOrPII`
//! (`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift`)
//! refuses to store any OCR text, window title or address one of these
//! matches. The agent runs [`contains_secret`] again on the text, title and
//! address of every moment from every source (screen, browser extensions,
//! Mail, Messages, transcript import, MCP sync) before it is stored, and
//! [`redact_secrets`] on what MCP answers, context packets, handoffs and
//! send-cards carry out. The reader ([`crate::reading`]) checks its output
//! with the same logic, so cleaning text never makes something look like a
//! secret that the helper let through.
//!
//! Swift compiles the regex strings with `NSRegularExpression` (ICU); Rust
//! compiles them with `regex`. The credit-card and OTP detectors are hand-rolled
//! byte scans in both languages (no regex engine, no lookaround), so the two
//! engines cannot drift on them. Both answer the same for every case in
//! `core/brain/fixtures/ocr-secret-corpus.json`, which an `XCTest` of
//! `containsSecretOrPII` reads too. The corpus covers the characters the regex
//! engines could disagree on (newlines, U+001E, U+000B, U+0085, case folding),
//! real test PANs and non-Luhn look-alikes, OTPs with and without a keyword,
//! and every vendor key shape with its near misses. Key-shaped cases are
//! stored as `parts` the tests join, so no whole key sits in the repository.

use std::borrow::Cow;
use std::ops::Range;
use std::sync::OnceLock;

use regex::{Regex, RegexSet};

/// The pattern strings, in the helper's order: key-value secrets, GitHub
/// tokens, AWS access key ids, JSON web tokens, then vendor API keys and
/// private keys.
///
/// These are kept BYTE-FOR-BYTE identical to the raw-string literals in
/// `SuppressionCascade.swift` — `reading.rs`'s
/// `the_guard_uses_the_capture_helpers_pattern_strings_verbatim` fails the
/// build otherwise. The credit-card and OTP detectors below are deliberately
/// NOT in this array: they are not pure regex (one needs a checksum, the other
/// needs keyword context), so a bare `RegexSet` match would over-redact.
///
/// The vendor shapes are precision-first: each needs its vendor's prefix and
/// enough key characters that no word, file name or placeholder matches.
/// Stripe's test-mode secret keys (`sk_test_`, `rk_test_`) count: they are
/// working credentials for an account's test data, and Stripe's own docs show
/// a signed-in reader their real one. Publishable keys (`pk_live_`,
/// `pk_test_`) are public by design and do not count.
pub const PATTERNS: [&str; 14] = [
    // 1. A key name, `:` or `=`, and a value.
    r"(?i)(password|passwd|secret|api[_-]?key|token|bearer|access[_-]?token)\s*[:=]\s*\S+",
    // 2. GitHub classic tokens: ghp_, gho_, ghu_, ghs_, ghr_.
    r"\bgh[poursAS]_[A-Za-z0-9_]{20,}\b",
    // 3. AWS access key ids.
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    // 4. JSON web tokens.
    r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b",
    // 5. Anthropic API, admin and OAuth keys: sk-ant-api03-…, sk-ant-admin01-…
    r"\bsk-ant-[A-Za-z0-9_-]{20,}",
    // 6. OpenAI project, service-account and admin keys.
    r"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}",
    // 7. OpenAI user keys and other `sk-` keys: 32 or more letters and digits.
    r"\bsk-[A-Za-z0-9]{32,}",
    // 8. Slack bot, user, app, refresh, session and export tokens.
    r"\bxox[abeprs]-[0-9]+-[A-Za-z0-9-]{8,}",
    // 9. GitHub fine-grained personal access tokens.
    r"\bgithub_pat_[A-Za-z0-9_]{22,}",
    // 10. GitLab personal access tokens.
    r"\bglpat-[A-Za-z0-9_-]{20,}",
    // 11. Google API keys.
    r"\bAIza[0-9A-Za-z_-]{35}",
    // 12. Stripe secret and restricted keys, live and test.
    r"\b[rs]k_(?:live|test)_[0-9A-Za-z]{20,}",
    // 13. A private key's first line, any kind (RSA, EC, OpenSSH, PKCS #8).
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    // 14. `Bearer` and a long token with no label.
    r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}",
];

/// What [`redact_secrets`] puts where a secret was.
pub const REDACTED: &str = "[secret removed]";

fn pattern_set() -> &'static RegexSet {
    static SET: OnceLock<RegexSet> = OnceLock::new();
    SET.get_or_init(|| RegexSet::new(PATTERNS).expect("the helper patterns compile"))
}

fn pattern_regexes() -> &'static [Regex] {
    static EACH: OnceLock<Vec<Regex>> = OnceLock::new();
    EACH.get_or_init(|| {
        PATTERNS
            .iter()
            .map(|pattern| Regex::new(pattern).expect("the helper patterns compile"))
            .collect()
    })
}

/// Phrases that mark a nearby 4–8 digit run as a one-time code, lower-cased.
///
/// MUST stay identical to Swift `SuppressionCascade.otpKeywords`; the shared
/// corpus is the cross-engine check. Matched case-insensitively and only on a
/// word boundary, so "someone timer" is not "one time" and "laptop" is not a
/// match. `confirm(ation) code` is spelled out as both forms.
pub const OTP_KEYWORDS: [&str; 13] = [
    "one-time",
    "one time",
    "verification code",
    "security code",
    "passcode",
    "otp",
    "2fa",
    "two-factor",
    "authentication code",
    "login code",
    "confirmation code",
    "confirm code",
    "your code is",
];

/// How near (in UTF-8 bytes) a 4–8 digit run must sit to an OTP keyword for the
/// run to count as a one-time code. "~40 characters" in the launch audit; bytes
/// and characters coincide for the ASCII that OTP keywords and digits are made
/// of. MUST equal Swift `SuppressionCascade.otpWindowBytes`.
const OTP_WINDOW_BYTES: usize = 40;

/// True when any of the patterns matches, or `text` holds a Luhn-valid
/// credit-card number, or a one-time code next to an OTP keyword.
#[must_use]
pub fn contains_secret(text: &str) -> bool {
    pattern_set().is_match(text) || contains_credit_card(text) || contains_otp(text)
}

/// The byte ranges of `text` that [`contains_secret`] would object to:
/// every pattern match, every Luhn-valid card number and every one-time code,
/// sorted, with overlapping and touching ranges merged. Empty exactly when
/// [`contains_secret`] is false.
#[must_use]
pub fn secret_spans(text: &str) -> Vec<Range<usize>> {
    let mut spans: Vec<Range<usize>> = pattern_regexes()
        .iter()
        .flat_map(|regex| regex.find_iter(text).map(|found| found.range()))
        .collect();
    spans.extend(credit_card_spans(text));
    spans.extend(otp_spans(text));
    spans.sort_by_key(|span| (span.start, span.end));
    let mut merged: Vec<Range<usize>> = Vec::with_capacity(spans.len());
    for span in spans {
        match merged.last_mut() {
            Some(last) if span.start <= last.end => last.end = last.end.max(span.end),
            _ => merged.push(span),
        }
    }
    merged
}

/// `text` with every secret [`contains_secret`] finds replaced by
/// [`REDACTED`], for what leaves Hippocampus (an MCP answer, a context packet,
/// a handoff). Borrowed and unchanged when there is nothing to remove; the
/// result never holds a secret, so redacting twice changes nothing.
///
/// A whole match goes, key name included (`password: hunter2` becomes
/// `[secret removed]`), so the marker can never complete a key-value match.
/// Removing one secret can bring a number within reach of an OTP keyword, so
/// it repeats until nothing matches; a line that still matches after that
/// goes whole, and so, as a last resort, does the text.
#[must_use]
pub fn redact_secrets(text: &str) -> Cow<'_, str> {
    if !contains_secret(text) {
        return Cow::Borrowed(text);
    }
    let mut current = text.to_owned();
    for _ in 0..4 {
        let spans = secret_spans(&current);
        if spans.is_empty() {
            break;
        }
        let mut next = String::with_capacity(current.len());
        let mut at = 0;
        for span in spans {
            next.push_str(&current[at..span.start]);
            next.push_str(REDACTED);
            at = span.end;
        }
        next.push_str(&current[at..]);
        current = next;
    }
    if contains_secret(&current) {
        current = current
            .split('\n')
            .map(|line| {
                if contains_secret(line) {
                    REDACTED
                } else {
                    line
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
    }
    if contains_secret(&current) {
        REDACTED.clone_into(&mut current);
    }
    Cow::Owned(current)
}

/// Whether `text` holds a credit-card number: a maximal run of 13–19 digits,
/// with single spaces or hyphens allowed between digits, that passes the Luhn
/// checksum.
///
/// Precision-first. The run is maximal: a 20-digit blob is one 20-digit
/// candidate (out of range, so no match), never a 16-digit card hidden inside
/// it. It must stand on its own ([`stands_alone`]): a number inside a name
/// (`zebrafish20261020125831`, `handoff-20261020125831`, `…831.json`) is an
/// id or a timestamp, and one in ten of those passes Luhn. Luhn then drops
/// almost every ordinary number — phone numbers, order ids and timestamps
/// rarely pass — so a real card has to be on screen for this to fire.
#[must_use]
pub fn contains_credit_card(text: &str) -> bool {
    !credit_card_spans(text).is_empty()
}

/// The byte ranges of the card numbers [`contains_credit_card`] finds.
fn credit_card_spans(text: &str) -> Vec<Range<usize>> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if !bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        // Grow a maximal candidate run from here: digits, with at most one
        // space or hyphen between two digits.
        let start = i;
        let mut digits = 0usize;
        loop {
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                digits += 1;
                i += 1;
            }
            if i + 1 < bytes.len()
                && (bytes[i] == b' ' || bytes[i] == b'-')
                && bytes[i + 1].is_ascii_digit()
            {
                i += 1; // a single separator between two digits stays in the run
            } else {
                break;
            }
        }
        if (13..=19).contains(&digits)
            && stands_alone(bytes, start, i)
            && luhn_valid(&bytes[start..i])
        {
            spans.push(start..i);
        }
        // `i` already sits past this run; the maximal run is never re-entered.
    }
    spans
}

/// Whether the digit run `bytes[start..end]` stands on its own rather than
/// inside a name: no ASCII letter or `_` right before or right after it, and
/// no `-`, `.` or `/` joining it to a letter or digit on that side. A card
/// number is written apart from the words around it (`card 4111 …`,
/// `number: 4111…`, `…1111.` at the end of a sentence); a number glued into
/// a name (`zebrafish2026…`, `handoff-2026…`, `export_…831.json`) is an id or
/// a timestamp. Only ASCII counts, as in the helper's Swift twin
/// (`SuppressionCascade.standsAlone`).
fn stands_alone(bytes: &[u8], start: usize, end: usize) -> bool {
    let glued = |near: Option<&u8>, beyond: Option<&u8>| match near {
        Some(byte) if byte.is_ascii_alphabetic() || *byte == b'_' => true,
        Some(b'-' | b'.' | b'/') => beyond.is_some_and(u8::is_ascii_alphanumeric),
        _ => false,
    };
    let before = start.checked_sub(1).and_then(|at| bytes.get(at));
    let before_that = start.checked_sub(2).and_then(|at| bytes.get(at));
    !glued(before, before_that) && !glued(bytes.get(end), bytes.get(end + 1))
}

/// The Luhn checksum over the ASCII digits in `run`; any other byte (a space or
/// hyphen separator) is skipped. Doubles every second digit from the right,
/// casts out nines, and checks the total is a multiple of ten.
fn luhn_valid(run: &[u8]) -> bool {
    let mut sum = 0u32;
    let mut position = 0u32; // 0 for the rightmost digit, then 1, 2, …
    for &byte in run.iter().rev() {
        if !byte.is_ascii_digit() {
            continue;
        }
        let mut digit = u32::from(byte - b'0');
        if position % 2 == 1 {
            digit *= 2;
            if digit > 9 {
                digit -= 9;
            }
        }
        sum += digit;
        position += 1;
    }
    sum % 10 == 0
}

/// Whether `text` holds a one-time code: a maximal run of 4–8 digits within
/// [`OTP_WINDOW_BYTES`] of an OTP keyword (case-insensitive, on a word
/// boundary). A bare number with no such keyword never matches, so ordinary
/// 4–8 digit numbers (an order id, a year, a port) are kept.
#[must_use]
pub fn contains_otp(text: &str) -> bool {
    !otp_spans(text).is_empty()
}

/// The byte ranges of the digit runs [`contains_otp`] counts as one-time
/// codes: every 4–8 digit run within reach of a bounded OTP keyword.
fn otp_spans(text: &str) -> Vec<Range<usize>> {
    let bytes = text.as_bytes();

    // Maximal runs of 4–8 ASCII digits. A longer run (a card, a long id) is not
    // an OTP, so runs of 9+ digits are left out.
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if (4..=8).contains(&(i - start)) {
                runs.push((start, i));
            }
        } else {
            i += 1;
        }
    }
    if runs.is_empty() {
        return Vec::new();
    }

    // Lower-case the ASCII so the keyword search is case-insensitive without
    // moving any byte offset (every OTP keyword is ASCII, as are the digits).
    let lower: Vec<u8> = bytes.iter().map(u8::to_ascii_lowercase).collect();
    let mut codes = vec![false; runs.len()];
    for keyword in OTP_KEYWORDS {
        let keyword = keyword.as_bytes();
        if keyword.len() > lower.len() {
            continue;
        }
        for start in 0..=lower.len() - keyword.len() {
            if &lower[start..start + keyword.len()] != keyword {
                continue;
            }
            let end = start + keyword.len();
            let bounded = (start == 0 || !is_word_byte(lower[start - 1]))
                && (end == lower.len() || !is_word_byte(lower[end]));
            if !bounded {
                continue;
            }
            for (index, &(run_start, run_end)) in runs.iter().enumerate() {
                // Distance between the keyword span [start, end) and the digit
                // run [run_start, run_end); 0 when they overlap. saturating_sub
                // makes the non-touching side vanish, so this equals the old
                // if/else and clippy accepts it.
                let gap = run_start
                    .saturating_sub(end)
                    .max(start.saturating_sub(run_end));
                if gap <= OTP_WINDOW_BYTES {
                    codes[index] = true;
                }
            }
        }
    }
    runs.into_iter()
        .zip(codes)
        .filter_map(|((start, end), code)| code.then_some(start..end))
        .collect()
}

/// A byte that can be part of a word, for the OTP keyword boundary test.
fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_and_value_is_a_secret_and_a_sentence_is_not() {
        assert!(contains_secret("password: hunter2"));
        assert!(!contains_secret("Use a password manager."));
    }

    #[test]
    fn real_test_cards_pass_luhn_and_look_alikes_do_not() {
        // The standard Visa / Mastercard / Amex test PANs, spaced and bare.
        assert!(contains_credit_card("4111 1111 1111 1111"));
        assert!(contains_credit_card("4111-1111-1111-1111"));
        assert!(contains_credit_card("4111111111111111"));
        assert!(contains_credit_card("5500 0000 0000 0004"));
        assert!(contains_credit_card("3400 0000 0000 009")); // 15-digit Amex
                                                             // A 16-digit number that fails Luhn, and ordinary numbers in range.
        assert!(!contains_credit_card("1234 1234 1234 1234"));
        assert!(!contains_credit_card("4111 1111 1111 1112")); // last digit off
                                                               // Out of the 13–19 range: a phone number, a 20-digit blob, an order id.
        assert!(!contains_credit_card("415-555-0132"));
        assert!(!contains_credit_card("12345678901234567890"));
        assert!(!contains_credit_card("Order #40281773"));
        // A maximal 20-digit run is one over-long candidate, never a card
        // inside it, even though its first 16 digits are a valid Visa.
        assert!(!contains_credit_card("41111111111111110000"));
    }

    #[test]
    fn an_otp_needs_both_a_keyword_and_a_nearby_run() {
        assert!(contains_otp("Your verification code is 283910"));
        assert!(contains_otp("one-time passcode: 55012"));
        assert!(contains_otp("OTP 4821"));
        assert!(contains_otp("Enter the 2FA code 135790 to continue"));
        // A bare number, or a keyword too far from any run, is not an OTP.
        assert!(!contains_otp("283910"));
        assert!(!contains_otp("max_tokens: 4096"));
        assert!(!contains_otp("Order #40281773"));
        // "someone timer" is not "one time"; the boundary test rejects it.
        assert!(!contains_otp("someone timer showed 283910 on it"));
    }

    /// A number inside a name is an id or a timestamp, not a card: the
    /// end-to-end test's project, `handoff-<yyyymmddHHMMSS>`, was refused
    /// and its packet heading redacted whenever the stamp passed Luhn, which
    /// one stamp in ten does.
    #[test]
    fn a_number_inside_a_name_is_not_a_card() {
        assert!(luhn_valid(b"20261020125831"), "the stamp passes Luhn");
        for text in [
            "zebrafish20261020125831",
            "# handoff-20261020125831",
            "export_20261020125831.json",
            "builds/20261020125831/log.txt",
            "v1.20261020125831",
            "20261020125831abc",
        ] {
            assert!(!contains_credit_card(text), "{text}");
            assert!(!contains_secret(text), "{text}");
            assert_eq!(redact_secrets(text), text);
        }
        for text in [
            "card 4111 1111 1111 1111.",
            "number:4111111111111111",
            "(4111-1111-1111-1111)",
            "#4111111111111111",
            "card=4111111111111111&exp=1229",
            "- 4111111111111111",
        ] {
            assert!(contains_credit_card(text), "{text}");
        }
    }

    #[test]
    fn luhn_matches_the_textbook_values() {
        assert!(luhn_valid(b"79927398713"));
        assert!(!luhn_valid(b"79927398710"));
    }

    /// Key material for the vendor shapes, joined at run time so no whole
    /// key-shaped string sits in the source.
    const BODY: &str = "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R";

    fn key(parts: &[&str]) -> String {
        parts.concat()
    }

    #[test]
    fn every_vendor_key_shape_is_a_secret_on_its_own_line() {
        let keys = [
            key(&["sk-", "ant-", "api03-", BODY]),
            key(&["sk-", "ant-", "admin01-", BODY]),
            key(&["sk-", "proj-", BODY]),
            key(&["sk-", "svcacct-", BODY]),
            key(&["sk-", BODY]),
            key(&[
                "xox",
                "b-",
                "1234567890",
                "-",
                "9876543210",
                "-",
                &BODY[..24],
            ]),
            key(&[
                "xox",
                "p-",
                "1234567890",
                "-",
                "9876543210",
                "-",
                &BODY[..24],
            ]),
            key(&["gh", "p_", &BODY[..36]]),
            key(&["github", "_pat_", &BODY[..22], "_", BODY]),
            key(&["gl", "pat-", &BODY[..20]]),
            key(&["AK", "IA", "IOSFODNN7EXAMPLE"]),
            key(&["AI", "za", "Sy", &BODY[..33]]),
            key(&["sk", "_live_", &BODY[..24]]),
            key(&["rk", "_live_", &BODY[..24]]),
            key(&["sk", "_test_", &BODY[..24]]),
            key(&["-----BEGIN ", "OPENSSH ", "PRIVATE KEY-----"]),
            key(&["Authorization: ", "Bearer ", BODY]),
        ];
        for key in &keys {
            assert!(contains_secret(key), "{key}");
            assert!(
                contains_secret(&format!("Copy it now:\n{key}\nthen close")),
                "{key}"
            );
        }
    }

    #[test]
    fn near_misses_of_the_vendor_shapes_are_not_secrets() {
        for text in [
            "sk-ant-".to_owned(),
            key(&["sk-", "ant-", "short"]),
            key(&["task-", "ant-", "api03-", BODY]),
            "sk-learn is a common alias for scikit-learn".to_owned(),
            key(&["sk-", &BODY[..31]]),
            "risk-free, desk-bound, ask-me-anything".to_owned(),
            "xoxb- tokens start like this".to_owned(),
            key(&["xox", "o-", "1234-", "gossipgirl"]),
            key(&["xox", "b-", "notdigits-", BODY]),
            "github_pat_ is the prefix".to_owned(),
            key(&["gl", "pat-", "short"]),
            key(&["AI", "za", "Sy", &BODY[..32]]),
            key(&["pk", "_live_", &BODY[..24]]),
            key(&["pk", "_test_", &BODY[..24]]),
            key(&["sk", "_live_", "short"]),
            "-----BEGIN PUBLIC KEY-----".to_owned(),
            "-----BEGIN CERTIFICATE-----".to_owned(),
            "the bearer of this letter".to_owned(),
            "Bearer authentication is described in RFC 6750".to_owned(),
        ] {
            assert!(!contains_secret(&text), "{text}");
        }
    }

    #[test]
    fn redacting_clean_text_borrows_it_unchanged() {
        let text = "Send the Quillfeather draft by Thursday. Order #40281773.";
        assert!(matches!(redact_secrets(text), Cow::Borrowed(same) if same == text));
        assert!(secret_spans(text).is_empty());
    }

    #[test]
    fn redacting_removes_every_secret_and_keeps_the_rest() {
        let anthropic = key(&["sk-", "ant-", "api03-", BODY]);
        let text = format!(
            "Bramble\n{anthropic}\nPay with 4111 1111 1111 1111 today.\n\
             Your verification code is 482913.\npassword: hunter2 and more"
        );
        let redacted = redact_secrets(&text);
        assert!(!contains_secret(&redacted), "{redacted}");
        for gone in [anthropic.as_str(), "4111", "482913", "hunter2"] {
            assert!(!redacted.contains(gone), "{gone} in {redacted}");
        }
        for kept in ["Bramble", "Pay with", "today.", "and more"] {
            assert!(redacted.contains(kept), "{kept} not in {redacted}");
        }
        assert_eq!(
            redact_secrets(&redacted),
            redacted,
            "redacting twice changes nothing"
        );
    }

    #[test]
    fn a_removed_card_cannot_bring_a_code_within_reach_of_its_keyword() {
        // The card is 19 bytes and the marker 16, so with the card gone the
        // run 1234 moves from 42 bytes after "passcode" to 39: within reach.
        let text = format!("passcode 4111 1111 1111 1111 {} 1234", "x".repeat(20));
        let redacted = redact_secrets(&text);
        assert!(!contains_secret(&redacted), "{redacted}");
        assert!(!redacted.contains("1234"), "{redacted}");
    }

    #[test]
    fn spans_cover_exactly_the_secrets() {
        let text = "a password: hunter2 b";
        let spans = secret_spans(text);
        assert_eq!(spans.len(), 1);
        assert_eq!(&text[spans[0].clone()], "password: hunter2");
    }
}
