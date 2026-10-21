//! Storage-security review S11: a release build never opens the person's
//! memory with a development key, however the environment asks
//! (`MCI_DEVELOPMENT_FILE_KEY=1` with `MCI_DB_KEY_HEX`, `MCI_DB_KEY_FILE` or
//! `MCI/dev.key`). Only Demo Memory's own key file still opens Demo
//! Memory's own store. A debug build keeps the development path.
//!
//! The binary checks run the programs this profile built (`cargo test` for
//! debug, `cargo test --release` for release), in a throwaway home, with a
//! Keychain service that holds nothing, so no real item is ever asked for.

use std::path::{Path, PathBuf};
use std::process::Command;

use mci_agent::key_resolver::{
    demo_memory_folder, DevelopmentKeyEnvironment, DEVELOPMENT_FILE_KEY_COMPILED_IN,
};
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn key_pair() -> ([u8; 32], String) {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("csprng");
    let hex = bytes.iter().fold(String::new(), |mut out, byte| {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
        out
    });
    (bytes, hex)
}

fn memory(path: &Path, key: [u8; 32]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let store = SqlCipherBrainStore::new(path, &DbKey::from_bytes(key)).expect("store");
    store
        .put_event(&Event {
            id: EventId(0),
            ts_us: 1_800_000_000_000_000,
            app_bundle_id: Some("com.example.Notes".into()),
            window_title: Some("Synthetic".into()),
            url: None,
            text: "A made-up moment.".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        })
        .expect("moment");
}

#[test]
fn without_the_development_path_only_demo_memorys_own_key_file_is_read() {
    let home = tempfile::tempdir().unwrap();
    let (_, hex) = key_pair();
    let mci = home.path().join("Library/Application Support/MCI");
    std::fs::create_dir_all(&mci).unwrap();
    std::fs::write(mci.join("dev.key"), &hex).unwrap();
    let demo = demo_memory_folder(home.path());
    std::fs::create_dir_all(&demo).unwrap();
    std::fs::write(demo.join("demo.key"), format!("{hex}\n")).unwrap();
    let demo_db = demo.join("mci.sqlite");
    let real_db = mci.join("mci.sqlite");

    let ask = |raw: Option<&str>, file: Option<&Path>, db: Option<&Path>, built: bool| {
        DevelopmentKeyEnvironment {
            marker: Some("1"),
            raw_key: raw,
            key_file: file,
            db_path: db,
            home: Some(home.path()),
        }
        .key_for_build(built)
    };
    // A raw key, the file beside the real memory, a file the environment
    // names: all ignored for the real memory.
    assert_eq!(ask(Some(&hex), None, Some(&real_db), false), None);
    assert_eq!(ask(None, None, Some(&real_db), false), None, "MCI/dev.key");
    assert_eq!(
        ask(None, Some(&mci.join("dev.key")), Some(&real_db), false),
        None
    );
    assert_eq!(
        ask(None, Some(&demo.join("demo.key")), Some(&real_db), false),
        None
    );
    // A way out of the folder is no way in.
    let sneaky = demo.join("../../MCI/dev.key");
    assert_eq!(ask(None, Some(&sneaky), Some(&demo_db), false), None);
    // Demo Memory's key file, for Demo Memory's store: read.
    assert_eq!(
        ask(None, Some(&demo.join("demo.key")), Some(&demo_db), false),
        Some(hex.clone())
    );
    // Without the marker nothing is read in any build.
    let unmarked = DevelopmentKeyEnvironment {
        marker: Some("true"),
        raw_key: Some(&hex),
        key_file: None,
        db_path: Some(&real_db),
        home: Some(home.path()),
    };
    assert_eq!(unmarked.key_for_build(true), None);
    // With the development path, the developer's keys work as before.
    assert_eq!(
        ask(Some(&hex), None, Some(&real_db), true),
        Some(hex.clone())
    );
    assert_eq!(ask(None, None, Some(&real_db), true), Some(hex));
}

#[test]
fn only_debug_builds_or_the_explicit_feature_have_the_development_path() {
    assert_eq!(
        DEVELOPMENT_FILE_KEY_COMPILED_IN,
        cfg!(debug_assertions) || cfg!(feature = "development-file-key")
    );
}

/// Runs `program` against a throwaway memory whose key is offered only
/// through the development variables.
fn run(program: &str, args: &[&str], home: &Path, db: &Path, hex: &str) -> std::process::Output {
    Command::new(program)
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", hex)
        .env("MCI_DB_PATH", db)
        // A service that holds nothing: a lookup finds no item, and no
        // real Keychain item is ever asked for.
        .env(
            "MCI_DB_KEYCHAIN_SERVICE",
            "ai.hippocampus.test.development-key-gate.none",
        )
        .env("MCI_DB_KEYCHAIN_ACCOUNT", "none")
        .output()
        .expect("run the built program")
}

#[test]
fn the_built_programs_honour_the_development_key_only_when_built_with_it() {
    let home = tempfile::tempdir().unwrap();
    let (bytes, hex) = key_pair();
    let db: PathBuf = home
        .path()
        .join("Library/Application Support/MCI/mci.sqlite");
    memory(&db, bytes);
    std::fs::write(db.with_file_name("dev.key"), &hex).unwrap();
    let db_arg = db.to_str().unwrap();

    let brain = run(
        env!("CARGO_BIN_EXE_mci-brain"),
        &["stats", "--db-path", db_arg],
        home.path(),
        &db,
        &hex,
    );
    let agent = run(
        env!("CARGO_BIN_EXE_mci-agent"),
        &["stats", "--source", "safari", "--db-path", db_arg],
        home.path(),
        &db,
        &hex,
    );
    for (name, output) in [("mci-brain", &brain), ("mci-agent", &agent)] {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if DEVELOPMENT_FILE_KEY_COMPILED_IN {
            assert!(
                output.status.success(),
                "{name} (debug build) opens it with the development key: {stderr}"
            );
        } else {
            assert!(
                !output.status.success(),
                "{name} (release build) must ignore MCI_DEVELOPMENT_FILE_KEY, yet it opened the memory"
            );
            assert!(
                stderr.contains("Keychain"),
                "{name} went to the Keychain: {stderr}"
            );
        }
    }
}

#[test]
fn every_build_still_opens_demo_memory_with_its_own_key_file() {
    let home = tempfile::tempdir().unwrap();
    let (bytes, hex) = key_pair();
    let demo = demo_memory_folder(home.path());
    let db = demo.join("mci.sqlite");
    memory(&db, bytes);
    std::fs::write(demo.join("demo.key"), format!("{hex}\n")).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_mci-agent"))
        .args([
            "stats",
            "--source",
            "safari",
            "--db-path",
            db.to_str().unwrap(),
        ])
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/bin:/bin")
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_FILE", demo.join("demo.key"))
        .env("MCI_DB_PATH", &db)
        .env("MCI_DB_KEYCHAIN_SERVICE", "ai.hippocampus.demo-memory")
        .env("MCI_DB_KEYCHAIN_ACCOUNT", "none")
        .output()
        .expect("run mci-agent");
    assert!(
        output.status.success(),
        "Demo Memory opens: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
