//! The OCR secret patterns, copied verbatim from the capture helper, plus the
//! two detectors a plain regex cannot express: credit-card numbers (Luhn) and
//! one-time codes (a keyword nearby).
//!
//! `SuppressionCascade.containsSecretOrPII`
//! (`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift`)
//! refuses to store any OCR text one of these matches. The reader
//! ([`crate::reading`]) checks its output with the same logic, so cleaning text
//! never makes something look like a secret that the helper let through.
//!
//! Swift compiles the four regex strings with `NSRegularExpression` (ICU); Rust
//! compiles them with `regex`. The credit-card and OTP detectors are hand-rolled
//! byte scans in both languages (no regex engine, no lookaround), so the two
//! engines cannot drift on them. Both answer the same for every case in
//! `core/brain/fixtures/ocr-secret-corpus.json`, which an XCTest of
//! `containsSecretOrPII` reads too. The corpus covers the characters the regex
//! engines could disagree on (newlines, U+001E, U+000B, U+0085, case folding),
//! real test PANs and non-Luhn look-alikes, and OTPs with and without a keyword.

use std::sync::OnceLock;

use regex::RegexSet;

/// The pattern strings, in the helper's order: key-value secrets, GitHub
/// tokens, AWS access key ids, JSON web tokens.
///
/// These four are kept BYTE-FOR-BYTE identical to the raw-string literals in
/// `SuppressionCascade.swift` — `reading.rs`'s
/// `the_guard_uses_the_capture_helpers_four_pattern_strings_verbatim` fails the
/// build otherwise. The credit-card and OTP detectors below are deliberately
/// NOT in this array: they are not pure regex (one needs a checksum, the other
/// needs keyword context), so a bare `RegexSet` match would over-redact.
pub const PATTERNS: [&str; 4] = [
    r"(?i)(password|passwd|secret|api[_-]?key|token|bearer|access[_-]?token)\s*[:=]\s*\S+",
    r"\bgh[poursAS]_[A-Za-z0-9_]{20,}\b",
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b",
];

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

/// True when any of the four patterns matches, or `text` holds a Luhn-valid
/// credit-card number, or a one-time code next to an OTP keyword.
#[must_use]
pub fn contains_secret(text: &str) -> bool {
    static SET: OnceLock<RegexSet> = OnceLock::new();
    SET.get_or_init(|| RegexSet::new(PATTERNS).expect("the four helper patterns compile"))
        .is_match(text)
        || contains_credit_card(text)
        || contains_otp(text)
}

/// Whether `text` holds a credit-card number: a maximal run of 13–19 digits,
/// with single spaces or hyphens allowed between digits, that passes the Luhn
/// checksum.
///
/// Precision-first. The run is maximal: a 20-digit blob is one 20-digit
/// candidate (out of range, so no match), never a 16-digit card hidden inside
/// it. Luhn then drops almost every ordinary number — phone numbers, order ids
/// and timestamps rarely pass — so a real card has to be on screen for this to
/// fire.
#[must_use]
pub fn contains_credit_card(text: &str) -> bool {
    let bytes = text.as_bytes();
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
        if (13..=19).contains(&digits) && luhn_valid(&bytes[start..i]) {
            return true;
        }
        // `i` already sits past this run; the maximal run is never re-entered.
    }
    false
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
        return false;
    }

    // Lower-case the ASCII so the keyword search is case-insensitive without
    // moving any byte offset (every OTP keyword is ASCII, as are the digits).
    let lower: Vec<u8> = bytes.iter().map(u8::to_ascii_lowercase).collect();
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
            for &(run_start, run_end) in &runs {
                // Distance between the keyword span [start, end) and the digit
                // run [run_start, run_end); 0 when they overlap. saturating_sub
                // makes the non-touching side vanish, so this equals the old
                // if/else and clippy accepts it.
                let gap = run_start
                    .saturating_sub(end)
                    .max(start.saturating_sub(run_end));
                if gap <= OTP_WINDOW_BYTES {
                    return true;
                }
            }
        }
    }
    false
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

    #[test]
    fn luhn_matches_the_textbook_values() {
        assert!(luhn_valid(b"79927398713"));
        assert!(!luhn_valid(b"79927398710"));
    }
}
