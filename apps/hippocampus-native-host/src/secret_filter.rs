//! The secret checks a page passes before the host forwards it: the same
//! code the agent and the capture helper's Rust twin run, compiled into this
//! binary from `core/brain/src/redaction/` (the host does not link the brain
//! crate, so the two files are included by path, never copied).
//!
//! - [`page_holds_secret`]: every key-value secret, GitHub, AWS, JWT and
//!   vendor key shape, private keys, Luhn-valid card numbers and one-time
//!   codes, in the page's text, its title and its addresses (each checked
//!   without its sign-in parameters).
//! - [`strip_secret_params`]: the address the host forwards, without
//!   `access_token=…` and the like.
//!
//! Security review INVARIANT: this filter runs BEFORE any `PageContentEvent`
//! reaches the wire. A page that matches is dropped and the host answers
//! `dropped`, never `ok`. The agent runs the same checks again before
//! anything is stored.

#[allow(dead_code)]
#[path = "../../../core/brain/src/redaction/ocr_secrets.rs"]
mod ocr_secrets;
#[allow(dead_code)]
#[path = "../../../core/brain/src/redaction/url_secrets.rs"]
mod url_secrets;

pub use url_secrets::strip_secret_params;

/// Whether `text` holds anything the shared checks call a secret.
pub fn contains_secret(text: &str) -> bool {
    ocr_secrets::contains_secret(text)
}

/// Whether a page holds a secret in its text, its title or any of its
/// addresses, the addresses checked as they would be forwarded (without
/// sign-in parameters).
pub fn page_holds_secret(text: &str, title: &str, urls: &[&str]) -> bool {
    contains_secret(text)
        || contains_secret(title)
        || urls
            .iter()
            .any(|url| contains_secret(&strip_secret_params(url)))
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

    /// The storage review's extension run (S2): the host answered `ok` for a
    /// card, a one-time code and a bare key, and forwarded them.
    #[test]
    fn cards_codes_and_bare_keys_are_secrets_here_too() {
        let key = [
            "sk-",
            "ant-",
            "api03-",
            "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R",
        ]
        .concat();
        assert!(contains_secret(
            "Pay with card 4111 1111 1111 1111 exp 12/29"
        ));
        assert!(contains_secret("Your verification code is 482913."));
        assert!(contains_secret(&format!("Copy your key now: {key}")));
    }

    #[test]
    fn a_page_is_checked_in_its_title_and_addresses() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl";
        assert!(page_holds_secret(
            "clean",
            "Reset password: SYNTHhunter2",
            &[]
        ));
        assert!(page_holds_secret(
            "clean",
            "Reset",
            &[&format!("https://x.example/reset/{jwt}")]
        ));
        // A token only in a sign-in parameter is removed, not a reason to drop.
        let url = format!("https://x.example/cb?access_token={jwt}&lang=en");
        assert!(!page_holds_secret("Welcome back", "Larch", &[&url]));
        assert_eq!(strip_secret_params(&url), "https://x.example/cb?lang=en");
    }
}
