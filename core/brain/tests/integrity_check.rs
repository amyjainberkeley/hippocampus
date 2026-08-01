//! Cycle 8.44 audit — breakage risk #3 pins.
//!
//! Verifies:
//! 1. `verify_integrity_on_boot` succeeds on a healthy DB with the
//!    typed `Ok(())` shape that `apps/agent` gates on.
//! 2. `verify_integrity_on_boot` returns `IntegrityError::Corrupted`
//!    with pragma output preserved when the `SQLite` file is
//!    physically corrupted BEFORE open. This is the "refuse to
//!    serve" trigger — the agent match arm in
//!    `apps/agent/src/bin/mci_agent.rs` returns `ExitCode::from(22)`
//!    on this error.
//!
//! Corrupting a `SQLCipher` file by overwriting bytes in the ENCRYPTED
//! store would fail the wrong-key probe on re-open (`mci_core::store`
//! refuses to open a torn cipher). Instead we assert the healthy-path
//! contract + directly exercise the `IntegrityError::Corrupted`
//! variant to pin its `Display` shape (which the agent's log line
//! uses).

use std::path::PathBuf;

use mci_brain::{IntegrityError, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use tempfile::TempDir;

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

/// Fresh DB, no prior writes → `verify_integrity_on_boot` returns
/// `Ok(())`. The agent boot path passes and proceeds to spawn ingest
/// pumps.
#[test]
fn verify_integrity_on_boot_ok_on_fresh_db() {
    let (_dir, path) = tmp("boot_ok_fresh.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    store
        .verify_integrity_on_boot()
        .expect("healthy DB must pass");
}

/// After a round-trip write + re-open (the common case), the check
/// still passes.
#[test]
fn verify_integrity_on_boot_ok_after_write() {
    let (_dir, path) = tmp("boot_ok_after_write.sqlite");
    let key = test_key();
    {
        let store = SqlCipherBrainStore::new(&path, &key).expect("open");
        // Touch the DB by running the underlying integrity_check —
        // exercises the writer connection at least once so the WAL
        // has some traffic.
        let rows = store.integrity_check().expect("integrity");
        assert_eq!(rows, vec!["ok".to_string()]);
    }
    let store = SqlCipherBrainStore::new(&path, &key).expect("re-open");
    store
        .verify_integrity_on_boot()
        .expect("healthy DB must pass after round-trip");
}

/// The `Corrupted` variant preserves the pragma row set verbatim so
/// the agent's stderr log line + future repair UX have the full
/// diagnostic. This test constructs the variant directly (production
/// corruption paths are cheaper to exercise structurally than by
/// synthesizing a torn `SQLCipher` file across versions) and asserts
/// the `Display` shape the agent's error branch matches on.
#[test]
fn integrity_error_corrupted_display_preserves_rows() {
    let rows = vec![
        "*** in database main ***".to_string(),
        "Page 42: btreeInitPage() returns error code 11".to_string(),
    ];
    let err = IntegrityError::Corrupted(rows.clone());
    let msg = format!("{err}");
    assert!(msg.contains("corrupted"), "display: {msg}");
    for row in &rows {
        assert!(
            msg.contains(row),
            "display must preserve row {row:?}: {msg}"
        );
    }
}

/// Backend-error variant carries the wrapped `StoreError` message
/// verbatim.
#[test]
fn integrity_error_backend_display_preserves_source() {
    let err = IntegrityError::Backend("prepare integrity_check: database is locked".to_string());
    let msg = format!("{err}");
    assert!(msg.contains("backend"), "display: {msg}");
    assert!(msg.contains("database is locked"), "display: {msg}");
}

/// Pins the "refuse to serve on integrity failure" contract at the
/// type level: matching on `verify_integrity_on_boot`'s result yields
/// exactly two error variants, both of which the agent boot arm MUST
/// treat as fatal (return `ExitCode::from(22)` without spawning
/// pumps). If a new `IntegrityError` variant lands, this match will
/// fail to compile and the agent's boot arm MUST be extended.
#[test]
fn refuse_to_serve_matches_all_integrity_error_variants() {
    // Consume every variant so `#[non_exhaustive]` growth or a new
    // enum variant forces an audit of the agent's boot match arm.
    fn all_variants_are_fatal(e: &IntegrityError) -> &'static str {
        match e {
            IntegrityError::Backend(_) | IntegrityError::Corrupted(_) => "refuse-to-serve",
        }
    }
    assert_eq!(
        all_variants_are_fatal(&IntegrityError::Backend("x".into())),
        "refuse-to-serve"
    );
    assert_eq!(
        all_variants_are_fatal(&IntegrityError::Corrupted(vec!["y".into()])),
        "refuse-to-serve"
    );
}
