//! What `mci-agent` links. The Mail.app and Messages.app readers, and the
//! deep-hook supervisor that starts them, are compiled in only with the
//! `deep-hooks` feature, which is off by default and in every release
//! (launch plan item 10: Hippocampus reads what is on the screen, not mail
//! or message databases). Checked in the built binary itself, so no other
//! path can link them back in unnoticed.

/// Text only the readers and the supervisor put in the binary: each
/// reader's source path (its panic locations), the Messages reader's query,
/// the Mail reader's parse error, the supervisor's start line and the
/// allowlist file only the supervisor reads.
const MARKERS: [&str; 6] = [
    "mci-mail-reader/src",
    "mci-messages-reader/src",
    "chat_message_join",
    "invalid emlx framing",
    "deep-hook pump supervisor",
    "user-allowlist.toml",
];

/// The markers found in the `mci-agent` this test run built.
fn linked() -> Vec<&'static str> {
    let binary = std::fs::read(env!("CARGO_BIN_EXE_mci-agent")).expect("read the built mci-agent");
    // The markers are ASCII, so a lossy reading keeps every one of them.
    let text = String::from_utf8_lossy(&binary);
    MARKERS
        .into_iter()
        .filter(|marker| text.contains(marker))
        .collect()
}

#[cfg(not(feature = "deep-hooks"))]
#[test]
fn the_default_build_has_no_mail_or_messages_reader() {
    assert_eq!(linked(), Vec::<&str>::new());
}

/// The control: with the feature on (as CI's `--all-features` run builds
/// it), every marker is in the binary, so their absence by default means
/// the readers are gone, not that the markers are wrong.
#[cfg(all(target_os = "macos", feature = "deep-hooks"))]
#[test]
fn a_deep_hooks_build_links_the_readers() {
    assert_eq!(linked(), MARKERS.to_vec());
}
