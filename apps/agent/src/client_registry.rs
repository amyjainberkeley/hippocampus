//! Safe, idempotent registration with local AI clients.
//!
//! Claude JSON and Codex TOML are patched structurally behind the same
//! ownership, locking, and atomic-write boundary. Generated entries carry a
//! database path and a stable Keychain reference, never database key material.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::ffi::OsString;
use std::fmt;
use std::fs::{File, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
use std::os::unix::fs::{FileExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
#[cfg(debug_assertions)]
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rustix::fs::{flock, renameat_with, FlockOperation, OFlags, RenameFlags, CWD};
use serde::de::{Error as _, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use toml_edit::{value, Array, DocumentMut, Item, Table};

use crate::key_resolver::{mcp_registration_env, DEFAULT_KEYCHAIN_SERVICE};

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const SERVER_NAME: &str = "hippocampus";
const KEYCHAIN_SERVICE_ENV: &str = "MCI_DB_KEYCHAIN_SERVICE";
const EXCHANGE_MARKER_VERSION: u8 = 2;
const MAX_EXCHANGE_MARKER_BYTES: u64 = 8 * 1024;

#[cfg(debug_assertions)]
type ClientRegistryDebugHook = Arc<dyn Fn(ClientRegistryDebugEvent) + Send + Sync>;
#[cfg(not(debug_assertions))]
type ClientRegistryDebugHook = ();

/// Atomic transaction boundaries exposed only to deterministic debug tests.
#[cfg(debug_assertions)]
#[doc(hidden)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientRegistryDebugEvent {
    /// The durable temp file and recovery marker exist, before replacement.
    BeforeAtomicReplace,
    /// The exchange completed, before post-exchange validation and cleanup.
    AfterAtomicExchange,
}

/// Whether one registration changed client configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationChange {
    /// The desired entry was written.
    Updated,
    /// The complete existing entry already matched semantically.
    AlreadyCurrent,
}

/// Outcome of repairing a registration that may or may not already exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationRepair {
    /// An existing Hippocampus entry was replaced with the canonical entry.
    Updated,
    /// The existing Hippocampus entry was already canonical.
    AlreadyCurrent,
    /// No Hippocampus entry exists; repair mode made no registration.
    NotRegistered,
}

/// Stable reason a registration was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationErrorKind {
    /// Existing client configuration was malformed or structurally invalid.
    BlockedMalformed,
    /// The server name exists but is not provably owned by Hippocampus.
    NameConflict,
    /// A path failed ownership, file-type, linking, or stability checks.
    UnsafePath,
    /// Another process changed the file during a conditional update.
    ConcurrentChange,
    /// A filesystem or serialization operation failed.
    Failed,
}

/// Content-free registration failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistrationError {
    /// Machine-readable refusal category.
    pub kind: RegistrationErrorKind,
    detail: String,
}

impl RegistrationError {
    fn new(kind: RegistrationErrorKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }
}

impl fmt::Display for RegistrationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for RegistrationError {}

/// User-visible state for one supported client.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationStatus {
    /// Configuration was created or updated.
    Registered,
    /// The complete entry already matched and no write occurred.
    Unchanged,
    /// The client executable and configuration root were not found.
    NotInstalled,
    /// Existing configuration could not be parsed safely.
    BlockedMalformed,
    /// An unrelated server already owns the `hippocampus` name.
    NameConflict,
    /// Registration failed without modifying unrelated client state.
    Failed,
}

/// Registration result for one client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientRegistration {
    /// Stable status suitable for UI rendering.
    pub status: RegistrationStatus,
    /// Bounded content-free diagnostic for a refused registration.
    pub detail: Option<String>,
}

/// Combined local-client registration report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectReport {
    /// Claude Code registration result.
    pub claude: ClientRegistration,
    /// Codex registration result.
    pub codex: ClientRegistration,
}

/// Per-client result of a best-effort existing-registration repair pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepairReport {
    /// Claude Code repair result.
    pub claude: Result<RegistrationRepair, RegistrationError>,
    /// Codex repair result.
    pub codex: Result<RegistrationRepair, RegistrationError>,
}

/// Paths and client detection used by the registry.
#[derive(Clone)]
pub struct ClientRegistry {
    home: PathBuf,
    agent_executable: PathBuf,
    codex_executable: Option<PathBuf>,
    codex_home: Option<PathBuf>,
    claude_detected: bool,
    #[cfg(debug_assertions)]
    debug_hook: Option<ClientRegistryDebugHook>,
}

impl fmt::Debug for ClientRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ClientRegistry")
            .field("home", &self.home)
            .field("agent_executable", &self.agent_executable)
            .field("codex_executable", &self.codex_executable)
            .field("codex_home", &self.codex_home)
            .field("claude_detected", &self.claude_detected)
            .finish_non_exhaustive()
    }
}

impl ClientRegistry {
    /// Construct an explicit registry. Tests use this to remain hermetic.
    #[must_use]
    pub const fn new(
        home: PathBuf,
        agent_executable: PathBuf,
        codex_executable: Option<PathBuf>,
        codex_home: Option<PathBuf>,
    ) -> Self {
        Self {
            home,
            agent_executable,
            codex_executable,
            codex_home,
            claude_detected: true,
            #[cfg(debug_assertions)]
            debug_hook: None,
        }
    }

    /// Install deterministic transaction synchronization points for tests.
    #[cfg(debug_assertions)]
    #[doc(hidden)]
    #[must_use]
    pub fn with_debug_hook(
        mut self,
        hook: Arc<dyn Fn(ClientRegistryDebugEvent) + Send + Sync>,
    ) -> Self {
        self.debug_hook = Some(hook);
        self
    }

    /// Discover the current agent, home directory, and installed clients.
    pub fn discover() -> Result<Self, String> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME not set".to_owned())?;
        let agent_executable = std::env::current_exe()
            .map_err(|error| format!("cannot resolve own binary path: {error}"))?;
        let codex_executable = discover_client_binary(
            "MCI_CODEX_BINARY",
            &["/Applications/Codex.app/Contents/Resources/codex"],
            "codex",
        );
        let codex_home = std::env::var_os("CODEX_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let claude_detected = discover_client_binary(
            "MCI_CLAUDE_BINARY",
            &["/usr/local/bin/claude", "/opt/homebrew/bin/claude"],
            "claude",
        )
        .is_some()
            || home.join(".claude.json").exists();
        Ok(Self {
            home,
            agent_executable,
            codex_executable,
            codex_home,
            claude_detected,
            #[cfg(debug_assertions)]
            debug_hook: None,
        })
    }

    /// Atomically merge the Hippocampus server into `~/.claude.json`.
    pub fn register_claude(&self, db_path: &Path) -> Result<RegistrationChange, RegistrationError> {
        let desired = self.desired_entry(db_path)?;
        let journal_directory = stable_journal_directory(&self.home)?;
        update_config(
            &self.home.join(".claude.json"),
            &journal_directory,
            |bytes| patch_claude_json(bytes, &desired),
        )
    }

    /// Patch Codex's user-wide TOML directly, preserving unrelated formatting.
    pub fn register_codex(&self, db_path: &Path) -> Result<RegistrationChange, RegistrationError> {
        let desired = self.desired_entry(db_path)?;
        let journal_directory = stable_journal_directory(&self.home)?;
        update_config(&self.codex_config_path(), &journal_directory, |bytes| {
            patch_codex_toml(bytes, &desired)
        })
    }

    /// Register every detected local client and retain per-client failures.
    #[must_use]
    pub fn connect_all(&self, db_path: &Path) -> ConnectReport {
        let claude = if self.claude_detected {
            registration_result(self.register_claude(db_path))
        } else {
            not_installed()
        };
        let codex = if self.codex_executable.is_some() || self.codex_config_path().exists() {
            registration_result(self.register_codex(db_path))
        } else {
            not_installed()
        };
        ConnectReport { claude, codex }
    }

    /// Repair only Hippocampus registrations that already exist.
    ///
    /// Missing client configs are intentionally not created. Per-client errors
    /// remain isolated so one malformed config cannot block repairing the other.
    #[must_use]
    pub fn repair_existing_registrations(&self, db_path: &Path) -> RepairReport {
        let claude = self.repair_existing_claude(db_path);
        let codex = self.repair_existing_codex(db_path);
        RepairReport { claude, codex }
    }

    /// Return the canonical reference-only Codex argument vector for inspection.
    pub fn codex_arguments(&self, db_path: &Path) -> Result<Vec<OsString>, RegistrationError> {
        let desired = self.desired_entry(db_path)?;
        let mut args = vec!["mcp".into(), "add".into(), SERVER_NAME.into()];
        for (key, value) in desired.env {
            args.push("--env".into());
            args.push(format!("{key}={value}").into());
        }
        args.push("--".into());
        args.push(self.agent_executable.as_os_str().to_owned());
        args.push("mcp-serve".into());
        Ok(args)
    }

    fn codex_config_path(&self) -> PathBuf {
        self.codex_home
            .clone()
            .unwrap_or_else(|| self.home.join(".codex"))
            .join("config.toml")
    }

    fn repair_existing_claude(
        &self,
        db_path: &Path,
    ) -> Result<RegistrationRepair, RegistrationError> {
        let path = self.home.join(".claude.json");
        let journal_directory = stable_journal_directory(&self.home)?;
        if !claude_config_has_owned_registration(&path, &journal_directory)? {
            return Ok(RegistrationRepair::NotRegistered);
        }
        let desired = self.desired_entry(db_path)?;
        repair_existing_config(
            &path,
            &journal_directory,
            |bytes| repair_claude_json(bytes, &desired),
            self.debug_hook(),
        )
    }

    fn repair_existing_codex(
        &self,
        db_path: &Path,
    ) -> Result<RegistrationRepair, RegistrationError> {
        let path = self.codex_config_path();
        let journal_directory = stable_journal_directory(&self.home)?;
        if !codex_config_has_owned_registration(&path, &journal_directory)? {
            return Ok(RegistrationRepair::NotRegistered);
        }
        let desired = self.desired_entry(db_path)?;
        repair_existing_config(
            &path,
            &journal_directory,
            |bytes| repair_codex_toml(bytes, &desired),
            self.debug_hook(),
        )
    }

    #[cfg(debug_assertions)]
    fn debug_hook(&self) -> Option<&ClientRegistryDebugHook> {
        self.debug_hook.as_ref()
    }

    #[cfg(not(debug_assertions))]
    const fn debug_hook(&self) -> Option<&ClientRegistryDebugHook> {
        None
    }

    fn desired_entry(&self, db_path: &Path) -> Result<DesiredEntry, RegistrationError> {
        let command = validate_agent_path(&self.agent_executable)?;
        let db_path = validate_database_path(db_path)?;
        Ok(DesiredEntry {
            command,
            env: mcp_registration_env(&db_path),
        })
    }
}

fn stable_journal_directory(path: &Path) -> Result<PathBuf, RegistrationError> {
    let resolved = resolve_config_target(path)?;
    let metadata = resolved
        .target
        .symlink_metadata()
        .map_err(|error| io_error("inspect client registry journal directory", &error))?;
    if !metadata.is_dir() || metadata.uid() != rustix::process::getuid().as_raw() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client registry journal directory is not a current-user directory",
        ));
    }
    Ok(resolved.target)
}

fn claude_config_has_owned_registration(
    path: &Path,
    journal_directory: &Path,
) -> Result<bool, RegistrationError> {
    inspect_existing_config(path, journal_directory, |bytes| {
        let Some(content) = bytes else {
            return Ok(false);
        };
        let root = parse_claude_json(content)?;
        let root = root.as_object().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude config root must be a JSON object",
            )
        })?;
        let Some(servers) = root.get("mcpServers") else {
            return Ok(false);
        };
        let servers = servers.as_object().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude mcpServers must be a JSON object",
            )
        })?;
        let Some(existing) = servers.get(SERVER_NAME) else {
            return Ok(false);
        };
        if claude_entry_is_repairable(existing)? {
            Ok(true)
        } else {
            Err(RegistrationError::new(
                RegistrationErrorKind::NameConflict,
                "Claude already has an unrelated server named hippocampus",
            ))
        }
    })
}

fn codex_config_has_owned_registration(
    path: &Path,
    journal_directory: &Path,
) -> Result<bool, RegistrationError> {
    inspect_existing_config(path, journal_directory, |bytes| {
        let Some(content) = bytes else {
            return Ok(false);
        };
        let document = std::str::from_utf8(content)
            .map_err(|_| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Codex config is not valid UTF-8",
                )
            })?
            .parse::<DocumentMut>()
            .map_err(|error| {
                let location = error
                    .span()
                    .map_or_else(String::new, |span| format!(" near byte {}", span.start));
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    format!("Codex config is not valid TOML{location}"),
                )
            })?;
        let Some(servers) = document.get("mcp_servers") else {
            return Ok(false);
        };
        let servers = servers.as_table_like().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Codex mcp_servers must be a table",
            )
        })?;
        let Some(existing) = servers.get(SERVER_NAME) else {
            return Ok(false);
        };
        if codex_entry_is_repairable(existing)? {
            Ok(true)
        } else {
            Err(RegistrationError::new(
                RegistrationErrorKind::NameConflict,
                "Codex already has an unrelated server named hippocampus",
            ))
        }
    })
}

fn inspect_existing_config<F>(
    path: &Path,
    journal_directory: &Path,
    inspector: F,
) -> Result<bool, RegistrationError>
where
    F: Fn(Option<&[u8]>) -> Result<bool, RegistrationError>,
{
    let resolved = resolve_config_target(path)?;
    validate_existing_target(&resolved.target)?;
    recover_exchange_artifacts_if_present(&resolved, journal_directory)?;
    let snapshot = read_target_snapshot(&resolved.target)?;
    inspector(snapshot.bytes())
}

#[derive(Debug, Clone)]
struct DesiredEntry {
    command: String,
    env: BTreeMap<String, String>,
}

enum PatchOutcome {
    NotRegistered,
    Unchanged,
    Write(Vec<u8>),
}

#[derive(Debug, Clone, Copy)]
enum PatchMode {
    Upsert,
    ExistingOnly,
}

fn patch_claude_json(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
) -> Result<PatchOutcome, RegistrationError> {
    patch_claude_json_with_mode(bytes, desired, PatchMode::Upsert)
}

fn repair_claude_json(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
) -> Result<PatchOutcome, RegistrationError> {
    patch_claude_json_with_mode(bytes, desired, PatchMode::ExistingOnly)
}

fn patch_claude_json_with_mode(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
    mode: PatchMode,
) -> Result<PatchOutcome, RegistrationError> {
    let mut root = match bytes {
        Some(content) => parse_claude_json(content)?
            .as_object()
            .cloned()
            .ok_or_else(|| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Claude config root must be a JSON object",
                )
            })?,
        None => serde_json::Map::new(),
    };
    let desired_value = desired_claude_value(desired);
    if matches!(mode, PatchMode::ExistingOnly)
        && root
            .get("mcpServers")
            .and_then(serde_json::Value::as_object)
            .is_none_or(|servers| !servers.contains_key(SERVER_NAME))
    {
        if root.contains_key("mcpServers") && !root["mcpServers"].is_object() {
            return Err(RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude mcpServers must be a JSON object",
            ));
        }
        return Ok(PatchOutcome::NotRegistered);
    }
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude mcpServers must be a JSON object",
            )
        })?;
    if let Some(existing) = servers.get(SERVER_NAME) {
        if existing == &desired_value {
            return Ok(PatchOutcome::Unchanged);
        }
        let is_owned = match mode {
            PatchMode::Upsert => claude_entry_is_owned(existing),
            PatchMode::ExistingOnly => claude_entry_is_repairable(existing)?,
        };
        if !is_owned {
            return Err(RegistrationError::new(
                RegistrationErrorKind::NameConflict,
                "Claude already has an unrelated server named hippocampus",
            ));
        }
    }
    servers.insert(SERVER_NAME.into(), desired_value);
    serde_json::to_vec_pretty(&root)
        .map(PatchOutcome::Write)
        .map_err(|error| {
            RegistrationError::new(
                RegistrationErrorKind::Failed,
                format!("serialize Claude config: {error}"),
            )
        })
}

struct UniqueJsonValue(serde_json::Value);

impl<'de> serde::Deserialize<'de> for UniqueJsonValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(UniqueJsonVisitor)
    }
}

struct UniqueJsonVisitor;

impl<'de> Visitor<'de> for UniqueJsonVisitor {
    type Value = UniqueJsonValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value without duplicate object keys")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::Bool(value)))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::Number(value.into())))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::Number(value.into())))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        serde_json::Number::from_f64(value)
            .map(serde_json::Value::Number)
            .map(UniqueJsonValue)
            .ok_or_else(|| E::custom("JSON number must be finite"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        self.visit_string(value.to_owned())
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::String(value)))
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::Null))
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(serde_json::Value::Null))
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<UniqueJsonValue>()? {
            values.push(value.0);
        }
        Ok(UniqueJsonValue(serde_json::Value::Array(values)))
    }

    fn visit_map<A>(self, mut entries: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut values = serde_json::Map::new();
        while let Some(key) = entries.next_key::<String>()? {
            if values.contains_key(&key) {
                return Err(A::Error::custom("duplicate JSON object key"));
            }
            let value = entries.next_value::<UniqueJsonValue>()?;
            values.insert(key, value.0);
        }
        Ok(UniqueJsonValue(serde_json::Value::Object(values)))
    }
}

fn parse_claude_json(content: &[u8]) -> Result<serde_json::Value, RegistrationError> {
    let mut deserializer = serde_json::Deserializer::from_slice(content);
    let parsed = <UniqueJsonValue as serde::Deserialize>::deserialize(&mut deserializer)
        .and_then(|value| {
            deserializer.end()?;
            Ok(value.0)
        })
        .map_err(|error| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                format!(
                    "Claude config is not valid unique-key JSON at line {} column {}",
                    error.line(),
                    error.column()
                ),
            )
        })?;
    Ok(parsed)
}

fn desired_claude_value(desired: &DesiredEntry) -> serde_json::Value {
    serde_json::json!({
        "type": "stdio",
        "command": desired.command,
        "args": ["mcp-serve"],
        "env": desired.env,
    })
}

fn claude_entry_is_owned(entry: &serde_json::Value) -> bool {
    let Some(object) = entry.as_object() else {
        return false;
    };
    let service_owned = object
        .get("env")
        .and_then(serde_json::Value::as_object)
        .and_then(|env| env.get(KEYCHAIN_SERVICE_ENV))
        .and_then(serde_json::Value::as_str)
        == Some(DEFAULT_KEYCHAIN_SERVICE);
    service_owned
        || command_and_args_are_owned(
            object.get("command").and_then(serde_json::Value::as_str),
            object
                .get("args")
                .and_then(serde_json::Value::as_array)
                .map(|args| args.iter().filter_map(serde_json::Value::as_str)),
        )
}

fn claude_entry_is_repairable(entry: &serde_json::Value) -> Result<bool, RegistrationError> {
    let object = entry.as_object().ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Claude hippocampus entry must be a JSON object",
        )
    })?;
    let command = object
        .get("command")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude hippocampus command must be a string",
            )
        })?;
    let args = object
        .get("args")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude hippocampus args must be an array",
            )
        })?;
    if !args.iter().all(serde_json::Value::is_string) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Claude hippocampus args must contain only strings",
        ));
    }
    if let Some(entry_type) = object.get("type") {
        let entry_type = entry_type.as_str().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Claude hippocampus type must be a string",
            )
        })?;
        if entry_type != "stdio" {
            return Ok(false);
        }
    }
    let service = match object.get("env") {
        None => None,
        Some(env) => {
            let env = env.as_object().ok_or_else(|| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Claude hippocampus env must be a JSON object",
                )
            })?;
            if !env.values().all(serde_json::Value::is_string) {
                return Err(RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Claude hippocampus env values must be strings",
                ));
            }
            match env.get(KEYCHAIN_SERVICE_ENV) {
                None => None,
                Some(value) => Some(value.as_str().ok_or_else(|| {
                    RegistrationError::new(
                        RegistrationErrorKind::BlockedMalformed,
                        "Claude hippocampus Keychain service must be a string",
                    )
                })?),
            }
        }
    };
    if service.is_some_and(|value| value != DEFAULT_KEYCHAIN_SERVICE) {
        return Ok(false);
    }
    let command_owned = Path::new(command)
        .file_name()
        .and_then(|value| value.to_str())
        == Some("mci-agent");
    let args_owned = args
        .iter()
        .filter_map(serde_json::Value::as_str)
        .any(|argument| argument == "mcp-serve");
    Ok(command_owned && (args_owned || service == Some(DEFAULT_KEYCHAIN_SERVICE)))
}

fn patch_codex_toml(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
) -> Result<PatchOutcome, RegistrationError> {
    patch_codex_toml_with_mode(bytes, desired, PatchMode::Upsert)
}

fn repair_codex_toml(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
) -> Result<PatchOutcome, RegistrationError> {
    patch_codex_toml_with_mode(bytes, desired, PatchMode::ExistingOnly)
}

fn patch_codex_toml_with_mode(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
    mode: PatchMode,
) -> Result<PatchOutcome, RegistrationError> {
    let mut document = match bytes {
        Some(content) => std::str::from_utf8(content)
            .map_err(|_| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Codex config is not valid UTF-8",
                )
            })?
            .parse::<DocumentMut>()
            .map_err(|error| {
                let location = error
                    .span()
                    .map_or_else(String::new, |span| format!(" near byte {}", span.start));
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    format!("Codex config is not valid TOML{location}"),
                )
            })?,
        None => DocumentMut::new(),
    };

    let mut has_existing_entry = false;
    if let Some(servers) = document.get("mcp_servers") {
        let servers = servers.as_table_like().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Codex mcp_servers must be a table",
            )
        })?;
        if let Some(existing) = servers.get(SERVER_NAME) {
            has_existing_entry = true;
            if codex_entry_matches(existing, desired) {
                return Ok(PatchOutcome::Unchanged);
            }
            let is_owned = match mode {
                PatchMode::Upsert => codex_entry_is_owned(existing),
                PatchMode::ExistingOnly => codex_entry_is_repairable(existing)?,
            };
            if !is_owned {
                return Err(RegistrationError::new(
                    RegistrationErrorKind::NameConflict,
                    "Codex already has an unrelated server named hippocampus",
                ));
            }
        }
    }

    if matches!(mode, PatchMode::ExistingOnly) && !has_existing_entry {
        return Ok(PatchOutcome::NotRegistered);
    }

    if document.get("mcp_servers").is_none() {
        let mut servers = Table::new();
        servers.set_implicit(true);
        document["mcp_servers"] = Item::Table(servers);
    }
    let servers = document["mcp_servers"].as_table_like_mut().ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Codex mcp_servers must be a table",
        )
    })?;
    servers.insert(SERVER_NAME, desired_codex_item(desired));
    Ok(PatchOutcome::Write(document.to_string().into_bytes()))
}

fn desired_codex_item(desired: &DesiredEntry) -> Item {
    let mut server = Table::new();
    server.insert("command", value(&desired.command));
    let mut args = Array::new();
    args.push("mcp-serve");
    server.insert("args", value(args));
    let mut env = Table::new();
    for (key, field) in &desired.env {
        env.insert(key, value(field));
    }
    server.insert("env", Item::Table(env));
    Item::Table(server)
}

fn codex_entry_matches(entry: &Item, desired: &DesiredEntry) -> bool {
    let Some(table) = entry.as_table_like() else {
        return false;
    };
    if table.len() != 3
        || table.get("command").and_then(Item::as_str) != Some(desired.command.as_str())
    {
        return false;
    }
    let Some(args) = table.get("args").and_then(Item::as_array) else {
        return false;
    };
    if args.len() != 1 || args.get(0).and_then(toml_edit::Value::as_str) != Some("mcp-serve") {
        return false;
    }
    let Some(env) = table.get("env").and_then(Item::as_table_like) else {
        return false;
    };
    env.len() == desired.env.len()
        && desired
            .env
            .iter()
            .all(|(key, expected)| env.get(key).and_then(Item::as_str) == Some(expected.as_str()))
}

fn codex_entry_is_owned(entry: &Item) -> bool {
    let Some(table) = entry.as_table_like() else {
        return false;
    };
    let service_owned = table
        .get("env")
        .and_then(Item::as_table_like)
        .and_then(|env| env.get(KEYCHAIN_SERVICE_ENV))
        .and_then(Item::as_str)
        == Some(DEFAULT_KEYCHAIN_SERVICE);
    let args = table
        .get("args")
        .and_then(Item::as_array)
        .map(|values| values.iter().filter_map(toml_edit::Value::as_str));
    service_owned || command_and_args_are_owned(table.get("command").and_then(Item::as_str), args)
}

fn codex_entry_is_repairable(entry: &Item) -> Result<bool, RegistrationError> {
    let table = entry.as_table_like().ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Codex hippocampus entry must be a table",
        )
    })?;
    let command = table.get("command").and_then(Item::as_str).ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Codex hippocampus command must be a string",
        )
    })?;
    let args = table.get("args").and_then(Item::as_array).ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Codex hippocampus args must be an array",
        )
    })?;
    if !args.iter().all(|value| value.as_str().is_some()) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::BlockedMalformed,
            "Codex hippocampus args must contain only strings",
        ));
    }
    let service = match table.get("env") {
        None => None,
        Some(env) => {
            let env = env.as_table_like().ok_or_else(|| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Codex hippocampus env must be a table",
                )
            })?;
            if !env.iter().all(|(_, value)| value.as_str().is_some()) {
                return Err(RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    "Codex hippocampus env values must be strings",
                ));
            }
            match env.get(KEYCHAIN_SERVICE_ENV) {
                None => None,
                Some(value) => Some(value.as_str().ok_or_else(|| {
                    RegistrationError::new(
                        RegistrationErrorKind::BlockedMalformed,
                        "Codex hippocampus Keychain service must be a string",
                    )
                })?),
            }
        }
    };
    if service.is_some_and(|value| value != DEFAULT_KEYCHAIN_SERVICE) {
        return Ok(false);
    }
    let command_owned = Path::new(command)
        .file_name()
        .and_then(|value| value.to_str())
        == Some("mci-agent");
    let args_owned = args
        .iter()
        .filter_map(toml_edit::Value::as_str)
        .any(|argument| argument == "mcp-serve");
    Ok(command_owned && (args_owned || service == Some(DEFAULT_KEYCHAIN_SERVICE)))
}

fn command_and_args_are_owned<'a>(
    command: Option<&str>,
    args: Option<impl Iterator<Item = &'a str>>,
) -> bool {
    command
        .and_then(|value| Path::new(value).file_name())
        .and_then(|value| value.to_str())
        == Some("mci-agent")
        && args.is_some_and(|mut values| values.any(|argument| argument == "mcp-serve"))
}

fn update_config<F>(
    logical_path: &Path,
    journal_directory: &Path,
    patcher: F,
) -> Result<RegistrationChange, RegistrationError>
where
    F: Fn(Option<&[u8]>) -> Result<PatchOutcome, RegistrationError>,
{
    let resolved = resolve_config_target(logical_path)?;
    ensure_private_parent(&resolved.target)?;
    let _lock = acquire_update_lock(&resolved.target)?;
    let _journal_lock = acquire_journal_lock(journal_directory, logical_path)?;
    recover_exchange_artifacts(logical_path, journal_directory)?;

    let before = read_target_snapshot(&resolved.target)?;
    let outcome = patcher(before.bytes())?;
    let output = match outcome {
        PatchOutcome::NotRegistered => {
            return Err(RegistrationError::new(
                RegistrationErrorKind::Failed,
                "upsert patch unexpectedly declined registration",
            ));
        }
        PatchOutcome::Unchanged => return Ok(RegistrationChange::AlreadyCurrent),
        PatchOutcome::Write(output) => output,
    };
    atomic_replace(
        &resolved,
        journal_directory,
        &output,
        before.mode(),
        &before,
        None,
    )?;
    let committed = read_target_snapshot(&resolved.target)?;
    if committed.bytes() != Some(output.as_slice()) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::Failed,
            "client config verification failed after atomic replace",
        ));
    }
    if !matches!(patcher(committed.bytes())?, PatchOutcome::Unchanged) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::Failed,
            "client config semantic verification failed after atomic replace",
        ));
    }
    if !resolution_is_current(&resolved)? {
        return Err(concurrent_change(
            "client config symlink chain changed before update completed",
        ));
    }
    Ok(RegistrationChange::Updated)
}

fn repair_existing_config<F>(
    logical_path: &Path,
    journal_directory: &Path,
    patcher: F,
    debug_hook: Option<&ClientRegistryDebugHook>,
) -> Result<RegistrationRepair, RegistrationError>
where
    F: Fn(Option<&[u8]>) -> Result<PatchOutcome, RegistrationError>,
{
    let resolved = resolve_config_target(logical_path)?;
    validate_existing_target(&resolved.target)?;
    let before_lock = read_target_snapshot(&resolved.target)?;
    match patcher(before_lock.bytes())? {
        PatchOutcome::NotRegistered => return Ok(RegistrationRepair::NotRegistered),
        PatchOutcome::Unchanged => return Ok(RegistrationRepair::AlreadyCurrent),
        PatchOutcome::Write(_) => {}
    }

    let _lock = acquire_update_lock(&resolved.target)?;
    let _journal_lock = acquire_journal_lock(journal_directory, logical_path)?;
    recover_exchange_artifacts(logical_path, journal_directory)?;
    let before = read_target_snapshot(&resolved.target)?;
    let output = match patcher(before.bytes())? {
        PatchOutcome::NotRegistered => return Ok(RegistrationRepair::NotRegistered),
        PatchOutcome::Unchanged => return Ok(RegistrationRepair::AlreadyCurrent),
        PatchOutcome::Write(output) => output,
    };
    atomic_replace(
        &resolved,
        journal_directory,
        &output,
        before.mode(),
        &before,
        debug_hook,
    )?;
    let committed = read_target_snapshot(&resolved.target)?;
    if committed.bytes() != Some(output.as_slice()) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::Failed,
            "client config verification failed after atomic replace",
        ));
    }
    if !matches!(patcher(committed.bytes())?, PatchOutcome::Unchanged) {
        return Err(RegistrationError::new(
            RegistrationErrorKind::Failed,
            "client config semantic verification failed after atomic replace",
        ));
    }
    if !resolution_is_current(&resolved)? {
        return Err(concurrent_change(
            "client config symlink chain changed before repair completed",
        ));
    }
    Ok(RegistrationRepair::Updated)
}

#[derive(Debug, PartialEq, Eq)]
struct ResolvedConfigTarget {
    logical_path: PathBuf,
    target: PathBuf,
    symlink_hops: Vec<SymlinkHopFingerprint>,
}

#[derive(Debug, PartialEq, Eq)]
struct SymlinkHopFingerprint {
    path: PathBuf,
    destination: PathBuf,
    device: u64,
    inode: u64,
    owner: u32,
    mode: u32,
}

enum OwnedPathComponent {
    DirectoryBoundary,
    Parent,
    Normal(OsString),
}

fn resolve_config_target(path: &Path) -> Result<ResolvedConfigTarget, RegistrationError> {
    const MAX_SYMLINK_HOPS: usize = 16;

    if !path.is_absolute() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config path must be absolute",
        ));
    }

    let mut current = PathBuf::from("/");
    let mut pending = owned_path_components(path);
    let mut seen = BTreeSet::new();
    let mut symlink_hops = Vec::new();
    let mut final_symlink_seen = false;
    while let Some(component) = pending.pop_front() {
        match component {
            OwnedPathComponent::DirectoryBoundary => {
                validate_required_directory(&current)?;
            }
            OwnedPathComponent::Parent => {
                current.pop();
            }
            OwnedPathComponent::Normal(name) => {
                let candidate = current.join(name);
                let metadata = match candidate.symlink_metadata() {
                    Ok(metadata) => metadata,
                    Err(error)
                        if error.kind() == ErrorKind::NotFound
                            && !final_symlink_seen
                            && !pending.iter().any(|part| {
                                matches!(part, OwnedPathComponent::DirectoryBoundary)
                            }) =>
                    {
                        current = candidate;
                        append_unresolved_components(&mut current, pending);
                        return Ok(resolved_config_target(path, current, symlink_hops));
                    }
                    Err(error) if error.kind() == ErrorKind::NotFound => {
                        return Err(RegistrationError::new(
                            RegistrationErrorKind::UnsafePath,
                            "client config symlink target does not exist",
                        ));
                    }
                    Err(error) => return Err(io_error("inspect client config component", &error)),
                };

                if !metadata.file_type().is_symlink() {
                    if !pending.is_empty() && !metadata.is_dir() {
                        return Err(RegistrationError::new(
                            RegistrationErrorKind::UnsafePath,
                            "client config parent component is not a directory",
                        ));
                    }
                    current = candidate;
                    continue;
                }

                if symlink_hops.len() == MAX_SYMLINK_HOPS {
                    return Err(RegistrationError::new(
                        RegistrationErrorKind::UnsafePath,
                        "client config symlink chain exceeds the hop limit",
                    ));
                }
                if !seen.insert((metadata.dev(), metadata.ino())) {
                    return Err(RegistrationError::new(
                        RegistrationErrorKind::UnsafePath,
                        "client config symlink chain contains a cycle",
                    ));
                }
                if pending.is_empty() {
                    final_symlink_seen = true;
                }
                let link = std::fs::read_link(&candidate)
                    .map_err(|error| io_error("read client config link", &error))?;
                let after = candidate
                    .symlink_metadata()
                    .map_err(|error| io_error("reinspect client config link", &error))?;
                if !same_symlink(&metadata, &after) {
                    return Err(concurrent_change(
                        "client config symlink changed while it was resolved",
                    ));
                }
                symlink_hops.push(SymlinkHopFingerprint {
                    path: candidate,
                    destination: link.clone(),
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    owner: metadata.uid(),
                    mode: metadata.mode(),
                });

                let is_parent = !pending.is_empty();
                let mut destination = owned_path_components(&link);
                if link.is_absolute() {
                    current = PathBuf::from("/");
                }
                if is_parent {
                    destination.push_back(OwnedPathComponent::DirectoryBoundary);
                }
                destination.append(&mut pending);
                pending = destination;
            }
        }
    }

    Ok(resolved_config_target(path, current, symlink_hops))
}

fn resolved_config_target(
    logical_path: &Path,
    target: PathBuf,
    symlink_hops: Vec<SymlinkHopFingerprint>,
) -> ResolvedConfigTarget {
    ResolvedConfigTarget {
        logical_path: logical_path.to_path_buf(),
        target,
        symlink_hops,
    }
}

fn validate_required_directory(path: &Path) -> Result<(), RegistrationError> {
    let metadata = path
        .symlink_metadata()
        .map_err(|error| io_error("inspect client config symlinked parent target", &error))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config symlinked parent target is not a directory",
        ));
    }
    Ok(())
}

fn same_symlink(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    right.file_type().is_symlink()
        && left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.uid() == right.uid()
        && left.mode() == right.mode()
}

fn owned_path_components(path: &Path) -> VecDeque<OwnedPathComponent> {
    path.components()
        .filter_map(|component| match component {
            Component::RootDir | Component::CurDir => None,
            Component::ParentDir => Some(OwnedPathComponent::Parent),
            Component::Normal(name) => Some(OwnedPathComponent::Normal(name.to_owned())),
            Component::Prefix(_) => unreachable!("Unix paths do not contain prefixes"),
        })
        .collect()
}

fn append_unresolved_components(path: &mut PathBuf, components: VecDeque<OwnedPathComponent>) {
    for component in components {
        match component {
            OwnedPathComponent::DirectoryBoundary => {
                unreachable!("missing paths cannot cross a required directory boundary")
            }
            OwnedPathComponent::Parent => {
                path.pop();
            }
            OwnedPathComponent::Normal(name) => path.push(name),
        }
    }
}

fn resolution_is_current(resolved: &ResolvedConfigTarget) -> Result<bool, RegistrationError> {
    match resolve_config_target(&resolved.logical_path) {
        Ok(current) => Ok(current == *resolved),
        Err(error)
            if matches!(
                error.kind,
                RegistrationErrorKind::UnsafePath | RegistrationErrorKind::ConcurrentChange
            ) =>
        {
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn validate_existing_target(path: &Path) -> Result<(), RegistrationError> {
    let metadata = match path.symlink_metadata() {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error("inspect client config target", &error)),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target is not a regular file",
        ));
    }
    let current_uid = rustix::process::getuid().as_raw();
    if metadata.uid() != current_uid {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target is not owned by the current user",
        ));
    }
    if metadata.nlink() != 1 {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target has multiple hard links",
        ));
    }
    Ok(())
}

fn ensure_private_parent(path: &Path) -> Result<(), RegistrationError> {
    let parent = path.parent().ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config has no parent directory",
        )
    })?;
    let existed = parent.exists();
    std::fs::create_dir_all(parent)
        .map_err(|error| io_error("create client config directory", &error))?;
    if !existed {
        std::fs::set_permissions(parent, Permissions::from_mode(0o700))
            .map_err(|error| io_error("secure client config directory", &error))?;
    }
    Ok(())
}

fn acquire_update_lock(path: &Path) -> Result<File, RegistrationError> {
    let parent = path.parent().expect("validated config parent");
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("client-config");
    let lock_path = parent.join(format!(".{name}.hippocampus.lock"));
    if lock_path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config lock must not be a symlink",
        ));
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|error| io_error("open client config lock", &error))?;
    let metadata = lock
        .metadata()
        .map_err(|error| io_error("inspect client config lock", &error))?;
    if metadata.uid() != rustix::process::getuid().as_raw()
        || !metadata.is_file()
        || metadata.nlink() != 1
    {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config lock is not a current-user regular file",
        ));
    }
    flock(&lock, FlockOperation::LockExclusive).map_err(|error| {
        RegistrationError::new(
            RegistrationErrorKind::Failed,
            format!("lock client config: {error}"),
        )
    })?;
    Ok(lock)
}

enum TargetSnapshot {
    Missing,
    Existing {
        device: u64,
        inode: u64,
        length: u64,
        modified_seconds: i64,
        modified_nanoseconds: i64,
        changed_seconds: i64,
        changed_nanoseconds: i64,
        mode: u32,
        bytes: Vec<u8>,
        file: File,
    },
}

impl TargetSnapshot {
    fn bytes(&self) -> Option<&[u8]> {
        match self {
            Self::Missing => None,
            Self::Existing { bytes, .. } => Some(bytes),
        }
    }

    const fn mode(&self) -> u32 {
        match self {
            Self::Missing => 0o600,
            Self::Existing { mode, .. } => *mode,
        }
    }

    const fn exists(&self) -> bool {
        matches!(self, Self::Existing { .. })
    }

    fn same_snapshot(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Missing, Self::Missing) => true,
            (
                Self::Existing {
                    device: left_device,
                    inode: left_inode,
                    length: left_length,
                    modified_seconds: left_modified_seconds,
                    modified_nanoseconds: left_modified_nanoseconds,
                    changed_seconds: left_changed_seconds,
                    changed_nanoseconds: left_changed_nanoseconds,
                    mode: left_mode,
                    bytes: left_bytes,
                    ..
                },
                Self::Existing {
                    device: right_device,
                    inode: right_inode,
                    length: right_length,
                    modified_seconds: right_modified_seconds,
                    modified_nanoseconds: right_modified_nanoseconds,
                    changed_seconds: right_changed_seconds,
                    changed_nanoseconds: right_changed_nanoseconds,
                    mode: right_mode,
                    bytes: right_bytes,
                    ..
                },
            ) => {
                left_device == right_device
                    && left_inode == right_inode
                    && left_length == right_length
                    && left_modified_seconds == right_modified_seconds
                    && left_modified_nanoseconds == right_modified_nanoseconds
                    && left_changed_seconds == right_changed_seconds
                    && left_changed_nanoseconds == right_changed_nanoseconds
                    && left_mode == right_mode
                    && left_bytes == right_bytes
            }
            (Self::Missing, Self::Existing { .. }) | (Self::Existing { .. }, Self::Missing) => {
                false
            }
        }
    }

    fn identity(&self) -> Option<(u64, u64)> {
        match self {
            Self::Missing => None,
            Self::Existing { device, inode, .. } => Some((*device, *inode)),
        }
    }

    fn proof(&self) -> Option<ExchangeFileProof> {
        match self {
            Self::Missing => None,
            Self::Existing {
                device,
                inode,
                length,
                bytes,
                ..
            } => Some(ExchangeFileProof {
                device: *device,
                inode: *inode,
                length: *length,
                sha256: sha256_hex(bytes),
            }),
        }
    }

    fn retained_file_matches(&self) -> Result<bool, RegistrationError> {
        let Self::Existing {
            device,
            inode,
            length,
            modified_seconds,
            modified_nanoseconds,
            mode,
            bytes,
            file,
            ..
        } = self
        else {
            return Ok(true);
        };
        let before = file
            .metadata()
            .map_err(|error| io_error("inspect retained client config", &error))?;
        let current_uid = rustix::process::getuid().as_raw();
        if !before.is_file()
            || before.uid() != current_uid
            || before.nlink() != 1
            || before.dev() != *device
            || before.ino() != *inode
            || before.len() != *length
            || before.mtime() != *modified_seconds
            || before.mtime_nsec() != *modified_nanoseconds
            || before.permissions().mode() & 0o777 != *mode
        {
            return Ok(false);
        }
        let mut actual = vec![0; bytes.len()];
        let mut offset = 0;
        while offset < actual.len() {
            match file.read_at(&mut actual[offset..], offset as u64) {
                Ok(0) => return Ok(false),
                Ok(read) => offset += read,
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(error) => return Err(io_error("read retained client config", &error)),
            }
        }
        let mut trailing = [0_u8; 1];
        if file
            .read_at(&mut trailing, actual.len() as u64)
            .map_err(|error| io_error("verify retained client config length", &error))?
            != 0
        {
            return Ok(false);
        }
        let after = file
            .metadata()
            .map_err(|error| io_error("reinspect retained client config", &error))?;
        Ok(before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.len() == after.len()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && after.uid() == current_uid
            && after.nlink() == 1
            && after.permissions().mode() & 0o777 == *mode
            && actual == *bytes)
    }
}

fn read_target_snapshot(path: &Path) -> Result<TargetSnapshot, RegistrationError> {
    let no_follow = i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
        .expect("open flags fit platform c_int");
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(no_follow)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(TargetSnapshot::Missing),
        Err(_) => {
            return Err(RegistrationError::new(
                RegistrationErrorKind::UnsafePath,
                "client config target could not be opened without following links",
            ));
        }
    };
    let before = file
        .metadata()
        .map_err(|error| io_error("inspect open client config target", &error))?;
    validate_target_metadata(&before)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| io_error("read open client config target", &error))?;
    let after = file
        .metadata()
        .map_err(|error| io_error("reinspect open client config target", &error))?;
    if metadata_fingerprint(&before) != metadata_fingerprint(&after) {
        return Err(concurrent_change(
            "client config changed while it was being read",
        ));
    }
    Ok(TargetSnapshot::Existing {
        device: before.dev(),
        inode: before.ino(),
        length: before.len(),
        modified_seconds: before.mtime(),
        modified_nanoseconds: before.mtime_nsec(),
        changed_seconds: before.ctime(),
        changed_nanoseconds: before.ctime_nsec(),
        mode: before.permissions().mode() & 0o777,
        bytes,
        file,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ExchangeFileProof {
    device: u64,
    inode: u64,
    length: u64,
    sha256: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ExchangeMarker {
    version: u8,
    logical_path_sha256: String,
    target_path: Vec<u8>,
    artifact_name: String,
    original: Option<ExchangeFileProof>,
    output: ExchangeFileProof,
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn metadata_fingerprint(metadata: &std::fs::Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

fn validate_target_metadata(metadata: &std::fs::Metadata) -> Result<(), RegistrationError> {
    if !metadata.is_file() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target is not a regular file",
        ));
    }
    if metadata.uid() != rustix::process::getuid().as_raw() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target is not owned by the current user",
        ));
    }
    if metadata.nlink() != 1 {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client config target has multiple hard links",
        ));
    }
    Ok(())
}

fn logical_path_sha256(path: &Path) -> String {
    sha256_hex(path.as_os_str().as_bytes())
}

fn exchange_marker_prefix(logical_path: &Path) -> String {
    format!(
        ".hippocampus-client-registry-journal-{}-",
        logical_path_sha256(logical_path)
    )
}

fn exchange_marker_path(
    logical_path: &Path,
    journal_directory: &Path,
    timestamp: u128,
    sequence: u64,
) -> PathBuf {
    journal_directory.join(format!(
        "{}{}-{timestamp}-{sequence}.marker",
        exchange_marker_prefix(logical_path),
        std::process::id()
    ))
}

fn exchange_marker_paths(
    logical_path: &Path,
    journal_directory: &Path,
) -> Result<Vec<PathBuf>, RegistrationError> {
    let entries = match std::fs::read_dir(journal_directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(io_error("scan client registry journals", &error)),
    };
    let prefix = exchange_marker_prefix(logical_path);
    let mut markers = Vec::new();
    for entry in entries {
        let entry =
            entry.map_err(|error| io_error("read client registry journal directory", &error))?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name.starts_with(&prefix) && name.ends_with(".marker") {
            markers.push(entry.path());
        }
    }
    Ok(markers)
}

fn recover_exchange_artifacts_if_present(
    resolved: &ResolvedConfigTarget,
    journal_directory: &Path,
) -> Result<(), RegistrationError> {
    if exchange_marker_paths(&resolved.logical_path, journal_directory)?.is_empty() {
        return Ok(());
    }
    let _lock = acquire_journal_lock(journal_directory, &resolved.logical_path)?;
    recover_exchange_artifacts(&resolved.logical_path, journal_directory)?;
    if !resolution_is_current(resolved)? {
        return Err(concurrent_change(
            "client config symlink chain changed during exchange recovery",
        ));
    }
    Ok(())
}

fn recover_exchange_artifacts(
    logical_path: &Path,
    journal_directory: &Path,
) -> Result<(), RegistrationError> {
    let logical_path_sha256 = logical_path_sha256(logical_path);
    let mut changed_directories = BTreeSet::new();
    let mut journal_changed = false;
    for marker_path in exchange_marker_paths(logical_path, journal_directory)? {
        let Some(marker) = read_exchange_marker(&marker_path)? else {
            continue;
        };
        if marker.version != EXCHANGE_MARKER_VERSION
            || marker.logical_path_sha256 != logical_path_sha256
            || marker.target_path.is_empty()
        {
            continue;
        }
        let target_path = PathBuf::from(OsString::from_vec(marker.target_path.clone()));
        let Ok(recorded_target) = resolve_config_target(&target_path) else {
            continue;
        };
        if !target_path.is_absolute()
            || recorded_target.target != target_path
            || !recorded_target.symlink_hops.is_empty()
        {
            continue;
        }
        let parent = target_path
            .parent()
            .expect("absolute config target has a parent");
        let expected_temp_prefix = format!(
            ".{}.tmp-",
            target_path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("client-config")
        );
        if !is_generated_artifact_name(&marker.artifact_name, &expected_temp_prefix) {
            continue;
        }
        let artifact_path = parent.join(&marker.artifact_name);
        let artifact = match read_target_snapshot(&artifact_path) {
            Ok(artifact) => artifact,
            Err(error) if error.kind == RegistrationErrorKind::UnsafePath => continue,
            Err(error) => return Err(error),
        };
        let Some(proof) = artifact.proof() else {
            std::fs::remove_file(&marker_path)
                .map_err(|error| io_error("remove stale exchange marker", &error))?;
            journal_changed = true;
            continue;
        };
        if marker.original.as_ref() != Some(&proof) && marker.output != proof {
            continue;
        }
        if path_identity(&artifact_path) != artifact.identity() {
            continue;
        }
        std::fs::remove_file(&artifact_path)
            .map_err(|error| io_error("remove stale exchange artifact", &error))?;
        std::fs::remove_file(&marker_path)
            .map_err(|error| io_error("remove recovered exchange marker", &error))?;
        changed_directories.insert(parent.to_path_buf());
        journal_changed = true;
    }
    for directory in changed_directories {
        sync_directory(&directory)?;
    }
    if journal_changed {
        sync_directory(journal_directory)?;
    }
    Ok(())
}

fn acquire_journal_lock(
    journal_directory: &Path,
    logical_path: &Path,
) -> Result<File, RegistrationError> {
    let lock_path = journal_directory.join(format!("{}lock", exchange_marker_prefix(logical_path)));
    let no_follow = i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
        .expect("open flags fit platform c_int");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(no_follow)
        .open(lock_path)
        .map_err(|error| io_error("open client registry journal lock", &error))?;
    let metadata = lock
        .metadata()
        .map_err(|error| io_error("inspect client registry journal lock", &error))?;
    if metadata.uid() != rustix::process::getuid().as_raw()
        || !metadata.is_file()
        || metadata.nlink() != 1
    {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "client registry journal lock is not a current-user regular file",
        ));
    }
    flock(&lock, FlockOperation::LockExclusive).map_err(|error| {
        RegistrationError::new(
            RegistrationErrorKind::Failed,
            format!("lock client registry journal: {error}"),
        )
    })?;
    Ok(lock)
}

fn is_generated_artifact_name(name: &str, expected_prefix: &str) -> bool {
    let path = Path::new(name);
    path.components().count() == 1
        && path.file_name().and_then(|value| value.to_str()) == Some(name)
        && name.starts_with(expected_prefix)
}

fn read_exchange_marker(path: &Path) -> Result<Option<ExchangeMarker>, RegistrationError> {
    let no_follow = i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
        .expect("open flags fit platform c_int");
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(no_follow)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Ok(None),
    };
    let before = file
        .metadata()
        .map_err(|error| io_error("inspect exchange marker", &error))?;
    if !before.is_file()
        || before.uid() != rustix::process::getuid().as_raw()
        || before.nlink() != 1
        || before.permissions().mode() & 0o077 != 0
        || before.len() > MAX_EXCHANGE_MARKER_BYTES
    {
        return Ok(None);
    }
    let mut bytes = Vec::with_capacity(
        usize::try_from(before.len()).expect("bounded marker length fits usize"),
    );
    file.read_to_end(&mut bytes)
        .map_err(|error| io_error("read exchange marker", &error))?;
    let after = file
        .metadata()
        .map_err(|error| io_error("reinspect exchange marker", &error))?;
    if metadata_fingerprint(&before) != metadata_fingerprint(&after) {
        return Ok(None);
    }
    let Ok(value) = parse_claude_json(&bytes) else {
        return Ok(None);
    };
    Ok(serde_json::from_value(value).ok())
}

fn write_exchange_marker(path: &Path, marker: &ExchangeMarker) -> Result<(), RegistrationError> {
    let bytes = serde_json::to_vec(marker).map_err(|error| {
        RegistrationError::new(
            RegistrationErrorKind::Failed,
            format!("serialize client config exchange marker: {error}"),
        )
    })?;
    let no_follow = i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
        .expect("open flags fit platform c_int");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(no_follow)
        .open(path)
        .map_err(|error| io_error("create client config exchange marker", &error))?;
    file.write_all(&bytes)
        .map_err(|error| io_error("write client config exchange marker", &error))?;
    file.sync_all()
        .map_err(|error| io_error("sync client config exchange marker", &error))
}

struct ExchangeTransaction {
    temp_path: PathBuf,
    marker_path: PathBuf,
    output_identity: (u64, u64),
}

fn atomic_replace(
    resolved: &ResolvedConfigTarget,
    journal_directory: &Path,
    bytes: &[u8],
    mode: u32,
    expected: &TargetSnapshot,
    debug_hook: Option<&ClientRegistryDebugHook>,
) -> Result<(), RegistrationError> {
    let transaction =
        prepare_exchange_transaction(resolved, journal_directory, bytes, mode, expected)?;
    #[cfg(debug_assertions)]
    if let Some(hook) = debug_hook {
        hook(ClientRegistryDebugEvent::BeforeAtomicReplace);
    }
    let result = commit_exchange_transaction(resolved, expected, &transaction, debug_hook);
    if result.is_err() {
        cleanup_exchange_transaction(
            &transaction.temp_path,
            &transaction.marker_path,
            transaction.output_identity,
            expected.identity(),
        );
    }
    result
}

fn prepare_exchange_transaction(
    resolved: &ResolvedConfigTarget,
    journal_directory: &Path,
    bytes: &[u8],
    mode: u32,
    expected: &TargetSnapshot,
) -> Result<ExchangeTransaction, RegistrationError> {
    let path = &resolved.target;
    let parent = path.parent().expect("validated config parent");
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temp_path = parent.join(format!(
        ".{}.tmp-{}-{timestamp}-{sequence}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("client-config"),
        std::process::id()
    ));
    let mut temp = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp_path)
        .map_err(|error| io_error("create client config temp file", &error))?;
    let temp_metadata = match temp.metadata() {
        Ok(metadata) => metadata,
        Err(error) => {
            drop(temp);
            let _ = std::fs::remove_file(&temp_path);
            return Err(io_error("inspect client config temp file", &error));
        }
    };
    let output_identity = (temp_metadata.dev(), temp_metadata.ino());
    let output_proof = ExchangeFileProof {
        device: temp_metadata.dev(),
        inode: temp_metadata.ino(),
        length: u64::try_from(bytes.len()).expect("config length fits u64"),
        sha256: sha256_hex(bytes),
    };
    let marker_path = exchange_marker_path(
        &resolved.logical_path,
        journal_directory,
        timestamp,
        sequence,
    );
    let result = (|| {
        temp.write_all(bytes)
            .map_err(|error| io_error("write client config temp file", &error))?;
        temp.set_permissions(Permissions::from_mode(mode))
            .map_err(|error| io_error("preserve client config mode", &error))?;
        temp.sync_all()
            .map_err(|error| io_error("sync client config temp file", &error))?;
        drop(temp);
        write_exchange_marker(
            &marker_path,
            &ExchangeMarker {
                version: EXCHANGE_MARKER_VERSION,
                logical_path_sha256: logical_path_sha256(&resolved.logical_path),
                target_path: path.as_os_str().as_bytes().to_vec(),
                artifact_name: temp_path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .expect("generated temp name is UTF-8")
                    .to_owned(),
                original: expected.proof(),
                output: output_proof.clone(),
            },
        )?;
        sync_directory(parent)?;
        if journal_directory != parent {
            sync_directory(journal_directory)?;
        }
        Ok(())
    })();
    if result.is_err() {
        cleanup_exchange_transaction(
            &temp_path,
            &marker_path,
            output_identity,
            expected.identity(),
        );
    }
    result?;
    Ok(ExchangeTransaction {
        temp_path,
        marker_path,
        output_identity,
    })
}

fn commit_exchange_transaction(
    resolved: &ResolvedConfigTarget,
    expected: &TargetSnapshot,
    transaction: &ExchangeTransaction,
    debug_hook: Option<&ClientRegistryDebugHook>,
) -> Result<(), RegistrationError> {
    let path = &resolved.target;
    if !target_matches_snapshot(path, expected)? {
        return Err(concurrent_change(
            "client config identity or content changed before replace",
        ));
    }
    if !resolution_is_current(resolved)? {
        return Err(concurrent_change(
            "client config symlink chain changed before atomic replace",
        ));
    }
    exchange_config(path, &transaction.temp_path, expected.exists())?;
    #[cfg(debug_assertions)]
    if let Some(hook) = debug_hook {
        hook(ClientRegistryDebugEvent::AfterAtomicExchange);
    }
    #[cfg(not(debug_assertions))]
    let _ = debug_hook;
    if expected.exists() {
        verify_existing_exchange(resolved, expected, transaction)?;
    } else if !resolution_is_current(resolved)? {
        if path_identity(path) == Some(transaction.output_identity) {
            std::fs::remove_file(path)
                .map_err(|error| io_error("remove retargeted client config", &error))?;
        }
        return Err(concurrent_change(
            "client config symlink chain changed during atomic create",
        ));
    }
    std::fs::remove_file(&transaction.marker_path)
        .map_err(|error| io_error("remove client config exchange marker", &error))?;
    let target_parent = path.parent().expect("validated config parent");
    sync_directory(target_parent)?;
    let marker_parent = transaction
        .marker_path
        .parent()
        .expect("validated journal parent");
    if marker_parent != target_parent {
        sync_directory(marker_parent)?;
    }
    Ok(())
}

fn exchange_config(
    path: &Path,
    temp_path: &Path,
    target_exists: bool,
) -> Result<(), RegistrationError> {
    let flags = if target_exists {
        RenameFlags::EXCHANGE
    } else {
        RenameFlags::NOREPLACE
    };
    if let Err(error) = renameat_with(CWD, temp_path, CWD, path, flags) {
        if error == rustix::io::Errno::NOENT || error == rustix::io::Errno::EXIST {
            return Err(concurrent_change(
                "client config changed during atomic replace",
            ));
        }
        return Err(RegistrationError::new(
            RegistrationErrorKind::Failed,
            format!("replace client config: {error}"),
        ));
    }
    Ok(())
}

fn verify_existing_exchange(
    resolved: &ResolvedConfigTarget,
    expected: &TargetSnapshot,
    transaction: &ExchangeTransaction,
) -> Result<(), RegistrationError> {
    let path = &resolved.target;
    if path_identity(&transaction.temp_path) != expected.identity() {
        rollback_exchange(path, &transaction.temp_path, transaction.output_identity)?;
        return Err(concurrent_change(
            "client config changed during atomic replace",
        ));
    }
    if !resolution_is_current(resolved)? {
        rollback_exchange(path, &transaction.temp_path, transaction.output_identity)?;
        return Err(concurrent_change(
            "client config symlink chain changed during atomic replace",
        ));
    }
    match expected.retained_file_matches() {
        Ok(true) => {}
        Ok(false) => {
            rollback_exchange(path, &transaction.temp_path, transaction.output_identity)?;
            return Err(concurrent_change(
                "client config content changed during atomic replace",
            ));
        }
        Err(error) => {
            rollback_exchange(path, &transaction.temp_path, transaction.output_identity)?;
            return Err(error);
        }
    }
    if path_identity(&transaction.temp_path) != expected.identity()
        || !resolution_is_current(resolved)?
    {
        rollback_exchange(path, &transaction.temp_path, transaction.output_identity)?;
        return Err(concurrent_change(
            "client config changed after post-exchange validation",
        ));
    }
    std::fs::remove_file(&transaction.temp_path)
        .map_err(|error| io_error("remove replaced client config", &error))?;
    Ok(())
}

fn rollback_exchange(
    path: &Path,
    temp_path: &Path,
    output_identity: (u64, u64),
) -> Result<(), RegistrationError> {
    if path_identity(path) != Some(output_identity) {
        return Err(concurrent_change(
            "client config changed before atomic rollback",
        ));
    }
    renameat_with(CWD, temp_path, CWD, path, RenameFlags::EXCHANGE).map_err(|error| {
        RegistrationError::new(
            RegistrationErrorKind::Failed,
            format!("restore client config after interrupted replace: {error}"),
        )
    })
}

fn cleanup_exchange_transaction(
    temp_path: &Path,
    marker_path: &Path,
    output_identity: (u64, u64),
    original_identity: Option<(u64, u64)>,
) {
    let temp_identity = path_identity(temp_path);
    let recognized = temp_identity == Some(output_identity) || temp_identity == original_identity;
    if recognized {
        let _ = std::fs::remove_file(temp_path);
    }
    let remaining_identity = path_identity(temp_path);
    if remaining_identity.is_none()
        || (remaining_identity != Some(output_identity) && remaining_identity != original_identity)
    {
        let _ = std::fs::remove_file(marker_path);
    }
    if let Some(parent) = temp_path.parent() {
        let _ = sync_directory(parent);
    }
    if let Some(parent) = marker_path
        .parent()
        .filter(|parent| Some(*parent) != temp_path.parent())
    {
        let _ = sync_directory(parent);
    }
}

fn path_identity(path: &Path) -> Option<(u64, u64)> {
    path.symlink_metadata()
        .ok()
        .filter(|metadata| !metadata.file_type().is_symlink())
        .map(|metadata| (metadata.dev(), metadata.ino()))
}

fn sync_directory(path: &Path) -> Result<(), RegistrationError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| io_error("sync client config directory", &error))
}

fn target_matches_snapshot(
    path: &Path,
    expected: &TargetSnapshot,
) -> Result<bool, RegistrationError> {
    match read_target_snapshot(path) {
        Ok(actual) => Ok(actual.same_snapshot(expected)),
        Err(error) if error.kind == RegistrationErrorKind::UnsafePath => Ok(false),
        Err(error) => Err(error),
    }
}

fn concurrent_change(detail: &str) -> RegistrationError {
    RegistrationError::new(RegistrationErrorKind::ConcurrentChange, detail)
}

fn validate_agent_path(path: &Path) -> Result<String, RegistrationError> {
    if !path.is_absolute() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "agent executable path must be absolute",
        ));
    }
    let metadata = path
        .metadata()
        .map_err(|error| io_error("inspect agent executable", &error))?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "agent executable must be a regular executable file",
        ));
    }
    let rendered = path.to_str().ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "agent executable path is not valid UTF-8",
        )
    })?;
    if !cfg!(debug_assertions)
        && (rendered.contains("/AppTranslocation/") || !is_stable_bundle_agent(path))
    {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "install Hippocampus in a stable Applications location before connecting AI tools",
        ));
    }
    Ok(rendered.to_owned())
}

fn is_stable_bundle_agent(path: &Path) -> bool {
    let components = path
        .components()
        .filter_map(|component| component.as_os_str().to_str())
        .collect::<Vec<_>>();
    components.len() >= 4
        && components[components.len() - 1] == "mci-agent"
        && components[components.len() - 2] == "MacOS"
        && components[components.len() - 3] == "Contents"
        && Path::new(components[components.len() - 4])
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("app"))
}

fn validate_database_path(path: &Path) -> Result<String, RegistrationError> {
    if !path.is_absolute() {
        return Err(RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "brain path must be absolute",
        ));
    }
    path.to_str().map(str::to_owned).ok_or_else(|| {
        RegistrationError::new(
            RegistrationErrorKind::UnsafePath,
            "brain path is not valid UTF-8",
        )
    })
}

fn registration_result(
    result: Result<RegistrationChange, RegistrationError>,
) -> ClientRegistration {
    match result {
        Ok(RegistrationChange::Updated) => ClientRegistration {
            status: RegistrationStatus::Registered,
            detail: None,
        },
        Ok(RegistrationChange::AlreadyCurrent) => ClientRegistration {
            status: RegistrationStatus::Unchanged,
            detail: None,
        },
        Err(error) => ClientRegistration {
            status: match error.kind {
                RegistrationErrorKind::BlockedMalformed => RegistrationStatus::BlockedMalformed,
                RegistrationErrorKind::NameConflict => RegistrationStatus::NameConflict,
                RegistrationErrorKind::UnsafePath
                | RegistrationErrorKind::ConcurrentChange
                | RegistrationErrorKind::Failed => RegistrationStatus::Failed,
            },
            detail: Some(error.to_string()),
        },
    }
}

fn not_installed() -> ClientRegistration {
    ClientRegistration {
        status: RegistrationStatus::NotInstalled,
        detail: None,
    }
}

fn io_error(action: &str, error: &std::io::Error) -> RegistrationError {
    RegistrationError::new(RegistrationErrorKind::Failed, format!("{action}: {error}"))
}

fn discover_client_binary(environment: &str, fixed: &[&str], basename: &str) -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(environment).map(PathBuf::from) {
        if is_executable(&path) {
            return Some(path);
        }
    }
    if let Some(path) = fixed
        .iter()
        .map(PathBuf::from)
        .find(|path| is_executable(path))
    {
        return Some(path);
    }
    std::env::var_os("PATH").and_then(|value| {
        std::env::split_paths(&value)
            .map(|directory| directory.join(basename))
            .find(|path| is_executable(path))
    })
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}
