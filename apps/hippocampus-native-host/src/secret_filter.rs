//! §6 secret-pattern filter — Rust port of
//! `SuppressionCascade.containsSecretOrPII` from MCICaptureHelperKit.
//!
//! Patterns covered (same set as the Swift helper):
//!   1. password/secret/api_key/token/bearer/access_token + separator + value
//!   2. GitHub PAT (ghp_/gho_/ghu_/ghs_/ghr_ + 36 alnum)
//!   3. AWS access key (AKIA/ASIA + 16 alnum)
//!   4. JWT (eyJ + base64url . base64url . base64url)
//!
//! CSO INVARIANT: this filter runs BEFORE any PageContentEvent reaches
//! the wire. Text that matches ANY pattern is dropped — the event is
//! never emitted. Same cascade-twice discipline as OCREvent.

use regex::Regex;
use std::sync::LazyLock;

static SECRET_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    let specs = [
        // 1. password/secret/key/token with separator and value
        r"(?i)(?:password|passwd|secret|api[_\-]?key|token|bearer|access[_\-]?token)\s*[:=]\s*\S+",
        // 2. GitHub PAT
        r"gh[pousr]_[A-Za-z0-9]{36}",
        // 3. AWS access key id
        r"(?:AKIA|ASIA)[A-Z0-9]{16}",
        // 4. JWT
        r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
    ];
    specs
        .iter()
        .map(|s| Regex::new(s).expect("secret pattern compiles"))
        .collect()
});

pub fn contains_secret(text: &str) -> bool {
    for pat in SECRET_PATTERNS.iter() {
        if pat.is_match(text) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_clean_text() {
        assert!(!contains_secret("Hello world, no secrets here."));
        assert!(!contains_secret(""));
        assert!(!contains_secret("Plans start at $10/mo."));
    }

    #[test]
    fn blocks_password_pattern() {
        assert!(contains_secret("password=hunter2"));
        assert!(contains_secret("Password: SuperSecret!"));
        assert!(contains_secret("api_key = sk-deadbeefcafe"));
    }

    #[test]
    fn blocks_bearer_token() {
        assert!(contains_secret("Authorization: bearer = abcd1234efgh5678"));
    }

    #[test]
    fn blocks_github_pat() {
        assert!(contains_secret(
            "Stale ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 token"
        ));
    }

    #[test]
    fn blocks_aws_access_key() {
        assert!(contains_secret("AWS_ACCESS_KEY_ID AKIAIOSFODNN7EXAMPLE"));
    }

    #[test]
    fn blocks_jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123";
        assert!(contains_secret(&format!("Set-Cookie: {jwt}; HttpOnly")));
    }

    #[test]
    fn access_token_pattern() {
        assert!(contains_secret("access_token=abc123def456"));
    }
}
