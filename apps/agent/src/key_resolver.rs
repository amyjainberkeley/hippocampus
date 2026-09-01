//! SQLCipher database-key resolution through the macOS file-based Keychain.
//!
//! Production uses one non-synchronizable generic-password item. The item is
//! created with a `SecAccess` ACL for the four executables shipped in the
//! signed app bundle. Raw key material is never accepted from production MCP
//! configuration or passed to child processes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use thiserror::Error;

/// Keychain service for the production SQLCipher key.
pub const DEFAULT_KEYCHAIN_SERVICE: &str = "ai.hippocampus.brain";
/// Keychain account for the production SQLCipher key.
pub const DEFAULT_KEYCHAIN_ACCOUNT: &str = "database-key-v1";
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
            return String::from_utf8(bytes).map_err(|_| KeyResolutionError::InvalidKey);
        }

        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account);
            Err(KeyResolutionError::UnsupportedPlatform)
        }
    }
}

#[cfg(target_os = "macos")]
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
}

/// Resolve and validate the production database key.
pub fn resolve_database_key() -> Result<String, KeyResolutionError> {
    let reference = KeychainKeyReference::from_environment()?;
    resolve_database_key_with_reader(&SystemKeychainReader, &reference)
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
pub fn initialize_database_key_with<R, W, G>(
    reader: &R,
    writer: &W,
    reference: &KeychainKeyReference,
    trusted_application_paths: &[PathBuf],
    generate: G,
) -> Result<KeyInitializationOutcome, KeyResolutionError>
where
    R: KeychainReader,
    W: KeychainWriter,
    G: FnOnce() -> Result<String, KeyResolutionError>,
{
    match resolve_database_key_with_reader(reader, reference) {
        Ok(_) => Ok(KeyInitializationOutcome::AlreadyPresent),
        Err(KeyResolutionError::MissingKey { .. }) => {
            if trusted_application_paths.is_empty() {
                return Err(KeyResolutionError::AclUnavailable {
                    reason: "trusted executable list is empty".to_owned(),
                });
            }
            let generated = generate()?;
            if !is_valid_database_key(&generated) {
                return Err(KeyResolutionError::InvalidKey);
            }
            writer.add_generic_password(
                &reference.service,
                &reference.account,
                &generated,
                trusted_application_paths,
            )?;
            Ok(KeyInitializationOutcome::Created)
        }
        Err(error) => Err(error),
    }
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
