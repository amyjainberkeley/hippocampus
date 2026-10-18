//! At-rest encryption proof for the production `SqlCipherBrainStore`,
//! written so a careful reviewer can reproduce it from the outside.
//!
//! This complements the two proofs already in the tree:
//!
//! - `core/src/store/open.rs` → `encrypt_close_reopen_roundtrip_and_wrong_key_fails`
//!   (store layer: no plaintext on disk, no `SQLite format 3` header,
//!   wrong/absent key fails), and
//! - `core/brain/tests/sqlcipher_brain_store.rs` (the brain store's
//!   schema + read/write behaviour over the encrypted file).
//!
//! What this file adds, at the *brain* layer and with a shape a launch
//! checker can lean on:
//!
//! 1. A UNIQUE plaintext canary string is written through `put_event`,
//!    then every byte of every file in the store dir is scanned — the
//!    canary must appear in NONE of them (main DB, `-wal`, `-shm`,
//!    blobs). This is the "no plaintext capture text in the store dir"
//!    property stated as a test.
//! 2. A raw keyless open (a fresh `rusqlite::Connection` with no
//!    `PRAGMA key`) cannot read the schema — the `SQLCipher` property a
//!    plain `sqlite3` CLI surfaces as "file is not a database".
//! 3. No key-material file is written beside the DB (the key lives in
//!    the Keychain; see `KeychainDatabaseKeyResolver` + the `open.rs`
//!    "key comes from a `DbKey` only — never argv / env / a config
//!    file" contract).
//!
//! Everything is SYNTHETIC: a throwaway key via the test-only
//! `InMemoryKeyWrap` (which cannot be constructed by a shipped binary —
//! `mci-core`'s `insecure-test-keywrap` feature `compile_error!`s in a
//! release build) and made-up text. It never touches the real brain.
//!
//! When `MCI_VERIFY_OUT_DIR` is set, the synthetic store is created
//! there and LEFT IN PLACE, and the canary is written to
//! `<dir>/canary.txt`, so `scripts/launch/verify-encryption.sh` can
//! cross-check the same file with the *system* `sqlite3` CLI. Without
//! the env var the test uses a `tempfile::tempdir()` that is cleaned up
//! — so the test is self-contained and asserts every property itself.

use std::path::PathBuf;

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};

/// Fresh `DbKey` via the test-only `InMemoryKeyWrap` round-trip —
/// mirrors `sqlcipher_brain_store.rs`'s `test_key`.
fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn synthetic_event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.synthetic".into()),
        window_title: Some("Synthetic fixture — not real capture".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

/// Recursively collect every regular file under `dir`.
fn all_files(dir: &std::path::Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.is_file() {
                out.push(p);
            }
        }
    }
    out
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn synthetic_brain_store_is_sqlcipher_encrypted_at_rest() {
    // Where the synthetic store lives. Persisted iff MCI_VERIFY_OUT_DIR
    // is set (the launch checker's hook); otherwise a cleaned-up tempdir.
    let (persist, dir, _guard): (bool, PathBuf, Option<tempfile::TempDir>) =
        if let Some(v) = std::env::var_os("MCI_VERIFY_OUT_DIR") {
            let d = PathBuf::from(v);
            std::fs::create_dir_all(&d).expect("create MCI_VERIFY_OUT_DIR");
            (true, d, None)
        } else {
            let td = tempfile::tempdir().expect("tempdir");
            let d = td.path().to_path_buf();
            (false, d, Some(td))
        };

    let db_path = dir.join("mci.sqlite");

    // A unique, high-entropy, human-readable canary. If any byte of this
    // appears in any store file, the capture text was written in the
    // clear. The value is deliberately not a word that could occur by
    // chance in SQLite framing.
    let nonce = format!(
        "{}_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos()),
        std::process::id()
    );
    let canary = format!("HIPPO-ATREST-CANARY-{nonce}-DO-NOT-STORE-IN-PLAINTEXT");

    let key = test_key();

    // Create, write one synthetic event carrying the canary, close.
    let written_id = {
        let store = SqlCipherBrainStore::new(&db_path, &key).expect("open fresh encrypted store");
        let id = store
            .put_event(&synthetic_event(
                1_700_000_000_000_000,
                &format!("[app=com.example.synthetic] {canary} — synthetic OCR line"),
            ))
            .expect("put synthetic event");
        id
        // store drops here → connection closes, pages flush.
    };

    // 1. Round-trip with the right key: the canary is readable again,
    //    so we know it really was stored (not silently dropped).
    {
        let store = SqlCipherBrainStore::new(&db_path, &key).expect("reopen with key");
        let ev = store
            .get_event(written_id)
            .expect("get_event")
            .expect("event present");
        assert!(
            ev.text.contains(&canary),
            "round-trip lost the canary — the test would be vacuous"
        );
    }

    // 2. The on-disk bytes must NOT contain the canary anywhere — not in
    //    the main DB, the WAL, the SHM, or any blob. SQLCipher encrypts
    //    the WAL pages too, so a freshly-written, un-checkpointed event
    //    must still be ciphertext at rest.
    let files = all_files(&dir);
    assert!(
        files.iter().any(|p| p == &db_path),
        "expected the main DB file to exist"
    );
    let canary_bytes = canary.as_bytes();
    for f in &files {
        // canary.txt (written below for the shell checker) legitimately
        // holds the canary; it is not part of the encrypted store.
        if f.file_name().and_then(|n| n.to_str()) == Some("canary.txt") {
            continue;
        }
        let bytes = std::fs::read(f).expect("read store file");
        assert!(
            !contains(&bytes, canary_bytes),
            "plaintext canary found in {} — encryption not engaged on this file",
            f.display()
        );
    }

    // 3. The main DB must not carry the unencrypted SQLite header.
    let head = std::fs::read(&db_path).expect("read db");
    assert!(
        !head.starts_with(b"SQLite format 3\0"),
        "unencrypted SQLite header on disk — SQLCipher not engaged"
    );

    // 4. A RAW keyless open (what a plain `sqlite3` CLI does) cannot read
    //    the schema. `rusqlite` here is the bundled-SQLCipher build, so a
    //    no-PRAGMA-key open surfaces SQLITE_NOTADB on first read — the
    //    same "file is not a database" the system CLI prints.
    {
        let raw = rusqlite::Connection::open(&db_path).expect("open raw handle");
        let probe: Result<i64, _> =
            raw.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get(0));
        assert!(
            probe.is_err(),
            "a keyless open read the schema — the file is NOT encrypted"
        );
    }

    // 5. No key-material file beside the DB. The key lives in the
    //    Keychain; nothing key-shaped should be written to the store dir.
    for f in &files {
        let name = f
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        assert!(
            !(name.contains("key") || name.contains(".pem") || name == "keyfile"),
            "found a key-shaped file in the store dir: {}",
            f.display()
        );
    }

    if persist {
        std::fs::write(dir.join("canary.txt"), &canary).expect("write canary.txt");
        // Leave the synthetic store in place for the shell cross-check.
        eprintln!(
            "MCI_VERIFY_OUT_DIR persisted synthetic store at {}",
            dir.display()
        );
        eprintln!("MCI_VERIFY_CANARY={canary}");
    }
}
