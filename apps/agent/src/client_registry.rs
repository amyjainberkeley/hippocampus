//! Safe, idempotent registration with local AI clients.
//!
//! Claude JSON and Codex TOML are patched structurally behind the same
//! ownership, locking, and atomic-write boundary. Generated entries carry a
//! database path and a stable Keychain reference, never database key material.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fmt;
use std::fs::{File, OpenOptions, Permissions};
use std::io::{ErrorKind, Write as _};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use rustix::fs::{flock, FlockOperation};
use toml_edit::{value, Array, DocumentMut, Item, Table};

use crate::key_resolver::mcp_registration_env;

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const SERVER_NAME: &str = "hippocampus";
const KEYCHAIN_SERVICE_ENV: &str = "MCI_DB_KEYCHAIN_SERVICE";
const KEYCHAIN_SERVICE: &str = "ai.hippocampus.brain";

/// Whether one registration changed client configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationChange {
    /// The desired entry was written.
    Updated,
    /// The complete existing entry already matched semantically.
    AlreadyCurrent,
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
    /// Another process changed the file during every bounded retry.
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

/// Paths and client detection used by the registry.
#[derive(Debug, Clone)]
pub struct ClientRegistry {
    home: PathBuf,
    agent_executable: PathBuf,
    codex_executable: Option<PathBuf>,
    codex_home: Option<PathBuf>,
    claude_detected: bool,
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
        }
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
        })
    }

    /// Atomically merge the Hippocampus server into `~/.claude.json`.
    pub fn register_claude(&self, db_path: &Path) -> Result<RegistrationChange, RegistrationError> {
        let desired = self.desired_entry(db_path)?;
        update_config(&self.home.join(".claude.json"), |bytes| {
            patch_claude_json(bytes, &desired)
        })
    }

    /// Patch Codex's user-wide TOML directly, preserving unrelated formatting.
    pub fn register_codex(&self, db_path: &Path) -> Result<RegistrationChange, RegistrationError> {
        let desired = self.desired_entry(db_path)?;
        update_config(&self.codex_config_path(), |bytes| {
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

    fn desired_entry(&self, db_path: &Path) -> Result<DesiredEntry, RegistrationError> {
        let command = validate_agent_path(&self.agent_executable)?;
        let db_path = validate_database_path(db_path)?;
        Ok(DesiredEntry {
            command,
            env: mcp_registration_env(&db_path),
        })
    }
}

#[derive(Debug, Clone)]
struct DesiredEntry {
    command: String,
    env: BTreeMap<String, String>,
}

enum PatchOutcome {
    Unchanged,
    Write(Vec<u8>),
}

fn patch_claude_json(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
) -> Result<PatchOutcome, RegistrationError> {
    let mut root = match bytes {
        Some(content) => serde_json::from_slice::<serde_json::Value>(content)
            .map_err(|error| {
                RegistrationError::new(
                    RegistrationErrorKind::BlockedMalformed,
                    format!(
                        "Claude config is not valid JSON at line {} column {}",
                        error.line(),
                        error.column()
                    ),
                )
            })?
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
        if !claude_entry_is_owned(existing) {
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
        == Some(KEYCHAIN_SERVICE);
    service_owned
        || command_and_args_are_owned(
            object.get("command").and_then(serde_json::Value::as_str),
            object
                .get("args")
                .and_then(serde_json::Value::as_array)
                .map(|args| args.iter().filter_map(serde_json::Value::as_str)),
        )
}

fn patch_codex_toml(
    bytes: Option<&[u8]>,
    desired: &DesiredEntry,
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

    if let Some(servers) = document.get("mcp_servers") {
        let servers = servers.as_table_like().ok_or_else(|| {
            RegistrationError::new(
                RegistrationErrorKind::BlockedMalformed,
                "Codex mcp_servers must be a table",
            )
        })?;
        if let Some(existing) = servers.get(SERVER_NAME) {
            if codex_entry_matches(existing, desired) {
                return Ok(PatchOutcome::Unchanged);
            }
            if !codex_entry_is_owned(existing) {
                return Err(RegistrationError::new(
                    RegistrationErrorKind::NameConflict,
                    "Codex already has an unrelated server named hippocampus",
                ));
            }
        }
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
        == Some(KEYCHAIN_SERVICE);
    let args = table
        .get("args")
        .and_then(Item::as_array)
        .map(|values| values.iter().filter_map(toml_edit::Value::as_str));
    service_owned || command_and_args_are_owned(table.get("command").and_then(Item::as_str), args)
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
    patcher: F,
) -> Result<RegistrationChange, RegistrationError>
where
    F: Fn(Option<&[u8]>) -> Result<PatchOutcome, RegistrationError>,
{
    let target = resolve_config_target(logical_path)?;
    ensure_private_parent(&target)?;
    let _lock = acquire_update_lock(&target)?;

    for _ in 0..3 {
        validate_existing_target(&target)?;
        let before = read_optional(&target)?;
        let outcome = patcher(before.as_deref())?;
        let PatchOutcome::Write(output) = outcome else {
            return Ok(RegistrationChange::AlreadyCurrent);
        };
        if read_optional(&target)? != before {
            continue;
        }
        let mode = std::fs::metadata(&target)
            .map_or(0o600, |metadata| metadata.permissions().mode() & 0o777);
        atomic_replace(&target, &output, mode)?;
        let committed = read_optional(&target)?;
        if committed.as_deref() != Some(output.as_slice()) {
            return Err(RegistrationError::new(
                RegistrationErrorKind::Failed,
                "client config verification failed after atomic replace",
            ));
        }
        if !matches!(patcher(committed.as_deref())?, PatchOutcome::Unchanged) {
            return Err(RegistrationError::new(
                RegistrationErrorKind::Failed,
                "client config semantic verification failed after atomic replace",
            ));
        }
        return Ok(RegistrationChange::Updated);
    }
    Err(RegistrationError::new(
        RegistrationErrorKind::ConcurrentChange,
        "client config changed concurrently during three update attempts",
    ))
}

fn resolve_config_target(path: &Path) -> Result<PathBuf, RegistrationError> {
    match path.symlink_metadata() {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            let link = std::fs::read_link(path)
                .map_err(|error| io_error("read client config link", &error))?;
            let target = if link.is_absolute() {
                link
            } else {
                path.parent().unwrap_or_else(|| Path::new(".")).join(link)
            };
            if !target.exists() {
                return Err(RegistrationError::new(
                    RegistrationErrorKind::UnsafePath,
                    "client config symlink target does not exist",
                ));
            }
            validate_existing_target(&target)?;
            Ok(target)
        }
        Ok(_) => {
            validate_existing_target(path)?;
            Ok(path.to_path_buf())
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(path.to_path_buf()),
        Err(error) => Err(io_error("inspect client config", &error)),
    }
}

fn validate_existing_target(path: &Path) -> Result<(), RegistrationError> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io_error("inspect client config target", &error)),
    };
    if !metadata.is_file() {
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

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, RegistrationError> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error("read client config", &error)),
    }
}

fn atomic_replace(path: &Path, bytes: &[u8], mode: u32) -> Result<(), RegistrationError> {
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
    let result = (|| {
        temp.write_all(bytes)
            .map_err(|error| io_error("write client config temp file", &error))?;
        temp.set_permissions(Permissions::from_mode(mode))
            .map_err(|error| io_error("preserve client config mode", &error))?;
        temp.sync_all()
            .map_err(|error| io_error("sync client config temp file", &error))?;
        std::fs::rename(&temp_path, path)
            .map_err(|error| io_error("replace client config", &error))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error("sync client config directory", &error))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp_path);
    }
    result
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
