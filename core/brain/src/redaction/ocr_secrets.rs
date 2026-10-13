//! The four OCR secret patterns, copied verbatim from the capture helper.
//!
//! `SuppressionCascade.containsSecretOrPII`
//! (`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift`)
//! refuses to store any OCR text one of these patterns matches. The reader
//! ([`crate::reading`]) checks its output with the same four strings, so
//! cleaning text never makes something look like a secret that the helper let
//! through.
//!
//! Swift compiles the strings with `NSRegularExpression` (ICU); Rust compiles
//! them with `regex`. Both answer the same for every case in
//! `core/brain/fixtures/ocr-secret-corpus.json`, which an XCTest of
//! `containsSecretOrPII` reads too. The corpus covers the characters the two
//! engines could disagree on: newlines, U+001E, U+000B, U+0085 and case
//! folding.

use std::sync::OnceLock;

use regex::RegexSet;

/// The pattern strings, in the helper's order: key-value secrets, GitHub
/// tokens, AWS access key ids, JSON web tokens.
pub const PATTERNS: [&str; 4] = [
    r"(?i)(password|passwd|secret|api[_-]?key|token|bearer|access[_-]?token)\s*[:=]\s*\S+",
    r"\bgh[poursAS]_[A-Za-z0-9_]{20,}\b",
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b",
];

/// True when any of the four patterns matches anywhere in `text`.
#[must_use]
pub fn contains_secret(text: &str) -> bool {
    static SET: OnceLock<RegexSet> = OnceLock::new();
    SET.get_or_init(|| RegexSet::new(PATTERNS).expect("the four helper patterns compile"))
        .is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_and_value_is_a_secret_and_a_sentence_is_not() {
        assert!(contains_secret("password: hunter2"));
        assert!(!contains_secret("Use a password manager."));
    }
}
