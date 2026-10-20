//! Delete Everything as a crypto-shred (storage-security review S3).
//!
//! Deleting rows removes a moment from the live file only. Every earlier
//! copy of the memory (a Time Machine backup, an APFS snapshot, a stale log
//! frame, a copy someone took) stays readable for as long as its key lives,
//! and the key never changed. So erasing the memory destroys its key:
//!
//! 1. a marker says an erase is under way (`MCI/erasing`), so a crash or a
//!    refusal finishes it at the next start, and the old key is never used
//!    for a new memory;
//! 2. the memory's Keychain items are deleted: the usual one, and any a key
//!    change left;
//! 3. the database, its log and shared memory, every screenshot, a key
//!    change's backup, and every key file are deleted;
//! 4. the marker goes once the key is gone. The next `ensure-key` makes a
//!    new key, and the agent a new, empty memory.
//!
//! Every copy made before is then unreadable at once, wherever it is. The
//! caller holds the memory's writer lease: nothing is remembering.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::key_change::{self, KeychainDeleter, ADOPTED_MARKER, KEY_CHANGE_DIR};
use crate::key_resolver::{KeyResolutionError, DEFAULT_KEYCHAIN_ACCOUNT, ROTATED_KEYCHAIN_ACCOUNT};

/// The marker in the data folder while an erase is under way.
pub const ERASE_MARKER: &str = "erasing";

/// What an erase needs from the outside.
pub struct EraseContext<'a> {
    /// The data folder: `~/Library/Application Support/MCI`.
    pub support_dir: &'a Path,
    /// The database: `<support_dir>/mci.sqlite`.
    pub db_path: &'a Path,
    /// Keychain service of the memory's key.
    pub service: &'a str,
    /// Deletes Keychain items.
    pub deleter: &'a dyn KeychainDeleter,
}

/// What an erase removed. Content-free.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EraseReport {
    /// Database files removed (the database, its log, its shared memory).
    pub database_files_deleted: u64,
    /// Screenshot files removed.
    pub screenshots_deleted: u64,
    /// Key files removed.
    pub key_files_deleted: u64,
}

/// Why an erase did not finish. Content-free.
#[derive(Debug, Error)]
pub enum EraseError {
    /// The Keychain refused to delete the key: the files are gone, the
    /// marker stays, and the next start tries again before any key is used.
    #[error("the memory's key could not be deleted from the Keychain: {0}")]
    Keychain(#[from] KeyResolutionError),
    /// A file could not be removed.
    #[error("file: {0}")]
    Io(String),
}

/// Whether an erase was left unfinished.
#[must_use]
pub fn erase_pending(support_dir: &Path) -> bool {
    support_dir.join(ERASE_MARKER).exists()
}

/// Erase the memory and its key. Safe to repeat: an erase left unfinished
/// is finished by running it again.
///
/// # Errors
/// [`EraseError::Keychain`] when the key could not be deleted; every file
/// is gone by then. [`EraseError::Io`] when a file could not be removed.
pub fn erase_memory(ctx: &EraseContext<'_>) -> Result<EraseReport, EraseError> {
    write_marker(ctx.support_dir)?;
    let mut report = EraseReport::default();

    // The files first, so nothing is left to read even if the Keychain
    // refuses; the marker keeps the old key from being used again.
    let database_files = [
        ctx.db_path.to_path_buf(),
        sidecar(ctx.db_path, "-wal"),
        sidecar(ctx.db_path, "-shm"),
        sidecar(ctx.db_path, "-journal"),
        sidecar(ctx.db_path, ".restoring"),
    ];
    for path in &database_files {
        if remove_file_if_present(path)? {
            report.database_files_deleted += 1;
        }
    }
    let blob_dir = ctx
        .db_path
        .parent()
        .unwrap_or(ctx.support_dir)
        .join("blobs");
    report.screenshots_deleted = empty_dir(&blob_dir)?;
    remove_dir_all_if_present(&ctx.support_dir.join(KEY_CHANGE_DIR))?;
    for file in key_change::key_files(ctx.support_dir).map_err(|e| io("list key files", &e))? {
        key_change::shred_file(&file).map_err(|e| io("delete key file", &e))?;
        report.key_files_deleted += 1;
    }
    remove_file_if_present(&ctx.support_dir.join(ADOPTED_MARKER))?;
    sync_dir(ctx.support_dir);

    // Then the key: every copy of the memory made before is unreadable
    // from here on.
    for account in [ROTATED_KEYCHAIN_ACCOUNT, DEFAULT_KEYCHAIN_ACCOUNT] {
        ctx.deleter.delete_generic_password(ctx.service, account)?;
    }

    remove_file_if_present(&ctx.support_dir.join(ERASE_MARKER))?;
    sync_dir(ctx.support_dir);
    Ok(report)
}

fn write_marker(support_dir: &Path) -> Result<(), EraseError> {
    std::fs::create_dir_all(support_dir).map_err(|e| io("create data folder", &e))?;
    let path = support_dir.join(ERASE_MARKER);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(&path)
        .map_err(|e| io("write erase marker", &e))?;
    file.sync_all().map_err(|e| io("write erase marker", &e))?;
    sync_dir(support_dir);
    Ok(())
}

fn remove_file_if_present(path: &Path) -> Result<bool, EraseError> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io("delete", &error)),
    }
}

fn remove_dir_all_if_present(path: &Path) -> Result<(), EraseError> {
    match std::fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io("delete folder", &error)),
    }
}

/// Removes everything in `dir`, keeping the folder (the capture helper
/// writes into it). Returns how many files went.
fn empty_dir(dir: &Path) -> Result<u64, EraseError> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(io("list screenshots", &error)),
    };
    let mut removed = 0;
    for entry in entries {
        let entry = entry.map_err(|e| io("list screenshots", &e))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|e| io("inspect screenshot", &e))?;
        if file_type.is_dir() {
            remove_dir_all_if_present(&path)?;
        } else if remove_file_if_present(&path)? {
            removed += 1;
        }
    }
    sync_dir(dir);
    Ok(removed)
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn sync_dir(dir: &Path) {
    if let Ok(handle) = std::fs::File::open(dir) {
        let _ = handle.sync_all();
    }
}

fn io(context: &str, error: &dyn std::fmt::Display) -> EraseError {
    EraseError::Io(format!("{context}: {error}"))
}
