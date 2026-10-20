//! `mci-agent` keeps what it writes owner-only: 0600 files, 0700 folders.
//!
//! The first launch used to leave the data folder, the database and its WAL
//! and SHM, `Application Support/Hippocampus` and `Logs/MCI` at 0755 and
//! 0644 (reports/e2e, finding 5). Each test starts the built binary from a
//! shell that sets the permissive umask 022 first, so the modes come from
//! the agent itself, and checks every path it left in a throwaway home.
//!
//! Every child runs with an explicitly built environment: a throwaway home,
//! a synthetic brain and the development key gate, never the Keychain.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

const KEY_HEX: &str = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";

fn built_bin(name: &str) -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push(name);
    path
}

fn agent_bin() -> PathBuf {
    built_bin("mci-agent")
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()))
        .permissions()
        .mode()
        & 0o7777
}

fn set_mode(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).expect("chmod");
}

/// The capture daemon on `db`, draining an empty stdin, started under umask 022.
fn drain(home: &Path, db: &Path) {
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"umask 022; exec "$0" "$@""#)
        .arg(agent_bin())
        .arg("--device-id-path")
        .arg(home.join(".mci/device-id"))
        .arg("--log-path")
        .arg(home.join("Library/Logs/MCI/helper-health.jsonl"))
        .arg("--db-path")
        .arg(db)
        .arg("--drain-stdin")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", KEY_HEX)
        .env("MCI_CAPTURE_ENABLED", "0")
        .env("MCI_UNDERSTANDING", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run mci-agent");
    assert!(
        status.success(),
        "the daemon drains EOF and exits 0: {status:?}"
    );
}

/// Every path under `root` that group or other accounts could read or enter.
fn readable_by_others(root: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(folder) = stack.pop() {
        for entry in std::fs::read_dir(&folder).expect("read_dir") {
            let path = entry.expect("entry").path();
            let metadata = std::fs::symlink_metadata(&path).expect("lstat");
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.permissions().mode() & 0o077 != 0 {
                found.push(format!(
                    "{:o} {}",
                    metadata.permissions().mode() & 0o7777,
                    path.strip_prefix(root).unwrap().display()
                ));
            }
            if metadata.is_dir() {
                stack.push(path);
            }
        }
    }
    found.sort();
    found
}

#[test]
fn a_new_install_is_owner_only_whatever_umask_the_agent_was_started_with() {
    let home = tempfile::tempdir().expect("temp home");
    let db = home
        .path()
        .join("Library/Application Support/MCI/mci.sqlite");

    drain(home.path(), &db);

    assert!(db.is_file(), "the daemon made the store");
    assert_eq!(mode(db.parent().unwrap()), 0o700, "the data folder");
    assert_eq!(mode(&db), 0o600, "the database");
    assert_eq!(
        readable_by_others(home.path()),
        Vec::<String>::new(),
        "nothing the agent wrote may be open to other accounts"
    );
}

#[test]
fn an_existing_install_is_made_owner_only_and_nothing_else_is_touched() {
    let home = tempfile::tempdir().expect("temp home");
    let support = home.path().join("Library/Application Support");
    let data = support.join("MCI");
    let locks = support.join("Hippocampus");
    let other = support.join("Another App");
    for folder in [&data, &locks, &other] {
        std::fs::create_dir_all(folder).expect("folder");
    }
    let db = data.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes([0x5a; 32])).expect("synthetic brain"));
    // As a 0.3.0 install left them.
    for name in ["mci.sqlite", "mci.sqlite-wal", "mci.sqlite-shm"] {
        let path = data.join(name);
        if path.exists() {
            set_mode(&path, 0o644);
        }
    }
    for folder in [&data, &locks, &other] {
        set_mode(folder, 0o755);
    }
    let theirs = other.join("settings.json");
    std::fs::write(&theirs, b"{}").expect("another app's file");
    set_mode(&theirs, 0o644);

    drain(home.path(), &db);

    assert_eq!(mode(&data), 0o700, "the data folder");
    assert_eq!(mode(&locks), 0o700, "the run-lock folder");
    for name in ["mci.sqlite", "mci.sqlite-wal", "mci.sqlite-shm"] {
        let path = data.join(name);
        if path.exists() {
            assert_eq!(mode(&path), 0o600, "{name}");
        }
    }
    assert_eq!(
        mode(&other),
        0o755,
        "another app's folder is not ours to change"
    );
    assert_eq!(
        mode(&theirs),
        0o644,
        "another app's file is not ours to change"
    );
}

#[test]
fn an_export_is_owner_only_whatever_umask_mci_brain_was_started_with() {
    let home = tempfile::tempdir().expect("temp home");
    let data = home.path().join("Library/Application Support/MCI");
    std::fs::create_dir_all(&data).expect("data folder");
    let db = data.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes([0x5a; 32])).expect("synthetic brain"));
    let export = home.path().join("Downloads/export.jsonl");
    std::fs::create_dir_all(export.parent().unwrap()).expect("downloads");

    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"umask 022; exec "$0" "$@""#)
        .arg(built_bin("mci-brain"))
        .arg("--db-path")
        .arg(&db)
        .arg("export")
        .arg("--out")
        .arg(&export)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home.path())
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", KEY_HEX)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run mci-brain");
    assert!(status.success(), "the export runs: {status:?}");
    assert_eq!(
        mode(&export),
        0o600,
        "a decrypted export is for its owner only"
    );
}
