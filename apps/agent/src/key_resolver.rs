//! `SQLCipher` database-key resolution through the macOS file-based Keychain.
//!
//! Production uses one non-synchronizable generic-password item. The item is
//! created with a `SecAccess` ACL for the four executables shipped in the
//! signed app bundle. Raw key material is never accepted from production MCP
//! configuration or passed to child processes.

use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use thiserror::Error;

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

/// Keychain service for the production `SQLCipher` key.
pub const DEFAULT_KEYCHAIN_SERVICE: &str = "ai.hippocampus.brain";
/// Keychain account for the production `SQLCipher` key.
pub const DEFAULT_KEYCHAIN_ACCOUNT: &str = "database-key-v1";
/// Keychain account a changed key is stored under while the memory moves to
/// it (storage-security review S4, `key_change`). Only ever there for the
/// length of one key change: once it is finished the new key is back under
/// [`DEFAULT_KEYCHAIN_ACCOUNT`] and this item is gone. So a reader of the
/// default reference that finds it uses it.
pub const ROTATED_KEYCHAIN_ACCOUNT: &str = "database-key-v2";
/// Storage-domain identifier shared by Swift, Rust, and packaging tests.
pub const KEYCHAIN_STORAGE_MODEL: &str = "file-keychain-acl-v1";
/// Executables explicitly trusted by the file-Keychain ACL.
pub const TRUSTED_EXECUTABLE_NAMES: [&str; 4] =
    ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"];

const CONTRACT_FILE_NAME: &str = "keychain-sharing-contract.json";

/// Content-free reference to a generic-password item.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KeychainKeyReference {
    /// Generic-password service.
    pub service: String,
    /// Generic-password account.
    pub account: String,
}

impl Default for KeychainKeyReference {
    fn default() -> Self {
        Self {
            service: DEFAULT_KEYCHAIN_SERVICE.to_owned(),
            account: DEFAULT_KEYCHAIN_ACCOUNT.to_owned(),
        }
    }
}

impl KeychainKeyReference {
    /// Whether this names the production item every process and AI tool is
    /// registered with: during and just after a key change its key may be
    /// under [`ROTATED_KEYCHAIN_ACCOUNT`] instead.
    #[must_use]
    pub fn is_default(&self) -> bool {
        self.service == DEFAULT_KEYCHAIN_SERVICE && self.account == DEFAULT_KEYCHAIN_ACCOUNT
    }

    /// Resolve the content-free reference from process metadata.
    pub fn from_environment() -> Result<Self, KeyResolutionError> {
        if let Ok(model) = std::env::var("MCI_DB_KEYCHAIN_STORAGE_MODEL") {
            if model != KEYCHAIN_STORAGE_MODEL {
                return Err(KeyResolutionError::DomainMismatch { model });
            }
        }
        Ok(Self {
            service: std::env::var("MCI_DB_KEYCHAIN_SERVICE")
                .unwrap_or_else(|_| DEFAULT_KEYCHAIN_SERVICE.to_owned()),
            account: std::env::var("MCI_DB_KEYCHAIN_ACCOUNT")
                .unwrap_or_else(|_| DEFAULT_KEYCHAIN_ACCOUNT.to_owned()),
        })
    }
}

/// Errors preserve Keychain status classes so callers create only on not-found.
#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum KeyResolutionError {
    /// The exact service/account item does not exist in the file Keychain.
    #[error("database key not found in Keychain (service={service}, account={account})")]
    MissingKey {
        /// Generic-password service.
        service: String,
        /// Generic-password account.
        account: String,
    },
    /// The caller is not trusted by the item's ACL.
    #[error("Keychain access denied (service={service}, account={account})")]
    AccessDenied {
        /// Generic-password service.
        service: String,
        /// Generic-password account.
        account: String,
    },
    /// Keychain access required interaction that was unavailable or canceled.
    #[error(
        "Keychain is locked or interaction is unavailable (service={service}, account={account})"
    )]
    InteractionNotAllowed {
        /// Generic-password service.
        service: String,
        /// Generic-password account.
        account: String,
    },
    /// The key exists but is not the expected 32-byte hexadecimal value.
    #[error("Keychain database key must be exactly 64 hex characters")]
    InvalidKey,
    /// A read failed for a status other than not-found/denied/locked.
    #[error("Keychain read failed with status {status} (service={service}, account={account})")]
    ReadFailure {
        /// Generic-password service.
        service: String,
        /// Generic-password account.
        account: String,
        /// Native `OSStatus` value.
        status: i32,
    },
    /// Creation found an existing item and refused to update it.
    #[error("database key already exists; refusing to overwrite it")]
    KeyAlreadyExists,
    /// The signed bundle cannot supply the complete ACL trust list.
    #[error("Keychain ACL unavailable: {reason}")]
    AclUnavailable {
        /// Content-free validation failure.
        reason: String,
    },
    /// A process supplied metadata for a different Keychain domain.
    #[error("unsupported Keychain storage model '{model}'")]
    DomainMismatch {
        /// Unsupported content-free model identifier.
        model: String,
    },
    /// The native Keychain API is unavailable on this platform.
    #[error("macOS Keychain is unavailable on this platform")]
    UnsupportedPlatform,
    /// Native Keychain creation failed.
    #[error("Keychain add failed with status {status}")]
    WriteFailure {
        /// Native `OSStatus` value.
        status: i32,
    },
    /// The operating-system CSPRNG failed.
    #[error("OS CSPRNG failed: {reason}")]
    GenerationFailure {
        /// Content-free random-source error.
        reason: String,
    },
    /// The existing database path could not be inspected safely.
    #[error("cannot inspect existing database path {path}: {reason}")]
    DatabasePathCheckFailed {
        /// Database path whose existence could not be established.
        path: PathBuf,
        /// Content-free filesystem error.
        reason: String,
    },
    /// An existing database has no readable legacy migration key.
    #[error(
        "existing database requires legacy key migration, but {path} could not be read: {reason}"
    )]
    LegacyKeyReadFailed {
        /// Legacy migration input path.
        path: PathBuf,
        /// Content-free filesystem error.
        reason: String,
    },
    /// The legacy migration input is not exactly 64 ASCII hex characters.
    #[error("legacy dev.key must be exactly 64 ASCII hex characters")]
    InvalidLegacyKey,
    /// A candidate key could not open and query the existing `SQLCipher` schema.
    #[error("database key did not open the existing brain read-only")]
    DatabaseValidationFailed,
    /// The mandatory read after an add or duplicate race failed.
    #[error("database key was added or raced, but the Keychain re-read failed: {source}")]
    PostAddReadFailed {
        /// Typed Keychain read failure, retained without collapsing denied/locked/missing.
        source: Box<KeyResolutionError>,
    },
    /// The re-read Keychain key could not open the existing database.
    #[error("re-read Keychain key did not open the existing brain read-only: {source}")]
    PostAddValidationFailed {
        /// Content-free read-only database validation error.
        source: Box<KeyResolutionError>,
    },
    /// The Keychain migration was validated, but the legacy plaintext remained.
    #[error("validated Keychain migration could not remove legacy key at {path}: {reason}")]
    LegacyKeyRemovalFailed {
        /// Legacy plaintext path that could not be removed.
        path: PathBuf,
        /// Content-free filesystem error.
        reason: String,
    },
    /// An interrupted migration left a different valid legacy key beside the item.
    #[error("legacy dev.key does not match the validated Keychain database key")]
    LegacyKeyMismatch,
}

/// Injectable read surface used by production and tests.
pub trait KeychainReader {
    /// Read one generic-password item without changing it.
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError>;
}

/// Injectable add-only surface used by initialization.
pub trait KeychainWriter {
    /// Add a generic-password item with an explicit trusted-application ACL.
    fn add_generic_password(
        &self,
        service: &str,
        account: &str,
        secret: &str,
        trusted_application_paths: &[PathBuf],
    ) -> Result<(), KeyResolutionError>;
}

/// Injectable read-only proof that a key opens the expected brain schema.
pub trait DatabaseKeyValidator {
    /// Open `database_path` read-only with `key` and query the expected schema.
    fn validate_existing_database(
        &self,
        database_path: &Path,
        key: &str,
    ) -> Result<(), KeyResolutionError>;
}

/// Injectable finalizer for deleting a successfully migrated legacy key.
pub trait LegacyKeyRemover {
    /// Remove the legacy plaintext after Keychain and database validation.
    fn remove(&self, path: &Path) -> std::io::Result<()>;
}

/// Production legacy-key finalizer.
pub struct SystemLegacyKeyRemover;

impl LegacyKeyRemover for SystemLegacyKeyRemover {
    fn remove(&self, path: &Path) -> std::io::Result<()> {
        std::fs::remove_file(path)
    }
}

/// Production read-only `SQLCipher` validator used by app startup and CLI init.
pub struct SqlCipherDatabaseKeyValidator;

impl DatabaseKeyValidator for SqlCipherDatabaseKeyValidator {
    fn validate_existing_database(
        &self,
        database_path: &Path,
        key_hex: &str,
    ) -> Result<(), KeyResolutionError> {
        let bytes = decode_hex_key(key_hex).ok_or(KeyResolutionError::DatabaseValidationFailed)?;
        let key = DbKey::from_bytes(bytes);
        let store = SqlCipherBrainStore::open_readonly(database_path, &key)
            .map_err(|_| KeyResolutionError::DatabaseValidationFailed)?;
        store
            .stats()
            .map(|_| ())
            .map_err(|_| KeyResolutionError::DatabaseValidationFailed)
    }
}

fn decode_hex_key(value: &str) -> Option<[u8; 32]> {
    if !is_valid_database_key(value) {
        return None;
    }
    let mut bytes = [0u8; 32];
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
        let high = u8::try_from((chunk[0] as char).to_digit(16)?).ok()?;
        let low = u8::try_from((chunk[1] as char).to_digit(16)?).ok()?;
        bytes[index] = (high << 4) | low;
    }
    Some(bytes)
}

/// Native reader for the current user's file-based, non-sync Keychain.
pub struct SystemKeychainReader;

impl KeychainReader for SystemKeychainReader {
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError> {
        #[cfg(target_os = "macos")]
        {
            let bytes = mci_keychain::read_file_generic_password(service, account)
                .map_err(|error| map_native_read_error(error, service, account))?;
            String::from_utf8(bytes).map_err(|_| KeyResolutionError::InvalidKey)
        }

        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account);
            Err(KeyResolutionError::UnsupportedPlatform)
        }
    }
}

#[cfg(target_os = "macos")]
#[allow(clippy::needless_pass_by_value)]
fn map_native_read_error(
    error: mci_keychain::Error,
    service: &str,
    account: &str,
) -> KeyResolutionError {
    match error {
        mci_keychain::Error::Status(status) => map_read_status(status, service, account),
        mci_keychain::Error::InvalidResult => map_read_status(-26275, service, account),
        mci_keychain::Error::InvalidPath
        | mci_keychain::Error::AclStatus(_)
        | mci_keychain::Error::EmptyTrustedApplications => map_read_status(-50, service, account),
    }
}

#[cfg(target_os = "macos")]
fn map_read_status(status: i32, service: &str, account: &str) -> KeyResolutionError {
    let context = || (service.to_owned(), account.to_owned());
    match status {
        -25300 => {
            let (service, account) = context();
            KeyResolutionError::MissingKey { service, account }
        }
        -25293 | -34018 => {
            let (service, account) = context();
            KeyResolutionError::AccessDenied { service, account }
        }
        -25308 | -25291 | -128 => {
            let (service, account) = context();
            KeyResolutionError::InteractionNotAllowed { service, account }
        }
        _ => {
            let (service, account) = context();
            KeyResolutionError::ReadFailure {
                service,
                account,
                status,
            }
        }
    }
}

/// Result of add-only database-key initialization.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyInitializationOutcome {
    /// A valid item already existed and was left untouched.
    AlreadyPresent,
    /// A new ACL-protected item was added after a proven not-found read.
    Created,
    /// An existing brain's exact legacy key was imported and revalidated.
    MigratedLegacyKey,
    /// Another process won the add race; its item was re-read and validated.
    ConcurrentItemValidated,
    /// A prior add succeeded; restart revalidated custody and removed plaintext.
    CompletedInterruptedMigration,
}

/// Resolve and validate the production database key.
///
/// For the default reference this is the memory's key wherever a key change
/// left it ([`resolve_current_database_key`]).
pub fn resolve_database_key() -> Result<String, KeyResolutionError> {
    let reference = KeychainKeyReference::from_environment()?;
    let database = database_path_hint();
    resolve_current_database_key(
        &SystemKeychainReader,
        &SqlCipherDatabaseKeyValidator,
        &reference,
        database.as_deref(),
    )
}

/// The memory this process was pointed at (`MCI_DB_PATH`), or the default
/// one, used only to choose between two keys during a key change.
fn database_path_hint() -> Option<PathBuf> {
    std::env::var_os("MCI_DB_PATH")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            mci_core::home::user_home()
                .map(|home| home.join("Library/Application Support/MCI/mci.sqlite"))
        })
}

/// The memory's key for `reference` (storage-security review S4).
///
/// Any reference but the default is read exactly. For the default one, a key
/// under [`ROTATED_KEYCHAIN_ACCOUNT`] is the newer key: a key change put it
/// there, and moves it back to the default account when it finishes. While
/// both items exist, the one that opens the memory at `database_path` is
/// returned, the newer first: before the database is re-encrypted that is
/// the old key, after it the new one, and a reader never has to know which
/// step the change is at.
///
/// # Errors
/// The same typed Keychain errors as [`resolve_database_key_with_reader`].
pub fn resolve_current_database_key<R: KeychainReader, V: DatabaseKeyValidator>(
    reader: &R,
    validator: &V,
    reference: &KeychainKeyReference,
    database_path: Option<&Path>,
) -> Result<String, KeyResolutionError> {
    if !reference.is_default() {
        return resolve_database_key_with_reader(reader, reference);
    }
    let rotated = KeychainKeyReference {
        service: reference.service.clone(),
        account: ROTATED_KEYCHAIN_ACCOUNT.to_owned(),
    };
    let newer = match resolve_database_key_with_reader(reader, &rotated) {
        Err(KeyResolutionError::MissingKey { .. }) => {
            return resolve_database_key_with_reader(reader, reference);
        }
        other => other,
    };
    let older = resolve_database_key_with_reader(reader, reference);
    let existing = database_path.filter(|path| path.exists());
    let opens = |key: &str| {
        existing.is_some_and(|path| validator.validate_existing_database(path, key).is_ok())
    };
    match (newer, older) {
        (Ok(newer), Ok(older)) => {
            if newer != older && !opens(&newer) && opens(&older) {
                Ok(older)
            } else {
                Ok(newer)
            }
        }
        (Ok(newer), Err(_)) => Ok(newer),
        // The newer item can't be read now: the older one only if it is the
        // one that opens the memory.
        (Err(error), Ok(older)) => {
            if opens(&older) {
                Ok(older)
            } else {
                Err(error)
            }
        }
        (Err(error), Err(_)) => Err(error),
    }
}

/// Resolve with an injected reader; does not access a real Keychain in tests.
pub fn resolve_database_key_with_reader<R: KeychainReader>(
    reader: &R,
    reference: &KeychainKeyReference,
) -> Result<String, KeyResolutionError> {
    let value = reader.read_generic_password(&reference.service, &reference.account)?;
    if is_valid_database_key(&value) {
        Ok(value)
    } else {
        Err(KeyResolutionError::InvalidKey)
    }
}

/// Initialize only after a typed not-found result. All other reads fail closed.
#[allow(clippy::too_many_arguments)]
pub fn initialize_database_key_with<R, W, V, G>(
    reader: &R,
    writer: &W,
    validator: &V,
    reference: &KeychainKeyReference,
    trusted_application_paths: &[PathBuf],
    database_path: &Path,
    legacy_key_path: &Path,
    generate: G,
) -> Result<KeyInitializationOutcome, KeyResolutionError>
where
    R: KeychainReader,
    W: KeychainWriter,
    V: DatabaseKeyValidator,
    G: FnOnce() -> Result<String, KeyResolutionError>,
{
    initialize_database_key_with_remover(
        reader,
        writer,
        validator,
        &SystemLegacyKeyRemover,
        reference,
        trusted_application_paths,
        database_path,
        legacy_key_path,
        generate,
    )
}

/// Initialize with an injectable legacy-key finalizer for failure-path tests.
#[allow(clippy::too_many_arguments)]
pub fn initialize_database_key_with_remover<R, W, V, D, G>(
    reader: &R,
    writer: &W,
    validator: &V,
    remover: &D,
    reference: &KeychainKeyReference,
    trusted_application_paths: &[PathBuf],
    database_path: &Path,
    legacy_key_path: &Path,
    generate: G,
) -> Result<KeyInitializationOutcome, KeyResolutionError>
where
    R: KeychainReader,
    W: KeychainWriter,
    V: DatabaseKeyValidator,
    D: LegacyKeyRemover,
    G: FnOnce() -> Result<String, KeyResolutionError>,
{
    let database_exists = match std::fs::metadata(database_path) {
        Ok(_) => true,
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => {
            return Err(KeyResolutionError::DatabasePathCheckFailed {
                path: database_path.to_path_buf(),
                reason: error.to_string(),
            });
        }
    };
    let legacy_exists = match std::fs::metadata(legacy_key_path) {
        Ok(_) => true,
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => {
            return Err(KeyResolutionError::LegacyKeyReadFailed {
                path: legacy_key_path.to_path_buf(),
                reason: error.to_string(),
            });
        }
    };

    match resolve_database_key_with_reader(reader, reference) {
        Ok(key) => {
            if database_exists {
                validator.validate_existing_database(database_path, &key)?;
            }
            if legacy_exists {
                let legacy = read_legacy_key(legacy_key_path)?;
                if database_exists {
                    validator.validate_existing_database(database_path, &legacy)?;
                }
                if legacy != key {
                    return Err(KeyResolutionError::LegacyKeyMismatch);
                }
                remove_legacy_key(remover, legacy_key_path)?;
                return Ok(KeyInitializationOutcome::CompletedInterruptedMigration);
            }
            Ok(KeyInitializationOutcome::AlreadyPresent)
        }
        Err(KeyResolutionError::MissingKey { .. }) => {
            if trusted_application_paths.is_empty() {
                return Err(KeyResolutionError::AclUnavailable {
                    reason: "trusted executable list is empty".to_owned(),
                });
            }

            let candidate = if legacy_exists {
                let legacy = read_legacy_key(legacy_key_path)?;
                if database_exists {
                    validator.validate_existing_database(database_path, &legacy)?;
                }
                legacy
            } else if database_exists {
                return Err(KeyResolutionError::LegacyKeyReadFailed {
                    path: legacy_key_path.to_path_buf(),
                    reason: "file does not exist".to_owned(),
                });
            } else {
                let generated = generate()?;
                if !is_valid_database_key(&generated) {
                    return Err(KeyResolutionError::InvalidKey);
                }
                generated
            };

            let raced = match writer.add_generic_password(
                &reference.service,
                &reference.account,
                &candidate,
                trusted_application_paths,
            ) {
                Ok(()) => false,
                Err(KeyResolutionError::KeyAlreadyExists) => true,
                Err(error) => return Err(error),
            };

            let reread = resolve_database_key_with_reader(reader, reference).map_err(|source| {
                KeyResolutionError::PostAddReadFailed {
                    source: Box::new(source),
                }
            })?;
            if database_exists {
                validator
                    .validate_existing_database(database_path, &reread)
                    .map_err(|source| KeyResolutionError::PostAddValidationFailed {
                        source: Box::new(source),
                    })?;
            }
            if legacy_exists {
                if reread != candidate {
                    return Err(KeyResolutionError::LegacyKeyMismatch);
                }
                remove_legacy_key(remover, legacy_key_path)?;
            }

            if raced {
                Ok(KeyInitializationOutcome::ConcurrentItemValidated)
            } else if legacy_exists {
                Ok(KeyInitializationOutcome::MigratedLegacyKey)
            } else {
                Ok(KeyInitializationOutcome::Created)
            }
        }
        Err(error) => Err(error),
    }
}

fn read_legacy_key(path: &Path) -> Result<String, KeyResolutionError> {
    let bytes = std::fs::read(path).map_err(|error| KeyResolutionError::LegacyKeyReadFailed {
        path: path.to_path_buf(),
        reason: error.to_string(),
    })?;
    let key = String::from_utf8(bytes).map_err(|_| KeyResolutionError::InvalidLegacyKey)?;
    if !is_valid_database_key(&key) {
        return Err(KeyResolutionError::InvalidLegacyKey);
    }
    Ok(key)
}

fn remove_legacy_key<D: LegacyKeyRemover>(
    remover: &D,
    path: &Path,
) -> Result<(), KeyResolutionError> {
    remover
        .remove(path)
        .map_err(|error| KeyResolutionError::LegacyKeyRemovalFailed {
            path: path.to_path_buf(),
            reason: error.to_string(),
        })
}

/// Whether this build honours development file keys for the person's own
/// memory: a debug build, or one built with the `development-file-key`
/// feature. A release build never does (storage-security review S11): a
/// developer who exported `MCI_DEVELOPMENT_FILE_KEY=1` and runs the shipped
/// agent gets the Keychain, never a memory keyed by a file beside it.
pub const DEVELOPMENT_FILE_KEY_COMPILED_IN: bool =
    cfg!(any(debug_assertions, feature = "development-file-key"));

/// Demo Memory's folder: `~/Library/Application Support/Hippocampus/Demo
/// Memory`. Its made-up week has its own key file there, which a release
/// build still reads, for a store in that folder only.
#[must_use]
pub fn demo_memory_folder(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Hippocampus/Demo Memory")
}

/// What the environment says about a development key.
#[derive(Clone, Copy, Debug, Default)]
pub struct DevelopmentKeyEnvironment<'a> {
    /// `MCI_DEVELOPMENT_FILE_KEY`: only `1` turns it on.
    pub marker: Option<&'a str>,
    /// `MCI_DB_KEY_HEX`.
    pub raw_key: Option<&'a str>,
    /// `MCI_DB_KEY_FILE`.
    pub key_file: Option<&'a Path>,
    /// The memory the command opens (`--db-path` or `MCI_DB_PATH`).
    pub db_path: Option<&'a Path>,
    /// The home folder.
    pub home: Option<&'a Path>,
}

impl DevelopmentKeyEnvironment<'_> {
    /// The development key this build honours, if any.
    #[must_use]
    pub fn key(&self) -> Option<String> {
        self.key_for_build(DEVELOPMENT_FILE_KEY_COMPILED_IN)
    }

    /// The development key a build with or without the development path
    /// honours. Without it, only Demo Memory's own key file opens Demo
    /// Memory's own store; never a raw key, never `MCI/dev.key`.
    #[must_use]
    pub fn key_for_build(&self, development_compiled_in: bool) -> Option<String> {
        if self.marker != Some("1") {
            return None;
        }
        if !development_compiled_in {
            let demo = demo_memory_folder(self.home?);
            let key_file = self.key_file?;
            let inside = |path: &Path| {
                path.is_absolute()
                    && path.starts_with(&demo)
                    && !path
                        .components()
                        .any(|part| matches!(part, std::path::Component::ParentDir))
            };
            if !inside(key_file) || !self.db_path.is_some_and(inside) {
                return None;
            }
            return read_development_key_file(key_file);
        }
        if let Some(path) = self.key_file {
            return read_development_key_file(path);
        }
        self.raw_key
            .filter(|key| is_valid_database_key(key))
            .map(str::to_owned)
            .or_else(|| {
                let path = self.home?.join("Library/Application Support/MCI/dev.key");
                read_development_key_file(&path)
            })
    }
}

/// A key file's 64 hex characters, with at most one line ending after them;
/// any other whitespace is never normalised into key material.
fn read_development_key_file(path: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(path).ok()?;
    let key = contents
        .strip_suffix("\r\n")
        .or_else(|| contents.strip_suffix('\n'))
        .unwrap_or(&contents);
    is_valid_database_key(key).then(|| key.to_owned())
}

/// True for an exact 32-byte key encoded as 64 ASCII hexadecimal digits.
#[must_use]
pub fn is_valid_database_key(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Build the content-free environment recorded in MCP client configuration.
#[must_use]
pub fn mcp_registration_env(db_path: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("MCI_DB_PATH".to_owned(), db_path.to_owned()),
        (
            "MCI_DB_KEYCHAIN_SERVICE".to_owned(),
            DEFAULT_KEYCHAIN_SERVICE.to_owned(),
        ),
        (
            "MCI_DB_KEYCHAIN_ACCOUNT".to_owned(),
            DEFAULT_KEYCHAIN_ACCOUNT.to_owned(),
        ),
        (
            "MCI_DB_KEYCHAIN_STORAGE_MODEL".to_owned(),
            KEYCHAIN_STORAGE_MODEL.to_owned(),
        ),
    ])
}

/// Validated ACL trust paths from an assembled Hippocampus.app bundle.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KeychainAclContract {
    /// Absolute paths used to create `SecTrustedApplication` entries.
    pub trusted_application_paths: Vec<PathBuf>,
}

#[derive(Deserialize)]
struct ContractManifest {
    storage_model: String,
    service: String,
    account: String,
    trusted_executables: Vec<String>,
    use_data_protection_keychain: bool,
    synchronizable: bool,
}

impl KeychainAclContract {
    /// Resolve the signed app bundle containing the running `mci-agent`.
    pub fn from_current_executable() -> Result<Self, KeyResolutionError> {
        let executable =
            std::env::current_exe().map_err(|error| KeyResolutionError::AclUnavailable {
                reason: format!("cannot resolve current executable: {error}"),
            })?;
        Self::from_agent_executable(&executable)
    }

    /// Validate an assembled app layout without reading any Keychain item.
    pub fn from_agent_executable(executable: &Path) -> Result<Self, KeyResolutionError> {
        if executable.file_name().and_then(|name| name.to_str()) != Some("mci-agent") {
            return Err(KeyResolutionError::AclUnavailable {
                reason: "initialization must run from bundled mci-agent".to_owned(),
            });
        }
        let macos = executable
            .parent()
            .ok_or_else(|| KeyResolutionError::AclUnavailable {
                reason: "bundled executable has no Contents/MacOS directory".to_owned(),
            })?;
        let contents = macos
            .parent()
            .ok_or_else(|| KeyResolutionError::AclUnavailable {
                reason: "bundled executable has no Contents directory".to_owned(),
            })?;
        if macos.file_name().and_then(|name| name.to_str()) != Some("MacOS")
            || contents.file_name().and_then(|name| name.to_str()) != Some("Contents")
        {
            return Err(KeyResolutionError::AclUnavailable {
                reason: "mci-agent is not inside Hippocampus.app/Contents/MacOS".to_owned(),
            });
        }
        let manifest_path = contents.join("Resources").join(CONTRACT_FILE_NAME);
        let bytes =
            std::fs::read(&manifest_path).map_err(|error| KeyResolutionError::AclUnavailable {
                reason: format!("cannot read {}: {error}", manifest_path.display()),
            })?;
        let manifest: ContractManifest =
            serde_json::from_slice(&bytes).map_err(|error| KeyResolutionError::AclUnavailable {
                reason: format!("cannot parse {}: {error}", manifest_path.display()),
            })?;
        let expected_names: Vec<String> = TRUSTED_EXECUTABLE_NAMES
            .iter()
            .map(ToString::to_string)
            .collect();
        if manifest.storage_model != KEYCHAIN_STORAGE_MODEL
            || manifest.service != DEFAULT_KEYCHAIN_SERVICE
            || manifest.account != DEFAULT_KEYCHAIN_ACCOUNT
            || manifest.trusted_executables != expected_names
            || manifest.use_data_protection_keychain
            || manifest.synchronizable
        {
            return Err(KeyResolutionError::AclUnavailable {
                reason: "bundle Keychain contract does not match this binary".to_owned(),
            });
        }

        let trusted_application_paths: Vec<PathBuf> = TRUSTED_EXECUTABLE_NAMES
            .iter()
            .map(|name| macos.join(name))
            .collect();
        for path in &trusted_application_paths {
            if !path.is_file() {
                return Err(KeyResolutionError::AclUnavailable {
                    reason: format!("trusted executable is missing: {}", path.display()),
                });
            }
        }
        Ok(Self {
            trusted_application_paths,
        })
    }
}
