//! The shared corpus for removing sign-in tokens from page addresses, which
//! the capture helper's `XCTest` reads too: both languages turn every address
//! into the same stored one.

use std::path::PathBuf;

use mci_brain::redaction::ocr_secrets::contains_secret;
use mci_brain::redaction::url_secrets::{has_secret_params, strip_secret_params};

fn corpus() -> Vec<(String, String, String)> {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/url-secret-params-corpus.json");
    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    value["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            (
                case["url"].as_str().unwrap().to_owned(),
                case["stored"].as_str().unwrap().to_owned(),
                case["why"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

#[test]
fn every_address_in_the_shared_corpus_is_stored_as_it_says() {
    let cases = corpus();
    assert!(cases.len() >= 30);
    for (url, stored, why) in cases {
        assert_eq!(strip_secret_params(&url), stored, "{why}: {url}");
        assert_eq!(has_secret_params(&url), url != stored, "{why}: {url}");
        // Removing is idempotent: what is stored has nothing left to remove.
        assert_eq!(strip_secret_params(&stored), stored, "{why}: {stored}");
    }
}

#[test]
fn the_token_address_from_the_end_to_end_run_is_clean_once_stripped() {
    // `c8.url` in scripts/e2e-full.sh: the window showed only the site's name.
    let url = "https://app.larch.example/cb?access_token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl&lang=en";
    assert!(contains_secret(url));
    let stored = strip_secret_params(url);
    assert_eq!(stored, "https://app.larch.example/cb?lang=en");
    assert!(!contains_secret(&stored));
}

#[test]
fn no_stored_address_keeps_a_name_the_key_value_pattern_looks_for() {
    // Every name the key-value secret pattern looks for ends a credential
    // parameter's name, so stripping leaves the pattern nothing to find in a
    // query, and a moment is not dropped for an ordinary `csrf_token=` link.
    for name in [
        "password",
        "passwd",
        "secret",
        "api_key",
        "api-key",
        "apikey",
        "token",
        "bearer",
        "access_token",
        "access-token",
        "csrf_token",
        "pageToken",
    ] {
        let url = format!("https://example.com/page?{name}=SYNTH&page=2");
        assert!(contains_secret(&url), "{name}");
        let stored = strip_secret_params(&url);
        assert_eq!(stored, "https://example.com/page?page=2", "{name}");
        assert!(!contains_secret(&stored), "{name}");
    }
}
