//! The agent's last check before anything is stored: one rule for every
//! source.
//!
//! The agent is the only program that writes memory, so every path that
//! stores a moment comes through here first: the screen (the capture
//! helper's frames), the browser extensions (Chromium's native host and the
//! Safari reader, through the page-content socket), Mail and Messages,
//! transcript import, and MCP sync. The helper already checks a frame's text,
//! title and address before it sends it; the other producers check less, so
//! the agent checks everything again with the same rules
//! ([`mci_brain::redaction::ocr_secrets::contains_secret`], kept in parity
//! with the helper's Swift checks by a shared corpus).
//!
//! Two steps, in this order:
//!
//! 1. [`storable_url`]: the address without its sign-in parameters
//!    (`access_token=…`, `code=…`, `X-Amz-Signature=…`, see
//!    [`mci_brain::redaction::url_secrets`]). This is the only address that
//!    is ever stored, and it goes into the moment's header too.
//! 2. [`find_secret`]: the moment's text, its title and that address. A
//!    secret in any of them and nothing of the moment is stored.

use std::borrow::Cow;

use mci_brain::redaction::ocr_secrets::contains_secret;
use mci_brain::redaction::url_secrets::strip_secret_params;

/// Which part of a moment held a secret. Content-free: it names the field,
/// never what was in it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecretIn {
    /// The moment's text (screen text, a page, a message, a transcript turn).
    Text,
    /// The window title, page title, subject or other heading.
    Title,
    /// The address, after its sign-in parameters were removed.
    Address,
}

impl SecretIn {
    /// A stable name for counters and logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Title => "title",
            Self::Address => "address",
        }
    }
}

/// The address as it may be stored: without sign-in parameters, and `None`
/// when nothing is left.
#[must_use]
pub fn storable_url(url: Option<String>) -> Option<String> {
    let url = url?;
    let clean = match strip_secret_params(&url) {
        Cow::Borrowed(_) => url,
        Cow::Owned(clean) => clean,
    };
    (!clean.is_empty()).then_some(clean)
}

/// Where a moment holds a secret, if anywhere: its text, its title, or its
/// address. Pass the address [`storable_url`] returned, so a token it removes
/// does not stop the moment.
#[must_use]
pub fn find_secret(text: &str, title: Option<&str>, url: Option<&str>) -> Option<SecretIn> {
    if contains_secret(text) {
        return Some(SecretIn::Text);
    }
    if title.is_some_and(contains_secret) {
        return Some(SecretIn::Title);
    }
    if url.is_some_and(contains_secret) {
        return Some(SecretIn::Address);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const JWT: &str = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl";

    #[test]
    fn a_token_parameter_is_removed_and_does_not_stop_the_moment() {
        let url = storable_url(Some(format!(
            "https://app.larch.example/cb?access_token={JWT}&lang=en"
        )));
        assert_eq!(url.as_deref(), Some("https://app.larch.example/cb?lang=en"));
        assert_eq!(find_secret("Welcome back", Some("Larch"), url.as_deref()), None);
    }

    #[test]
    fn a_secret_elsewhere_in_the_address_stops_the_moment() {
        let url = storable_url(Some(format!("https://app.larch.example/reset/{JWT}")));
        assert_eq!(
            find_secret("Choose a new password", Some("Reset"), url.as_deref()),
            Some(SecretIn::Address)
        );
    }

    #[test]
    fn the_text_and_the_title_are_checked_too() {
        let key = ["sk-", "ant-", "api03-", "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R"].concat();
        assert_eq!(find_secret(&key, None, None), Some(SecretIn::Text));
        assert_eq!(
            find_secret("Keys", Some(&format!("Console — {key}")), None),
            Some(SecretIn::Title)
        );
        assert_eq!(find_secret("Send the draft", Some("Notes"), None), None);
    }

    #[test]
    fn an_address_left_empty_is_not_stored() {
        assert_eq!(storable_url(Some("?token=SYNTH".into())), None);
        assert_eq!(storable_url(Some(String::new())), None);
        assert_eq!(storable_url(None), None);
    }
}
