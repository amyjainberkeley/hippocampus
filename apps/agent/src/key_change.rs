//! A one-time change of the memory's key (storage-security review S4).
//!
//! Until Keychain custody landed, the key lived in plaintext at
//! `~/Library/Application Support/MCI/dev.key`, and the migration adopted that
//! same key as the Keychain item. Any copy of such a file decrypts the memory
//! and every screenshot sealed since. So when a `dev.key*` file is in the data
//! folder, or a marker says the key was adopted from one, the memory moves to
//! a fresh key, once, on upgrade:
//!
//! 1. an encrypted backup of the database, with the index of its
//!    screenshots, is kept under the old key;
//! 2. a new key is stored in the Keychain under a new account
//!    ([`ROTATED_KEYCHAIN_ACCOUNT`]), so both keys stay available;
//! 3. the database is re-encrypted in place (`PRAGMA rekey`) and proven by
//!    opening it again with the new key;
//! 4. every screenshot is re-sealed under the new key: each new file is
//!    written, read back and opened, then renamed into place, and the moments
//!    that name it are moved to it in one transaction that also records the
//!    move;
//! 5. everything is verified: every moment reads, and every screenshot that
//!    opened before opens now, with the new key;
//! 6. only then is the change committed (the journal's pointer moves to the
//!    new key), and the old screenshots, the backup, every `dev.key*` file
//!    and the old Keychain item are deleted. The new key then goes back under
//!    the usual account ([`DEFAULT_KEYCHAIN_ACCOUNT`]) and the item under the
//!    new account goes, so a finished change leaves the Keychain exactly as a
//!    fresh install does, and an older Hippocampus still reads it.
//!
//! Every step is recorded in a content-free journal
//! (`MCI/key-change/journal.json`), so a crash, a quit or a kill at any point
//! resumes where it stopped. Readers of the default item try the new account
//! first and keep the key that opens the memory
//! ([`crate::key_resolver::resolve_current_database_key`]), so connected AI
//! tools keep working throughout. A failure before the commit is undone at
//! once: moments point at their original screenshots again, the database goes
//! back to the old key, the new files and the new Keychain item go; the next
//! try waits a day. After the commit nothing is undone: what is left of the
//! cleanup is finished by the next launch, and the memory works meanwhile.
//!
//! It never starts when it can't prove it can roll back: the caller must hold
//! the memory's writer lease; the old key must open the database, which must
//! pass `quick_check`; there must be room for the backup, the re-encryption
//! and a second copy of every screenshot; the backup must open and match;
//! and the new key must be stored and read back before the database is
//! touched. When any of these fails, nothing changes.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

use mci_brain::key_change::BlobIndexEntry;
use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

pub use crate::key_resolver::ROTATED_KEYCHAIN_ACCOUNT;
use crate::key_resolver::{
    is_valid_database_key, KeyResolutionError, KeychainReader, KeychainWriter,
    DEFAULT_KEYCHAIN_ACCOUNT,
};

/// Folder in the data folder for the journal and the backup.
pub const KEY_CHANGE_DIR: &str = "key-change";
/// The journal inside [`KEY_CHANGE_DIR`].
pub const JOURNAL_FILE: &str = "journal.json";
/// The encrypted backup inside [`KEY_CHANGE_DIR`], under the old key.
pub const BACKUP_FILE: &str = "backup.sqlite";
/// The record of undone changes inside [`KEY_CHANGE_DIR`]: how many, and when
/// the last one was.
pub const UNDONE_FILE: &str = "undone.json";
/// Written in the data folder before a `dev.key` is adopted as the Keychain
/// key, so the change still runs if the file is gone by the next launch.
pub const ADOPTED_MARKER: &str = "key-adopted-from-file";
/// Every file in the data folder whose name starts with this is a copy of a
/// key: the trigger, and deleted once the change is committed.
pub const KEY_FILE_PREFIX: &str = "dev.key";

/// Room kept free beyond what the change writes.
pub const SPACE_MARGIN_BYTES: u64 = 256 * 1024 * 1024;
/// The largest screenshot file the change reads.
pub const MAX_BLOB_BYTES: u64 = 128 * 1024 * 1024;
/// Screenshots moved per database transaction.
pub const RESEAL_BATCH: usize = 32;
/// Runs of one change (the first and every resume) before it is undone.
pub const MAX_ATTEMPTS: u32 = 6;
/// After a change was undone, the next one waits this long.
pub const RETRY_AFTER_UNDO_MS: u64 = 24 * 60 * 60 * 1000;
/// After this many undone changes, no new one starts.
pub const MAX_UNDOS: u32 = 3;

const JOURNAL_VERSION: u32 = 1;
const SALT_CONTEXT: &[u8] = b"hippocampus key change salt v1";
const NONCE_CONTEXT: &[u8] = b"hippocampus key change nonce v1";

/// Where the change has got to. Each phase is recorded once its step is done
/// and durable.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    /// The journal exists; the backup may be partial.
    Started,
    /// The backup and its screenshot index are written and verified.
    BackedUp,
    /// The new key is in the Keychain and was read back.
    KeyAdded,
    /// The database opens with the new key only.
    Rekeyed,
    /// Every screenshot that opened before is re-sealed and named.
    Resealed,
    /// Everything opens with the new key.
    Verified,
    /// The new key is the memory's key; only cleanup remains.
    Committed,
}

/// The content-free journal: phases, accounts and counts, never a key, a
/// path inside the memory or anything a moment holds.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Journal {
    /// Format of this file.
    pub version: u32,
    /// Where the change has got to.
    pub phase: Phase,
    /// Keychain service of both items.
    pub service: String,
    /// The account holding the old key.
    pub from_account: String,
    /// The account holding the new key until the change is finished.
    pub to_account: String,
    /// Moments when the change began.
    pub moments_before: u64,
    /// Distinct screenshots the memory named when the change began.
    pub screenshots_before: u64,
    /// Of those, how many already did not open (missing, damaged, or sealed
    /// under some other key). They stay as they are.
    pub unreadable_before: u64,
    /// How many times the change has been started or resumed.
    pub attempts: u32,
    /// When it began, milliseconds since the epoch.
    pub started_unix_ms: u64,
}

/// The record of undone changes.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct UndoneRecord {
    /// Changes undone so far.
    pub count: u32,
    /// When the last one was undone, milliseconds since the epoch.
    pub last_unix_ms: u64,
}

/// What happened, for the `ensure-key` line and the tests. Content-free.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KeyChangeOutcome {
    /// No key file, no marker, nothing unfinished: the key never sat in a
    /// file.
    NotNeeded,
    /// No change was due, but the Keychain held the memory's key in an
    /// unusual place, and it was put back.
    Settled(String),
    /// A change is due, but it can't be proven safe now; nothing changed.
    Deferred(String),
    /// The memory moved to a new key.
    Changed(KeyChangeReport),
    /// The change failed before its commit and was undone: the memory is
    /// back on its old key, exactly as before.
    RolledBack(String),
}

/// Counts from a finished change.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct KeyChangeReport {
    /// Moments in the memory.
    pub moments: u64,
    /// Screenshots re-sealed under the new key.
    pub screenshots_resealed: u64,
    /// Screenshots that did not open before the change and were left alone.
    pub screenshots_unreadable: u64,
    /// `dev.key*` files deleted.
    pub key_files_deleted: u64,
    /// Whether the old key is gone from the Keychain.
    pub old_key_deleted: bool,
    /// Whether the new key is back under the usual account and the item
    /// under the new account is gone: the change left nothing behind.
    pub finished: bool,
    /// What the cleanup could not do yet; the next launch does it. The
    /// memory is under the new key either way.
    pub cleanup_pending: Option<String>,
    /// Whether this run resumed an interrupted change.
    pub resumed: bool,
    /// Wall time of this run.
    pub elapsed_ms: u64,
}

/// A failure that leaves an unfinished change for the next launch to resume.
/// Content-free.
#[derive(Debug, Error)]
pub enum KeyChangeError {
    /// A Keychain read, add or delete failed.
    #[error("Keychain: {0}")]
    Keychain(#[from] KeyResolutionError),
    /// The memory could not be opened, read or written.
    #[error("memory: {0}")]
    Store(String),
    /// A file could not be read, written, renamed or removed.
    #[error("file: {0}")]
    Io(String),
    /// The journal could not be read or written.
    #[error("journal: {0}")]
    Journal(String),
    /// The undo itself failed; the journal stays so the next launch tries
    /// again.
    #[error("undo after a failure: {0}")]
    Rollback(String),
    /// A test checkpoint stopped the change (tests only).
    #[error("stopped at {0:?}")]
    Stopped(Step),
}

fn store_error(context: &str, error: impl std::fmt::Display) -> KeyChangeError {
    KeyChangeError::Store(format!("{context}: {error}"))
}

fn io_error(context: &str, error: impl std::fmt::Display) -> KeyChangeError {
    KeyChangeError::Io(format!("{context}: {error}"))
}

/// Seals and opens screenshots: the agent's copy of `KeyframeBlobCodec`.
pub trait Envelope {
    /// The plaintext, when `blob` authenticates under `key`.
    fn open(&self, blob: &[u8], key: &[u8; 32]) -> Option<Zeroizing<Vec<u8>>>;
    /// `plaintext` sealed under `key` with this salt and nonce.
    ///
    /// # Errors
    /// A content-free reason.
    fn seal(
        &self,
        plaintext: &[u8],
        key: &[u8; 32],
        salt: &[u8; 16],
        nonce: &[u8; 12],
    ) -> Result<Vec<u8>, String>;
}

/// The production envelope: `mci_keychain::envelope`, byte for byte the
/// capture helper's `KeyframeBlobCodec`.
#[cfg(target_os = "macos")]
pub struct SealedScreenshotEnvelope;

#[cfg(target_os = "macos")]
impl Envelope for SealedScreenshotEnvelope {
    fn open(&self, blob: &[u8], key: &[u8; 32]) -> Option<Zeroizing<Vec<u8>>> {
        mci_keychain::envelope::open(blob, key).ok()
    }

    fn seal(
        &self,
        plaintext: &[u8],
        key: &[u8; 32],
        salt: &[u8; 16],
        nonce: &[u8; 12],
    ) -> Result<Vec<u8>, String> {
        mci_keychain::envelope::seal(plaintext, key, salt, nonce).map_err(|e| format!("{e:?}"))
    }
}

/// Free space on the volume that holds a path.
pub trait SpaceProbe {
    /// Bytes this user may still write there.
    ///
    /// # Errors
    /// The volume could not be inspected.
    fn available_bytes(&self, path: &Path) -> std::io::Result<u64>;
}

/// The volume's own count (`statvfs`).
pub struct VolumeSpace;

impl SpaceProbe for VolumeSpace {
    #[cfg(unix)]
    fn available_bytes(&self, path: &Path) -> std::io::Result<u64> {
        let stats = rustix::fs::statvfs(path).map_err(std::io::Error::from)?;
        Ok(stats.f_bavail.saturating_mul(stats.f_frsize))
    }

    #[cfg(not(unix))]
    fn available_bytes(&self, _path: &Path) -> std::io::Result<u64> {
        Err(std::io::Error::other(
            "free space is unknown on this platform",
        ))
    }
}

/// Deletes a generic-password item; deleting one that is not there succeeds.
pub trait KeychainDeleter {
    /// Delete one item.
    ///
    /// # Errors
    /// The Keychain refused (locked, denied, other).
    fn delete_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<(), KeyResolutionError>;
}

/// Each place the change can stop. Tests stop the process at every one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    /// The journal was just written for the first time.
    JournalWritten,
    /// The backup file exists; its index may be missing.
    BackupWritten,
    /// The backup is verified and recorded.
    BackedUp,
    /// The new key was added to the Keychain, not yet recorded.
    KeyAddedUnrecorded,
    /// The new key is recorded.
    KeyAdded,
    /// `PRAGMA rekey` ran, not yet proven.
    RekeyRan,
    /// The re-encryption is proven and recorded.
    Rekeyed,
    /// One re-sealed screenshot file is in place, its moments not yet moved.
    ScreenshotWritten,
    /// A batch of moments now names re-sealed screenshots.
    BatchMoved,
    /// Every screenshot is re-sealed and recorded.
    Resealed,
    /// Verification passed and is recorded.
    Verified,
    /// The commit is recorded: the new key is the memory's key.
    Committed,
    /// The old screenshots are deleted.
    OldScreenshotsDeleted,
    /// The backup is deleted.
    BackupDeleted,
    /// The key files and the marker are deleted.
    KeyFilesDeleted,
    /// The old Keychain item is deleted.
    OldKeyDeleted,
    /// The new key is stored under the usual account again.
    KeyRestored,
    /// The item under the new account is deleted.
    RotatedKeyDeleted,
}

/// Called at every [`Step`]. Production does nothing; tests stop there.
pub trait Checkpoints {
    /// The change reached `step`.
    ///
    /// # Errors
    /// [`KeyChangeError::Stopped`] to stop the change at this point.
    fn reached(&self, step: Step) -> Result<(), KeyChangeError>;
}

/// No checkpoints: production.
pub struct NoCheckpoints;

impl Checkpoints for NoCheckpoints {
    fn reached(&self, _step: Step) -> Result<(), KeyChangeError> {
        Ok(())
    }
}

/// What the change needs from the outside, injectable so every failure can
/// be tested without the real Keychain.
pub struct KeyChangeContext<'a> {
    /// The data folder: `~/Library/Application Support/MCI`.
    pub support_dir: &'a Path,
    /// The database: `<support_dir>/mci.sqlite`.
    pub db_path: &'a Path,
    /// Keychain service of the memory's key.
    pub service: &'a str,
    /// Reads Keychain items.
    pub reader: &'a dyn KeychainReader,
    /// Adds Keychain items, with the bundle's ACL.
    pub writer: &'a dyn KeychainWriter,
    /// Deletes Keychain items.
    pub deleter: &'a dyn KeychainDeleter,
    /// Executables the new item trusts (the same four as the old one's ACL).
    pub trusted_application_paths: &'a [PathBuf],
    /// Seals and opens screenshots.
    pub envelope: &'a dyn Envelope,
    /// Free space.
    pub space: &'a dyn SpaceProbe,
    /// Makes a new random 64-hex key.
    pub generate: &'a dyn Fn() -> Result<String, KeyResolutionError>,
    /// Test stops.
    pub checkpoints: &'a dyn Checkpoints,
}

impl KeyChangeContext<'_> {
    fn dir(&self) -> PathBuf {
        self.support_dir.join(KEY_CHANGE_DIR)
    }

    fn journal_path(&self) -> PathBuf {
        self.dir().join(JOURNAL_FILE)
    }

    fn backup_path(&self) -> PathBuf {
        self.dir().join(BACKUP_FILE)
    }

    fn undone_path(&self) -> PathBuf {
        self.dir().join(UNDONE_FILE)
    }

    fn blob_dir(&self) -> PathBuf {
        self.db_path
            .parent()
            .unwrap_or(self.support_dir)
            .join("blobs")
    }

    fn reached(&self, step: Step) -> Result<(), KeyChangeError> {
        self.checkpoints.reached(step)
    }

    /// The item under `account`: `Ok(None)` when it does not exist.
    fn read_optional(&self, account: &str) -> Result<Option<String>, KeyChangeError> {
        match self.reader.read_generic_password(self.service, account) {
            Ok(value) if is_valid_database_key(&value) => Ok(Some(value)),
            Ok(_) => Err(KeyResolutionError::InvalidKey.into()),
            Err(KeyResolutionError::MissingKey { .. }) => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// The item under `account`, which must exist.
    fn read_item(&self, account: &str) -> Result<String, KeyChangeError> {
        self.read_optional(account)?.ok_or_else(|| {
            KeyChangeError::Keychain(KeyResolutionError::MissingKey {
                service: self.service.to_owned(),
                account: account.to_owned(),
            })
        })
    }

    fn delete_item(&self, account: &str) -> Result<(), KeyChangeError> {
        self.deleter
            .delete_generic_password(self.service, account)
            .map_err(KeyChangeError::Keychain)
    }

    /// Store `value` under `account` and prove it reads back.
    fn add_item(&self, account: &str, value: &str) -> Result<(), KeyChangeError> {
        self.writer.add_generic_password(
            self.service,
            account,
            value,
            self.trusted_application_paths,
        )?;
        if self.read_item(account)? == value {
            Ok(())
        } else {
            Err(KeyResolutionError::PostAddReadFailed {
                source: Box::new(KeyResolutionError::InvalidKey),
            }
            .into())
        }
    }
}

/// Every `dev.key*` regular file or link in the data folder, sorted. A link
/// is listed by its own path; its target is never touched.
///
/// # Errors
/// The folder exists but can't be listed.
pub fn key_files(support_dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    let entries = match std::fs::read_dir(support_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with(KEY_FILE_PREFIX) {
            continue;
        }
        let file_type = entry.file_type()?;
        if file_type.is_file() || file_type.is_symlink() {
            files.push(entry.path());
        }
    }
    files.sort();
    Ok(files)
}

/// Whether a change is due: a `dev.key*` file is in the data folder, or the
/// adoption marker is.
///
/// # Errors
/// The folder can't be inspected.
pub fn key_change_due(support_dir: &Path) -> std::io::Result<bool> {
    Ok(!key_files(support_dir)?.is_empty() || support_dir.join(ADOPTED_MARKER).exists())
}

/// Whether a change was left unfinished: its journal is there.
#[must_use]
pub fn key_change_unfinished(support_dir: &Path) -> bool {
    support_dir.join(KEY_CHANGE_DIR).join(JOURNAL_FILE).exists()
}

/// Record that the key about to be adopted came from a file. Written before
/// the file is removed, so the change still runs after a crash in between.
///
/// # Errors
/// The marker could not be written durably.
pub fn mark_key_adopted_from_file(support_dir: &Path) -> std::io::Result<()> {
    write_private_durably(
        &support_dir.join(ADOPTED_MARKER),
        b"The memory's key was adopted from a file; it will be changed.\n",
    )
}

/// Finish or undo an unfinished change, and put a key left under the new
/// account back in order. Never starts a change: `ensure-key` runs this
/// before it reads the usual item, which a change may have emptied.
///
/// # Errors
/// The Keychain can't be put in an order every reader agrees on, or an
/// unfinished change could neither go on nor be undone. The memory's
/// programs must not start then.
pub fn settle_key_change(ctx: &KeyChangeContext<'_>) -> Result<KeyChangeOutcome, KeyChangeError> {
    let started = Instant::now();
    if let Some(journal) = load_journal(ctx)? {
        return resume(ctx, journal, started);
    }
    Ok(settle(ctx)?.map_or(KeyChangeOutcome::NotNeeded, KeyChangeOutcome::Settled))
}

/// Run, or resume, the change. Holds no lease itself: the caller holds the
/// memory's writer lease for the whole call.
///
/// # Errors
/// As [`settle_key_change`]. A change that can't start safely is
/// [`KeyChangeOutcome::Deferred`], never an error.
pub fn run_key_change(ctx: &KeyChangeContext<'_>) -> Result<KeyChangeOutcome, KeyChangeError> {
    let started = Instant::now();
    if let Some(journal) = load_journal(ctx)? {
        return resume(ctx, journal, started);
    }
    let settled = settle(ctx)?;
    if !key_change_due(ctx.support_dir).map_err(|e| io_error("inspect data folder", e))? {
        return Ok(settled.map_or(KeyChangeOutcome::NotNeeded, KeyChangeOutcome::Settled));
    }
    if let Some(reason) = waiting_after_undo(ctx) {
        return Ok(KeyChangeOutcome::Deferred(reason));
    }
    start(ctx, started)
}

fn load_journal(ctx: &KeyChangeContext<'_>) -> Result<Option<Journal>, KeyChangeError> {
    match read_journal(&ctx.journal_path()) {
        Ok(journal) => Ok(journal),
        // A journal that can't be parsed (it is written atomically, so only
        // damage does this) is rebuilt from what the files say.
        Err(KeyChangeError::Journal(_)) => rebuild_journal(ctx).map(Some),
        Err(error) => Err(error),
    }
}

/// The phase a damaged journal must have had: the database under the new
/// key means at least [`Phase::Rekeyed`], whose steps all repeat safely;
/// otherwise nothing in the memory changed yet, and the backup is redone.
fn rebuild_journal(ctx: &KeyChangeContext<'_>) -> Result<Journal, KeyChangeError> {
    let rekeyed = match ctx.read_optional(ROTATED_KEYCHAIN_ACCOUNT)? {
        Some(new_hex) => ctx.db_path.exists() && opens(ctx.db_path, &new_hex),
        None => false,
    };
    let journal = Journal {
        version: JOURNAL_VERSION,
        phase: if rekeyed {
            Phase::Rekeyed
        } else {
            Phase::Started
        },
        service: ctx.service.to_owned(),
        from_account: DEFAULT_KEYCHAIN_ACCOUNT.to_owned(),
        to_account: ROTATED_KEYCHAIN_ACCOUNT.to_owned(),
        moments_before: u64::MAX,
        screenshots_before: 0,
        unreadable_before: 0,
        attempts: 1,
        started_unix_ms: unix_ms(),
    };
    write_journal(&ctx.journal_path(), &journal)?;
    Ok(journal)
}

fn resume(
    ctx: &KeyChangeContext<'_>,
    mut journal: Journal,
    started: Instant,
) -> Result<KeyChangeOutcome, KeyChangeError> {
    journal.attempts = journal.attempts.saturating_add(1);
    if journal.phase < Phase::Committed && journal.attempts > MAX_ATTEMPTS {
        roll_back(ctx, &journal)?;
        return Ok(KeyChangeOutcome::RolledBack(format!(
            "the key change did not finish after {MAX_ATTEMPTS} tries"
        )));
    }
    write_journal(&ctx.journal_path(), &journal)?;
    proceed(ctx, journal, true, started)
}

/// With no change under way, the memory's key belongs under the usual
/// account, and nothing under the new one. Readers of the default item use a
/// key under the new account first, so one left there that opens nothing
/// would have screenshots sealed under the wrong key. `Ok(Some(note))` when
/// something was put right.
fn settle(ctx: &KeyChangeContext<'_>) -> Result<Option<String>, KeyChangeError> {
    let Some(rotated) = ctx.read_optional(ROTATED_KEYCHAIN_ACCOUNT)? else {
        return Ok(None);
    };
    let usual = ctx.read_optional(DEFAULT_KEYCHAIN_ACCOUNT)?;
    let memory = ctx.db_path.exists();
    if usual.as_deref() == Some(rotated.as_str()) {
        // Both hold the same key, so every reader agrees either way.
        return Ok(Some(match ctx.delete_item(ROTATED_KEYCHAIN_ACCOUNT) {
            Ok(()) => "removed a second copy of the key".to_owned(),
            Err(error) => format!("a second copy of the key is still stored: {error}"),
        }));
    }
    if let Some(usual) = usual.as_deref() {
        if !memory || opens(ctx.db_path, usual) {
            // The usual item is the memory's key: the other opens nothing.
            ctx.delete_item(ROTATED_KEYCHAIN_ACCOUNT)?;
            return Ok(Some("removed a key that opened nothing".to_owned()));
        }
    }
    if memory && !opens(ctx.db_path, &rotated) {
        return Err(store_error(
            "settle the Keychain",
            "no Keychain item opens the memory",
        ));
    }
    // The memory's key is under the new account only: put it back. Until
    // that is done, readers find it where it is.
    match move_key_to_usual_account(ctx, &rotated, usual.is_some()) {
        Ok(()) => Ok(Some("moved the key back to its usual place".to_owned())),
        Err(error) => Ok(Some(format!(
            "the key is still under the new account ({error}); readers use it there"
        ))),
    }
}

/// Delete the usual item if there is one (it is not the memory's key), add
/// `value` there, prove it, then delete the item under the new account.
fn move_key_to_usual_account(
    ctx: &KeyChangeContext<'_>,
    value: &str,
    usual_exists: bool,
) -> Result<(), KeyChangeError> {
    if usual_exists {
        ctx.delete_item(DEFAULT_KEYCHAIN_ACCOUNT)?;
    }
    ctx.add_item(DEFAULT_KEYCHAIN_ACCOUNT, value)?;
    ctx.delete_item(ROTATED_KEYCHAIN_ACCOUNT)
}

fn waiting_after_undo(ctx: &KeyChangeContext<'_>) -> Option<String> {
    let record = read_undone(&ctx.undone_path())?;
    if record.count >= MAX_UNDOS {
        return Some(format!(
            "the key change was undone {} times; it is not tried again",
            record.count
        ));
    }
    let waited = unix_ms().saturating_sub(record.last_unix_ms);
    (waited < RETRY_AFTER_UNDO_MS)
        .then(|| "the last key change was undone less than a day ago".to_owned())
}

fn start(ctx: &KeyChangeContext<'_>, started: Instant) -> Result<KeyChangeOutcome, KeyChangeError> {
    // After `settle`, nothing is under the new account unless it could not
    // be moved; a change never starts beside it.
    match ctx.read_optional(ROTATED_KEYCHAIN_ACCOUNT) {
        Ok(None) => {}
        Ok(Some(_)) => {
            return Ok(KeyChangeOutcome::Deferred(
                "a key is still stored under the new account".to_owned(),
            ))
        }
        Err(error) => {
            return Ok(KeyChangeOutcome::Deferred(format!(
                "the Keychain can't be used now: {error}"
            )))
        }
    }
    let old_hex = match ctx.read_optional(DEFAULT_KEYCHAIN_ACCOUNT) {
        Ok(Some(value)) => Zeroizing::new(value),
        Ok(None) => {
            return Ok(KeyChangeOutcome::Deferred(
                "there is no key in the Keychain yet".to_owned(),
            ))
        }
        Err(error) => {
            return Ok(KeyChangeOutcome::Deferred(format!(
                "the current key can't be read: {error}"
            )))
        }
    };

    if !ctx.db_path.exists() {
        // No memory yet: nothing is encrypted under the old key. The key
        // itself is replaced, and the key files go.
        return replace_key_without_memory(ctx, started);
    }

    let old_key = key_from_hex(&old_hex)?;
    let precheck = match precheck(ctx, &old_key) {
        Ok(precheck) => precheck,
        Err(reason) => return Ok(KeyChangeOutcome::Deferred(reason)),
    };

    let journal = Journal {
        version: JOURNAL_VERSION,
        phase: Phase::Started,
        service: ctx.service.to_owned(),
        from_account: DEFAULT_KEYCHAIN_ACCOUNT.to_owned(),
        to_account: ROTATED_KEYCHAIN_ACCOUNT.to_owned(),
        moments_before: precheck.moments,
        screenshots_before: precheck.screenshots,
        unreadable_before: 0,
        attempts: 1,
        started_unix_ms: unix_ms(),
    };
    create_private_dir(&ctx.dir()).map_err(|e| io_error("create key-change folder", e))?;
    write_journal(&ctx.journal_path(), &journal)?;
    ctx.reached(Step::JournalWritten)?;
    proceed(ctx, journal, false, started)
}

struct Precheck {
    moments: u64,
    screenshots: u64,
}

/// Everything that must hold before anything changes. `Err` is the reason
/// the change is deferred.
fn precheck(ctx: &KeyChangeContext<'_>, old_key: &[u8; 32]) -> Result<Precheck, String> {
    let store = SqlCipherBrainStore::open_readonly(ctx.db_path, &DbKey::from_bytes(*old_key))
        .map_err(|e| format!("the current key does not open the memory: {e}"))?;
    store
        .quick_check()
        .map_err(|e| format!("the memory does not read back whole: {e}"))?;
    let moments = store
        .stats()
        .map_err(|e| format!("the memory can't be counted: {e}"))?
        .event_count;
    let digests = store
        .referenced_keyframe_digests()
        .map_err(|e| format!("the screenshots can't be listed: {e}"))?;
    drop(store);

    let blob_dir = ctx.blob_dir();
    let mut blob_bytes = 0_u64;
    for digest in &digests {
        if let Ok(metadata) = std::fs::symlink_metadata(blob_dir.join(format!("{digest}.bin"))) {
            blob_bytes = blob_bytes.saturating_add(metadata.len());
        }
    }
    let database_bytes =
        file_len(ctx.db_path).saturating_add(file_len(&sidecar(ctx.db_path, "-wal")));
    // The backup, the re-encrypted pages in the log, and a second copy of
    // every screenshot until the old ones go, plus a margin.
    let needed = database_bytes
        .saturating_mul(2)
        .saturating_add(blob_bytes)
        .saturating_add(SPACE_MARGIN_BYTES);
    let available = ctx
        .space
        .available_bytes(ctx.support_dir)
        .map_err(|e| format!("free space can't be measured: {e}"))?;
    if available < needed {
        return Err(format!(
            "not enough free space: the change needs {needed} bytes, {available} are free"
        ));
    }
    Ok(Precheck {
        moments,
        screenshots: digests.len() as u64,
    })
}

fn proceed(
    ctx: &KeyChangeContext<'_>,
    mut journal: Journal,
    resumed: bool,
    started: Instant,
) -> Result<KeyChangeOutcome, KeyChangeError> {
    let mut resealed = 0_u64;
    if journal.phase < Phase::Committed {
        let failure = match advance(ctx, &mut journal, &mut resealed) {
            Ok(None) => None,
            Ok(Some(reason)) => Some(reason),
            // A test's stop is a crash: the next run resumes.
            Err(KeyChangeError::Stopped(step)) => return Err(KeyChangeError::Stopped(step)),
            Err(error) => Some(error.to_string()),
        };
        if let Some(reason) = failure {
            roll_back(ctx, &journal)?;
            return Ok(KeyChangeOutcome::RolledBack(reason));
        }
    }
    // After the commit the memory is under the new key, and readers find it
    // under either account: cleanup that fails now is finished next launch.
    let mut report = match clean_up(ctx, &journal) {
        Ok(report) => report,
        Err(KeyChangeError::Stopped(step)) => return Err(KeyChangeError::Stopped(step)),
        Err(error) => KeyChangeReport {
            screenshots_unreadable: journal.unreadable_before,
            cleanup_pending: Some(error.to_string()),
            ..KeyChangeReport::default()
        },
    };
    report.screenshots_resealed = resealed.max(report.screenshots_resealed);
    report.resumed = resumed;
    report.elapsed_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    Ok(KeyChangeOutcome::Changed(report))
}

/// Every step up to the commit. `Ok(Some(reason))` when a verification
/// failed.
fn advance(
    ctx: &KeyChangeContext<'_>,
    journal: &mut Journal,
    resealed: &mut u64,
) -> Result<Option<String>, KeyChangeError> {
    if journal.phase < Phase::BackedUp {
        let old_hex = Zeroizing::new(ctx.read_item(&journal.from_account)?);
        back_up(ctx, journal, &key_from_hex(&old_hex)?)?;
    }
    if journal.phase < Phase::KeyAdded {
        add_new_key(ctx, journal)?;
    }
    let old_key = key_from_hex(&Zeroizing::new(ctx.read_item(&journal.from_account)?))?;
    let new_key = key_from_hex(&Zeroizing::new(ctx.read_item(&journal.to_account)?))?;
    if journal.phase < Phase::Rekeyed {
        if let Err(reason) = rekey(ctx, journal, &old_key, &new_key)? {
            return Ok(Some(reason));
        }
    }
    if journal.phase < Phase::Resealed {
        *resealed = reseal(ctx, journal, &old_key, &new_key)?;
    }
    if journal.phase < Phase::Verified {
        if let Err(reason) = verify(ctx, journal, &new_key)? {
            return Ok(Some(reason));
        }
    }
    journal.phase = Phase::Committed;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::Committed)?;
    Ok(None)
}

/// Step 1: the encrypted backup, under the old key, with the screenshot
/// index; then proof that it opens and matches.
fn back_up(
    ctx: &KeyChangeContext<'_>,
    journal: &mut Journal,
    old_key: &[u8; 32],
) -> Result<(), KeyChangeError> {
    let backup = ctx.backup_path();
    remove_database_files(&backup)?;
    create_private_dir(&ctx.dir()).map_err(|e| io_error("create key-change folder", e))?;
    let db_key = DbKey::from_bytes(*old_key);
    let live = SqlCipherBrainStore::new(ctx.db_path, &db_key)
        .map_err(|e| store_error("open memory", e))?;
    // Best effort: `VACUUM INTO` reads through the log either way.
    let _ = live.checkpoint_wal();
    live.vacuum_into(&backup)
        .map_err(|e| store_error("backup", e))?;
    let digests = live
        .referenced_keyframe_digests()
        .map_err(|e| store_error("list screenshots", e))?;
    let moments = live
        .stats()
        .map_err(|e| store_error("count", e))?
        .event_count;
    drop(live);
    restrict_file(&backup)?;
    ctx.reached(Step::BackupWritten)?;

    let blob_dir = ctx.blob_dir();
    let mut index = Vec::with_capacity(digests.len());
    for digest in &digests {
        let path = blob_dir.join(format!("{digest}.bin"));
        let (bytes, opened) = match read_blob(&path) {
            Ok(Some(blob)) => {
                let opened =
                    sha256_hex(&blob) == *digest && ctx.envelope.open(&blob, old_key).is_some();
                (blob.len() as u64, opened)
            }
            Ok(None) | Err(_) => (0, false),
        };
        index.push(BlobIndexEntry {
            digest: digest.clone(),
            bytes,
            opened,
        });
    }
    let copy =
        SqlCipherBrainStore::new(&backup, &db_key).map_err(|e| store_error("open backup", e))?;
    copy.record_blob_index(&index)
        .map_err(|e| store_error("record screenshot index", e))?;
    copy.checkpoint_wal()
        .map_err(|e| store_error("checkpoint backup", e))?;
    drop(copy);

    let check = SqlCipherBrainStore::open_readonly(&backup, &db_key)
        .map_err(|e| store_error("reopen backup", e))?;
    check
        .quick_check()
        .map_err(|e| store_error("backup quick_check", e))?;
    let copied = check
        .stats()
        .map_err(|e| store_error("count backup", e))?
        .event_count;
    let recorded = check
        .blob_index()
        .map_err(|e| store_error("read screenshot index", e))?;
    drop(check);
    if copied != moments || recorded.len() != index.len() {
        return Err(store_error(
            "backup",
            format!(
                "it holds {copied} of {moments} moments and {} of {} screenshots",
                recorded.len(),
                index.len()
            ),
        ));
    }
    restrict_file(&backup)?;
    sync_file(&backup)?;
    sync_dir(&ctx.dir())?;

    journal.moments_before = moments;
    journal.screenshots_before = index.len() as u64;
    journal.unreadable_before = index.iter().filter(|entry| !entry.opened).count() as u64;
    journal.phase = Phase::BackedUp;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::BackedUp)
}

/// Step 2: the new key, under the new account, read back. An item a crash
/// left there before it was recorded is used again, never replaced.
fn add_new_key(ctx: &KeyChangeContext<'_>, journal: &mut Journal) -> Result<(), KeyChangeError> {
    let new_hex = if let Some(value) = ctx.read_optional(&journal.to_account)? {
        Zeroizing::new(value)
    } else {
        let generated = Zeroizing::new((ctx.generate)()?);
        if !is_valid_database_key(&generated) {
            return Err(KeyResolutionError::InvalidKey.into());
        }
        ctx.writer.add_generic_password(
            ctx.service,
            &journal.to_account,
            &generated,
            ctx.trusted_application_paths,
        )?;
        ctx.reached(Step::KeyAddedUnrecorded)?;
        let reread = Zeroizing::new(ctx.read_item(&journal.to_account)?);
        if *reread != *generated {
            return Err(KeyResolutionError::PostAddReadFailed {
                source: Box::new(KeyResolutionError::InvalidKey),
            }
            .into());
        }
        reread
    };
    let old_hex = Zeroizing::new(ctx.read_item(&journal.from_account)?);
    if *new_hex == *old_hex {
        return Err(KeyResolutionError::InvalidKey.into());
    }
    journal.phase = Phase::KeyAdded;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::KeyAdded)
}

/// Step 3: `PRAGMA rekey`, proven by opening the file again. `Ok(Err(reason))`
/// means it could not be done and should be undone.
fn rekey(
    ctx: &KeyChangeContext<'_>,
    journal: &mut Journal,
    old_key: &[u8; 32],
    new_key: &[u8; 32],
) -> Result<Result<(), String>, KeyChangeError> {
    if !opens_with_bytes(ctx.db_path, new_key) {
        if !opens_with_bytes(ctx.db_path, old_key) {
            // Neither key opens it: the file is damaged. The backup, under
            // the old key, goes back in place before anything else.
            restore_backup(ctx, old_key)?;
        }
        let store = SqlCipherBrainStore::new(ctx.db_path, &DbKey::from_bytes(*old_key))
            .map_err(|e| store_error("open memory for rekey", e))?;
        store
            .rekey_in_place(&DbKey::from_bytes(*new_key))
            .map_err(|e| store_error("rekey", e))?;
        drop(store);
        ctx.reached(Step::RekeyRan)?;
        if !opens_with_bytes(ctx.db_path, new_key) {
            return Ok(Err(
                "the database could not be re-encrypted under the new key".to_owned(),
            ));
        }
    }
    let store = SqlCipherBrainStore::open_readonly(ctx.db_path, &DbKey::from_bytes(*new_key))
        .map_err(|e| store_error("open re-encrypted memory", e))?;
    if let Err(error) = store.quick_check() {
        return Ok(Err(format!(
            "the re-encrypted database does not read back whole: {error}"
        )));
    }
    let moments = store
        .stats()
        .map_err(|e| store_error("count", e))?
        .event_count;
    drop(store);
    // Another writer can add moments between two runs of an interrupted
    // change; none may be lost.
    if journal.moments_before != u64::MAX && moments < journal.moments_before {
        return Ok(Err(format!(
            "the re-encrypted database holds {moments} moments, fewer than the {} before",
            journal.moments_before
        )));
    }
    if opens_with_bytes(ctx.db_path, old_key) {
        return Ok(Err("the old key still opens the database".to_owned()));
    }
    journal.phase = Phase::Rekeyed;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::Rekeyed)?;
    Ok(Ok(()))
}

/// The salt and nonce for re-sealing the screenshot named `old_digest`:
/// derived from the new key and that name, so a repeat after a crash makes
/// the same bytes. Each name stands for exactly one plaintext, so a salt and
/// nonce pair never seals two different screenshots.
fn reseal_salt_nonce(new_key: &[u8; 32], old_digest: &str) -> ([u8; 16], [u8; 12]) {
    let mut message = Vec::with_capacity(SALT_CONTEXT.len() + old_digest.len());
    message.extend_from_slice(SALT_CONTEXT);
    message.extend_from_slice(old_digest.as_bytes());
    let salt_block = hmac(new_key, &message);
    message.clear();
    message.extend_from_slice(NONCE_CONTEXT);
    message.extend_from_slice(old_digest.as_bytes());
    let nonce_block = hmac(new_key, &message);
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    salt.copy_from_slice(&salt_block[..16]);
    nonce.copy_from_slice(&nonce_block[..12]);
    (salt, nonce)
}

/// Step 4: every screenshot that opens with the old key, re-sealed under the
/// new one; its moments moved to the new file in the same transaction that
/// records the move. Idempotent: a screenshot already moved, or already under
/// the new key, is skipped.
fn reseal(
    ctx: &KeyChangeContext<'_>,
    journal: &mut Journal,
    old_key: &[u8; 32],
    new_key: &[u8; 32],
) -> Result<u64, KeyChangeError> {
    let store = SqlCipherBrainStore::new(ctx.db_path, &DbKey::from_bytes(*new_key))
        .map_err(|e| store_error("open memory under the new key", e))?;
    let digests = store
        .referenced_keyframe_digests()
        .map_err(|e| store_error("list screenshots", e))?;
    let blob_dir = ctx.blob_dir();
    let mut pending: Vec<(String, String)> = Vec::new();
    let mut resealed = 0_u64;
    for digest in digests {
        let path = blob_dir.join(format!("{digest}.bin"));
        let blob = match read_blob(&path) {
            Ok(Some(blob)) => blob,
            Ok(None) => continue,
            Err(error) => return Err(io_error("read screenshot", error)),
        };
        if sha256_hex(&blob) != digest || ctx.envelope.open(&blob, new_key).is_some() {
            continue;
        }
        let Some(plaintext) = ctx.envelope.open(&blob, old_key) else {
            continue;
        };
        let (salt, nonce) = reseal_salt_nonce(new_key, &digest);
        let sealed = ctx
            .envelope
            .seal(&plaintext, new_key, &salt, &nonce)
            .map_err(|e| io_error("re-seal screenshot", e))?;
        let new_digest = sha256_hex(&sealed);
        place_blob(ctx, &blob_dir, &new_digest, &sealed, new_key, &plaintext)?;
        ctx.reached(Step::ScreenshotWritten)?;
        pending.push((digest, new_digest));
        resealed += 1;
        if pending.len() >= RESEAL_BATCH {
            move_batch(ctx, &store, &blob_dir, &mut pending)?;
        }
    }
    move_batch(ctx, &store, &blob_dir, &mut pending)?;
    drop(store);
    journal.phase = Phase::Resealed;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::Resealed)?;
    Ok(resealed)
}

/// Write one re-sealed screenshot: a private temporary file, synced, read
/// back and opened, then renamed to its name. A file already there with the
/// same bytes (a repeat after a crash) is kept.
fn place_blob(
    ctx: &KeyChangeContext<'_>,
    blob_dir: &Path,
    digest: &str,
    sealed: &[u8],
    new_key: &[u8; 32],
    plaintext: &[u8],
) -> Result<(), KeyChangeError> {
    let target = blob_dir.join(format!("{digest}.bin"));
    if let Ok(Some(existing)) = read_blob(&target) {
        if existing == sealed {
            return Ok(());
        }
    }
    let temporary = blob_dir.join(format!(".{digest}.{}.tmp", uuid_like()));
    if let Err(error) = write_private_file_unflushed(&temporary, sealed) {
        let _ = std::fs::remove_file(&temporary);
        return Err(io_error("write re-sealed screenshot", error));
    }
    let check = read_blob(&temporary)
        .map_err(|e| io_error("read back re-sealed screenshot", e))?
        .unwrap_or_default();
    let verified = sha256_hex(&check) == digest
        && ctx
            .envelope
            .open(&check, new_key)
            .is_some_and(|opened| opened.as_slice() == plaintext);
    if !verified {
        let _ = std::fs::remove_file(&temporary);
        return Err(io_error(
            "verify re-sealed screenshot",
            "it did not read back",
        ));
    }
    std::fs::rename(&temporary, &target).map_err(|e| {
        let _ = std::fs::remove_file(&temporary);
        io_error("place re-sealed screenshot", e)
    })
}

fn move_batch(
    ctx: &KeyChangeContext<'_>,
    store: &SqlCipherBrainStore,
    blob_dir: &Path,
    pending: &mut Vec<(String, String)>,
) -> Result<(), KeyChangeError> {
    if pending.is_empty() {
        return Ok(());
    }
    // The new files are durable before any moment names them: `sync_all`
    // on the folder is a full flush of the drive's cache (`F_FULLFSYNC`),
    // which covers every file written and `fsync`ed before it.
    sync_dir(blob_dir)?;
    store
        .retarget_keyframes(pending)
        .map_err(|e| store_error("move moments to re-sealed screenshots", e))?;
    pending.clear();
    ctx.reached(Step::BatchMoved)
}

/// Step 5: every moment reads, and every screenshot that opened before opens
/// with the new key.
fn verify(
    ctx: &KeyChangeContext<'_>,
    journal: &mut Journal,
    new_key: &[u8; 32],
) -> Result<Result<(), String>, KeyChangeError> {
    let old_key = key_from_hex(&Zeroizing::new(ctx.read_item(&journal.from_account)?))?;
    let unreadable: BTreeSet<String> = {
        let backup = match SqlCipherBrainStore::open_readonly(
            &ctx.backup_path(),
            &DbKey::from_bytes(old_key),
        ) {
            Ok(backup) => backup,
            Err(error) => return Ok(Err(format!("the backup does not open: {error}"))),
        };
        let index = backup
            .blob_index()
            .map_err(|e| store_error("read screenshot index", e))?;
        index
            .into_iter()
            .filter(|entry| !entry.opened)
            .map(|entry| entry.digest)
            .collect()
    };
    let store = match SqlCipherBrainStore::open_readonly(ctx.db_path, &DbKey::from_bytes(*new_key))
    {
        Ok(store) => store,
        Err(error) => {
            return Ok(Err(format!(
                "the memory does not open with the new key: {error}"
            )))
        }
    };
    if let Err(error) = store.quick_check() {
        return Ok(Err(format!("the memory does not read back whole: {error}")));
    }
    let moments = store
        .stats()
        .map_err(|e| store_error("count", e))?
        .event_count;
    if journal.moments_before != u64::MAX && moments < journal.moments_before {
        return Ok(Err(format!(
            "the memory holds {moments} moments, fewer than the {} before",
            journal.moments_before
        )));
    }
    let digests = store
        .referenced_keyframe_digests()
        .map_err(|e| store_error("list screenshots", e))?;
    drop(store);
    let blob_dir = ctx.blob_dir();
    for digest in digests {
        if unreadable.contains(&digest) {
            continue;
        }
        let blob = read_blob(&blob_dir.join(format!("{digest}.bin")))
            .map_err(|e| io_error("read screenshot", e))?;
        let Some(blob) = blob else {
            return Ok(Err("a screenshot that opened before is missing".to_owned()));
        };
        if sha256_hex(&blob) != digest || ctx.envelope.open(&blob, new_key).is_none() {
            return Ok(Err(
                "a screenshot that opened before does not open with the new key".to_owned(),
            ));
        }
    }
    journal.phase = Phase::Verified;
    write_journal(&ctx.journal_path(), journal)?;
    ctx.reached(Step::Verified)?;
    Ok(Ok(()))
}

/// Step 6, after the commit: the cleanup it allows. Every part is safe to
/// repeat, and none is undone. What can't be done now is reported in
/// [`KeyChangeReport::cleanup_pending`] and left for the next launch; the
/// memory works under the new key meanwhile.
fn clean_up(
    ctx: &KeyChangeContext<'_>,
    journal: &Journal,
) -> Result<KeyChangeReport, KeyChangeError> {
    let mut report = KeyChangeReport {
        screenshots_unreadable: journal.unreadable_before,
        ..KeyChangeReport::default()
    };
    // The new key: under the new account until it is back under the usual
    // one, where a crash after that move leaves it.
    let new_hex = match ctx.read_optional(&journal.to_account)? {
        Some(value) => Zeroizing::new(value),
        None => Zeroizing::new(ctx.read_item(&journal.from_account)?),
    };
    let new_key = key_from_hex(&new_hex)?;
    if !opens_with_bytes(ctx.db_path, &new_key) {
        return Err(store_error(
            "clean up after the key change",
            "the new key does not open the memory",
        ));
    }

    // The old screenshots, once no moment names them.
    let store = SqlCipherBrainStore::new(ctx.db_path, &DbKey::from_bytes(new_key))
        .map_err(|e| store_error("open memory", e))?;
    let moved = store
        .keyframe_retargets()
        .map_err(|e| store_error("read moved screenshots", e))?;
    let referenced: BTreeSet<String> = store
        .referenced_keyframe_digests()
        .map_err(|e| store_error("list screenshots", e))?
        .into_iter()
        .collect();
    let blob_dir = ctx.blob_dir();
    for (old, _) in &moved {
        if !referenced.contains(old) {
            remove_if_present(&blob_dir.join(format!("{old}.bin")))?;
        }
    }
    sync_dir_if_present(&blob_dir)?;
    store
        .clear_keyframe_retargets()
        .map_err(|e| store_error("clear moved screenshots", e))?;
    // Frames under the old key are gone from the log too.
    let _ = store.checkpoint_wal();
    report.moments = store
        .stats()
        .map_err(|e| store_error("count", e))?
        .event_count;
    report.screenshots_resealed = moved.len() as u64;
    drop(store);
    ctx.reached(Step::OldScreenshotsDeleted)?;

    // The backup, under the old key.
    remove_database_files(&ctx.backup_path())?;
    ctx.reached(Step::BackupDeleted)?;

    // Every copy of a key in a file, and the marker.
    for file in key_files(ctx.support_dir).map_err(|e| io_error("list key files", e))? {
        shred_file(&file)?;
        report.key_files_deleted += 1;
    }
    remove_if_present(&ctx.support_dir.join(ADOPTED_MARKER))?;
    sync_dir(ctx.support_dir)?;
    ctx.reached(Step::KeyFilesDeleted)?;

    // The old key, then the new key back under the usual account, then the
    // item under the new account. A Keychain that refuses is asked again at
    // the next launch; readers find the new key under either account.
    let usual = ctx.read_optional(&journal.from_account)?;
    if usual.as_deref() != Some(new_hex.as_str()) {
        if usual.is_some() {
            if let Err(error) = ctx.delete_item(&journal.from_account) {
                report.cleanup_pending = Some(format!("the old key is still stored: {error}"));
                return Ok(report);
            }
        }
        report.old_key_deleted = true;
        ctx.reached(Step::OldKeyDeleted)?;
        if let Err(error) = ctx.add_item(&journal.from_account, &new_hex) {
            report.cleanup_pending = Some(format!(
                "the new key is not back under its usual account yet: {error}"
            ));
            return Ok(report);
        }
        ctx.reached(Step::KeyRestored)?;
    }
    report.old_key_deleted = true;
    if let Err(error) = ctx.delete_item(&journal.to_account) {
        report.cleanup_pending = Some(format!(
            "a second copy of the new key is still stored: {error}"
        ));
        return Ok(report);
    }
    ctx.reached(Step::RotatedKeyDeleted)?;

    remove_if_present(&ctx.journal_path())?;
    remove_if_present(&ctx.undone_path())?;
    let _ = std::fs::remove_dir(ctx.dir());
    sync_dir(ctx.support_dir)?;
    report.finished = true;
    Ok(report)
}

/// Before the commit: everything back as it was. Moments name their original
/// screenshots, the database is under the old key, the re-sealed files and
/// the new Keychain item go, then the backup and the journal. The undo is
/// recorded, and the next change waits a day.
fn roll_back(ctx: &KeyChangeContext<'_>, journal: &Journal) -> Result<(), KeyChangeError> {
    if journal.phase >= Phase::Committed {
        return Err(KeyChangeError::Rollback(
            "the change is already committed".to_owned(),
        ));
    }
    let rollback = |context: &str, error: &dyn std::fmt::Display| {
        KeyChangeError::Rollback(format!("{context}: {error}"))
    };
    let old_hex = Zeroizing::new(
        ctx.read_item(&journal.from_account)
            .map_err(|e| rollback("old key", &e))?,
    );
    let old_key = key_from_hex(&old_hex)?;
    let new_key = match ctx.read_optional(&journal.to_account) {
        Ok(Some(value)) => Some(key_from_hex(&Zeroizing::new(value))?),
        Ok(None) => None,
        Err(error) => return Err(rollback("new key", &error)),
    };

    if ctx.db_path.exists() {
        if let Some(new_key) = new_key.filter(|key| opens_with_bytes(ctx.db_path, key)) {
            let store = SqlCipherBrainStore::new(ctx.db_path, &DbKey::from_bytes(new_key))
                .map_err(|e| rollback("open memory", &e))?;
            let moved = store
                .keyframe_retargets()
                .map_err(|e| rollback("moved screenshots", &e))?;
            store
                .revert_keyframe_retargets()
                .map_err(|e| rollback("move moments back", &e))?;
            store
                .rekey_in_place(&DbKey::from_bytes(old_key))
                .map_err(|e| rollback("rekey back", &e))?;
            drop(store);
            let blob_dir = ctx.blob_dir();
            for (old, new) in &moved {
                // The original must still be there before its copy goes.
                if blob_dir.join(format!("{old}.bin")).exists() {
                    remove_if_present(&blob_dir.join(format!("{new}.bin")))?;
                }
            }
        }
        if !opens_with_bytes(ctx.db_path, &old_key) {
            restore_backup(ctx, &old_key).map_err(|e| rollback("restore backup", &e))?;
        }
        if !opens_with_bytes(ctx.db_path, &old_key) {
            return Err(KeyChangeError::Rollback(
                "the memory does not open with the old key".to_owned(),
            ));
        }
        if let Some(new_key) = new_key {
            remove_unnamed_copies(ctx, &new_key, &old_key)
                .map_err(|e| rollback("remove re-sealed copies", &e))?;
        }
    }
    if new_key.is_some() {
        ctx.delete_item(&journal.to_account)
            .map_err(|e| rollback("delete new key", &e))?;
    }
    remove_database_files(&ctx.backup_path())?;
    let mut record = read_undone(&ctx.undone_path()).unwrap_or_default();
    record.count = record.count.saturating_add(1);
    record.last_unix_ms = unix_ms();
    write_undone(&ctx.undone_path(), &record)?;
    remove_if_present(&ctx.journal_path())?;
    sync_dir(&ctx.dir())?;
    Ok(())
}

/// Re-sealed copies a stopped change wrote before any moment named them:
/// screenshot files no moment names whose bytes open with `new_key`. The
/// originals, under the old key, are never touched.
fn remove_unnamed_copies(
    ctx: &KeyChangeContext<'_>,
    new_key: &[u8; 32],
    old_key: &[u8; 32],
) -> Result<(), KeyChangeError> {
    let blob_dir = ctx.blob_dir();
    let entries = match std::fs::read_dir(&blob_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error("list screenshots", error)),
    };
    let named: BTreeSet<String> =
        SqlCipherBrainStore::open_readonly(ctx.db_path, &DbKey::from_bytes(*old_key))
            .and_then(|store| store.referenced_keyframe_digests())
            .map_err(|e| store_error("list screenshots", e))?
            .into_iter()
            .collect();
    for entry in entries {
        let entry = entry.map_err(|e| io_error("list screenshots", e))?;
        let name = entry.file_name();
        let Some(digest) = name.to_str().and_then(|name| name.strip_suffix(".bin")) else {
            continue;
        };
        if digest.len() != 64 || named.contains(digest) {
            continue;
        }
        let path = entry.path();
        if let Ok(Some(bytes)) = read_blob(&path) {
            if sha256_hex(&bytes) == digest && ctx.envelope.open(&bytes, new_key).is_some() {
                remove_if_present(&path)?;
            }
        }
    }
    sync_dir(&blob_dir)
}

/// The backup, under the old key, copied back over a database neither key
/// opens.
fn restore_backup(ctx: &KeyChangeContext<'_>, old_key: &[u8; 32]) -> Result<(), KeyChangeError> {
    let backup = ctx.backup_path();
    if !opens_with_bytes(&backup, old_key) {
        return Err(store_error(
            "restore",
            "the backup does not open with the old key",
        ));
    }
    let staged = sidecar(ctx.db_path, ".restoring");
    remove_if_present(&staged)?;
    std::fs::copy(&backup, &staged).map_err(|e| io_error("copy backup", e))?;
    restrict_file(&staged)?;
    sync_file(&staged)?;
    remove_if_present(&sidecar(ctx.db_path, "-wal"))?;
    remove_if_present(&sidecar(ctx.db_path, "-shm"))?;
    std::fs::rename(&staged, ctx.db_path).map_err(|e| io_error("restore backup", e))?;
    sync_dir(ctx.db_path.parent().unwrap_or(ctx.support_dir))
}

/// No memory yet: the key is swapped for a new one and the key files go.
/// Nothing is encrypted under the old key, so there is nothing to undo.
fn replace_key_without_memory(
    ctx: &KeyChangeContext<'_>,
    started: Instant,
) -> Result<KeyChangeOutcome, KeyChangeError> {
    let generated = Zeroizing::new((ctx.generate)()?);
    if !is_valid_database_key(&generated) {
        return Err(KeyResolutionError::InvalidKey.into());
    }
    // The new key goes under the new account first, so a crash in between
    // leaves one that readers use.
    if let Err(error) = ctx.add_item(ROTATED_KEYCHAIN_ACCOUNT, &generated) {
        let _ = ctx.delete_item(ROTATED_KEYCHAIN_ACCOUNT);
        return Ok(KeyChangeOutcome::Deferred(format!(
            "the new key could not be stored: {error}"
        )));
    }
    let mut key_files_deleted = 0;
    for file in key_files(ctx.support_dir).map_err(|e| io_error("list key files", e))? {
        shred_file(&file)?;
        key_files_deleted += 1;
    }
    remove_if_present(&ctx.support_dir.join(ADOPTED_MARKER))?;
    sync_dir(ctx.support_dir)?;
    let (old_key_deleted, finished, cleanup_pending) =
        match move_key_to_usual_account(ctx, &generated, true) {
            Ok(()) => (true, true, None),
            Err(error) => (
                false,
                false,
                Some(format!(
                    "the new key is still under the new account: {error}"
                )),
            ),
        };
    Ok(KeyChangeOutcome::Changed(KeyChangeReport {
        key_files_deleted,
        old_key_deleted,
        finished,
        cleanup_pending,
        elapsed_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        ..KeyChangeReport::default()
    }))
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn read_journal(path: &Path) -> Result<Option<Journal>, KeyChangeError> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io_error("read journal", error)),
    };
    let journal: Journal = serde_json::from_slice(&bytes)
        .map_err(|e| KeyChangeError::Journal(format!("parse: {e}")))?;
    if journal.version != JOURNAL_VERSION {
        return Err(KeyChangeError::Journal(format!(
            "unknown version {}",
            journal.version
        )));
    }
    Ok(Some(journal))
}

fn write_journal(path: &Path, journal: &Journal) -> Result<(), KeyChangeError> {
    let mut body =
        serde_json::to_vec_pretty(journal).map_err(|e| KeyChangeError::Journal(e.to_string()))?;
    body.push(b'\n');
    write_private_durably(path, &body).map_err(|e| KeyChangeError::Journal(format!("write: {e}")))
}

fn read_undone(path: &Path) -> Option<UndoneRecord> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn write_undone(path: &Path, record: &UndoneRecord) -> Result<(), KeyChangeError> {
    if let Some(dir) = path.parent() {
        create_private_dir(dir).map_err(|e| io_error("create key-change folder", e))?;
    }
    let body = serde_json::to_vec(record).map_err(|e| KeyChangeError::Journal(e.to_string()))?;
    write_private_durably(path, &body).map_err(|e| io_error("record the undo", e))
}

/// A private file, written to a temporary beside it, synced, renamed into
/// place, and its folder synced: the file is either the old one or the new
/// one after a crash, never half of either.
fn write_private_durably(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let temporary = dir.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("file"),
        uuid_like()
    ));
    if let Err(error) = write_private_file(&temporary, bytes) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    std::fs::File::open(dir)?.sync_all()
}

/// A new file, mode 0600 from the start, written and synced.
fn write_private_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = create_private_file(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// A new file, mode 0600 from the start, written and handed to the disk
/// with a plain `fsync`, without the drive-cache flush `sync_all` adds on
/// macOS (`F_FULLFSYNC`). For re-sealed screenshots: one full flush of the
/// folder before any moment names a batch of them (`move_batch`) makes the
/// whole batch durable, instead of one flush per screenshot.
fn write_private_file_unflushed(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = create_private_file(path)?;
    file.write_all(bytes)?;
    #[cfg(unix)]
    {
        rustix::fs::fsync(&file).map_err(std::io::Error::from)
    }
    #[cfg(not(unix))]
    {
        file.sync_all()
    }
}

fn create_private_file(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// A screenshot file's bytes; `None` when it is missing, not a regular file,
/// or larger than [`MAX_BLOB_BYTES`].
fn read_blob(path: &Path) -> std::io::Result<Option<Vec<u8>>> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !metadata.is_file() || metadata.len() > MAX_BLOB_BYTES {
        return Ok(None);
    }
    let mut file = std::fs::File::open(path)?;
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
    std::io::Read::take(&mut file, MAX_BLOB_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BLOB_BYTES {
        return Ok(None);
    }
    Ok(Some(bytes))
}

/// Overwrite a key file with random bytes of its length, sync, truncate,
/// sync, then unlink it. A link is unlinked, never followed. On an SSD with
/// a copy-on-write file system older copies of the bytes can survive until
/// the space is reused; after the change they open nothing.
pub fn shred_file(path: &Path) -> Result<(), KeyChangeError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error("inspect key file", error)),
    };
    if metadata.is_file() {
        let mut options = std::fs::OpenOptions::new();
        options.write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits().cast_signed());
        }
        if let Ok(mut file) = options.open(path) {
            let length = usize::try_from(metadata.len()).unwrap_or(0).min(1 << 20);
            let mut noise = Zeroizing::new(vec![0u8; length]);
            if getrandom::fill(&mut noise).is_ok() {
                let _ = file.write_all(&noise);
                let _ = file.sync_all();
            }
            let _ = file.set_len(0);
            let _ = file.sync_all();
        }
    }
    std::fs::remove_file(path).map_err(|e| io_error("delete key file", e))
}

fn remove_if_present(path: &Path) -> Result<(), KeyChangeError> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error("delete", error)),
    }
}

fn remove_database_files(path: &Path) -> Result<(), KeyChangeError> {
    remove_if_present(path)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar(path, suffix))?;
    }
    Ok(())
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn file_len(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |metadata| metadata.len())
}

fn restrict_file(path: &Path) -> Result<(), KeyChangeError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| io_error("restrict file", e))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(dir)
}

fn sync_file(path: &Path) -> Result<(), KeyChangeError> {
    std::fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|e| io_error("sync file", e))
}

fn sync_dir(dir: &Path) -> Result<(), KeyChangeError> {
    std::fs::File::open(dir)
        .and_then(|file| file.sync_all())
        .map_err(|e| io_error("sync folder", e))
}

fn sync_dir_if_present(dir: &Path) -> Result<(), KeyChangeError> {
    if dir.exists() {
        sync_dir(dir)
    } else {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Keys and digests
// ---------------------------------------------------------------------------

/// Whether the 64-hex `key` opens the database at `path` read-only.
#[must_use]
pub fn opens(path: &Path, key: &str) -> bool {
    decode_key(key).is_some_and(|bytes| opens_with_bytes(path, &bytes))
}

fn opens_with_bytes(path: &Path, key: &[u8; 32]) -> bool {
    path.exists()
        && SqlCipherBrainStore::open_readonly(path, &DbKey::from_bytes(*key))
            .and_then(|store| store.stats())
            .is_ok()
}

fn key_from_hex(value: &str) -> Result<[u8; 32], KeyChangeError> {
    decode_key(value).ok_or(KeyChangeError::Keychain(KeyResolutionError::InvalidKey))
}

/// 64 hex characters as 32 bytes.
#[must_use]
pub fn decode_key(value: &str) -> Option<[u8; 32]> {
    if !is_valid_database_key(value) {
        return None;
    }
    let mut bytes = [0u8; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let high = (pair[0] as char).to_digit(16)?;
        let low = (pair[1] as char).to_digit(16)?;
        bytes[index] = u8::try_from((high << 4) | low).ok()?;
    }
    Some(bytes)
}

/// Lowercase hex SHA-256: the name a sealed screenshot is stored under.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(64);
    for byte in Sha256::digest(bytes) {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn hmac(key: &[u8; 32], message: &[u8]) -> [u8; 32] {
    let mut ipad = Zeroizing::new([0x36u8; 64]);
    let mut opad = Zeroizing::new([0x5cu8; 64]);
    for (index, byte) in key.iter().enumerate() {
        ipad[index] ^= byte;
        opad[index] ^= byte;
    }
    let mut inner = Sha256::new();
    inner.update(&ipad[..]);
    inner.update(message);
    let mut outer = Sha256::new();
    outer.update(&opad[..]);
    outer.update(inner.finalize());
    outer.finalize().into()
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
        })
}

/// A random name part for temporary files, shaped like the blob store's own
/// (`8-4-4-4-12` hex), so its orphan sweep recognises a leftover one.
fn uuid_like() -> String {
    let mut bytes = [0u8; 16];
    let _ = getrandom::fill(&mut bytes);
    let mut out = String::with_capacity(36);
    for (index, byte) in bytes.iter().enumerate() {
        if matches!(index, 4 | 6 | 8 | 10) {
            out.push('-');
        }
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reseal_salt_and_nonce_repeat_for_one_name_and_differ_between_names() {
        let key = [5u8; 32];
        let a = "a".repeat(64);
        let b = "b".repeat(64);
        assert_eq!(reseal_salt_nonce(&key, &a), reseal_salt_nonce(&key, &a));
        assert_ne!(reseal_salt_nonce(&key, &a), reseal_salt_nonce(&key, &b));
        assert_ne!(
            reseal_salt_nonce(&key, &a),
            reseal_salt_nonce(&[6u8; 32], &a)
        );
    }

    #[test]
    fn hmac_matches_rfc_4231_case_1_with_a_padded_key() {
        // RFC 4231 case 1 with the key zero-padded to 32 bytes is HMAC over
        // the same block key, so the result matches the RFC.
        let mut key = [0u8; 32];
        key[..20].copy_from_slice(&[0x0b; 20]);
        let digest = hmac(&key, b"Hi There");
        let hex: String = digest.iter().fold(String::new(), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        });
        assert_eq!(
            hex,
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }

    #[test]
    fn temporary_names_match_the_blob_store_sweep() {
        let name = uuid_like();
        assert_eq!(name.len(), 36);
        for (index, byte) in name.bytes().enumerate() {
            if matches!(index, 8 | 13 | 18 | 23) {
                assert_eq!(byte, b'-');
            } else {
                assert!(byte.is_ascii_hexdigit());
            }
        }
    }

    #[test]
    fn decode_key_reads_64_hex_characters_only() {
        let hex = "00ff".repeat(16);
        let bytes = decode_key(&hex).expect("valid");
        assert_eq!(bytes[0], 0x00);
        assert_eq!(bytes[1], 0xff);
        assert!(decode_key("abc").is_none());
        assert!(decode_key(&"zz".repeat(32)).is_none());
    }
}
