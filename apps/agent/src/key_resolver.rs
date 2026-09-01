//! SQLCipher database key resolution without serializing reusable key material.
//!
//! Production reads a macOS Keychain generic-password item identified by a
//! service/account pair. Tests inject a reader so the security boundary is
//! exercised without touching the user's real Keychain.

use std::collections::BTreeMap;
use std::fmt;
use std::process::Command;

/// Default Keychain service for the Hippocampus SQLCipher key.
pub const DEFAULT_KEYCHAIN_SERVICE: &str = "ai.hippocampus.brain";

/// Default Keychain account for the Hippocampus SQLCipher key.
pub const DEFAULT_KEYCHAIN_ACCOUNT: &str = "database-key-v1";

/// Environment variable carrying the Keychain service reference.
pub const ENV_KEYCHAIN_SERVICE: &str = "MCI_DB_KEYCHAIN_SERVICE";

/// Environment variable carrying the Keychain account reference.
pub const ENV_KEYCHAIN_ACCOUNT: &str = "MCI_DB_KEYCHAIN_ACCOUNT";

/// Environment variable carrying the brain path for registered MCP clients.
pub const ENV_DB_PATH: &str = "MCI_DB_PATH";

/// Content-free reference to a generic-password item in Keychain.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct KeychainKeyReference {
    /// Keychain generic-password service.
    pub service: String,
    /// Keychain generic-password account.
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
    /// Construct a new content-free Keychain reference.
    pub fn new(service: impl Into<String>, account: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            account: account.into(),
        }
    }

    /// Resolve the reference from environment variables, with production defaults.
    pub fn from_env() -> Self {
        let default = Self::default();
        Self {
            service: std::env::var(ENV_KEYCHAIN_SERVICE).unwrap_or(default.service),
            account: std::env::var(ENV_KEYCHAIN_ACCOUNT).unwrap_or(default.account),
        }
    }
}

/// Read-only abstraction over a Keychain generic-password lookup.
pub trait KeychainReader {
    /// Read the password string for `service` and `account`.
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError>;
}

/// Production Keychain reader.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemKeychainReader;

impl KeychainReader for SystemKeychainReader {
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError> {
        #[cfg(target_os = "macos")]
        {
            let output = Command::new("/usr/bin/security")
                .args(["find-generic-password", "-s", service, "-a", account, "-w"])
                .output()
                .map_err(|e| KeyResolutionError::ReadFailed {
                    service: service.to_owned(),
                    account: account.to_owned(),
                    message: e.to_string(),
                })?;
            if output.status.success() {
                return String::from_utf8(output.stdout)
                    .map(|s| s.trim().to_owned())
                    .map_err(|e| KeyResolutionError::ReadFailed {
                        service: service.to_owned(),
                        account: account.to_owned(),
                        message: e.to_string(),
                    });
            }
            return Err(KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            });
        }

        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account);
            Err(KeyResolutionError::UnsupportedPlatform)
        }
    }
}

/// Error returned by database-key resolution.
#[derive(Debug, Eq, PartialEq)]
pub enum KeyResolutionError {
    /// No Keychain item exists for the requested reference.
    MissingKey {
        /// Keychain generic-password service.
        service: String,
        /// Keychain generic-password account.
        account: String,
    },
    /// The item exists but is not a 64-character hexadecimal key.
    InvalidKeyMaterial {
        /// Keychain generic-password service.
        service: String,
        /// Keychain generic-password account.
        account: String,
    },
    /// The underlying Keychain read failed.
    ReadFailed {
        /// Keychain generic-password service.
        service: String,
        /// Keychain generic-password account.
        account: String,
        /// Sanitized diagnostic that never includes key bytes.
        message: String,
    },
    /// Keychain resolution is only supported on macOS.
    UnsupportedPlatform,
}

impl fmt::Display for KeyResolutionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingKey { service, account } => write!(
                f,
                "database key not found in Keychain service={service} account={account}"
            ),
            Self::InvalidKeyMaterial { service, account } => write!(
                f,
                "database key in Keychain service={service} account={account} must be 64 hex characters"
            ),
            Self::ReadFailed {
                service,
                account,
                message,
            } => write!(
                f,
                "read Keychain database key service={service} account={account}: {message}"
            ),
            Self::UnsupportedPlatform => write!(f, "Keychain database key resolution requires macOS"),
        }
    }
}

impl std::error::Error for KeyResolutionError {}

/// Resolve the database key using the production Keychain reader.
pub fn resolve_database_key() -> Result<String, KeyResolutionError> {
    resolve_database_key_with_reader(&SystemKeychainReader, &KeychainKeyReference::from_env())
}

/// Resolve the database key using an injected Keychain reader.
pub fn resolve_database_key_with_reader<R: KeychainReader + ?Sized>(
    reader: &R,
    reference: &KeychainKeyReference,
) -> Result<String, KeyResolutionError> {
    let key = reader.read_generic_password(&reference.service, &reference.account)?;
    if is_valid_database_key(&key) {
        Ok(key)
    } else {
        Err(KeyResolutionError::InvalidKeyMaterial {
            service: reference.service.clone(),
            account: reference.account.clone(),
        })
    }
}

/// Environment block for MCP client registration.
pub fn mcp_registration_env(db_path: impl Into<String>) -> BTreeMap<String, String> {
    let reference = KeychainKeyReference::default();
    BTreeMap::from([
        (ENV_DB_PATH.to_owned(), db_path.into()),
        (ENV_KEYCHAIN_SERVICE.to_owned(), reference.service),
        (ENV_KEYCHAIN_ACCOUNT.to_owned(), reference.account),
    ])
}

/// Validate SQLCipher key material without returning any key bytes in errors.
pub fn is_valid_database_key(key: &str) -> bool {
    key.len() == 64 && key.chars().all(|c| c.is_ascii_hexdigit())
}
