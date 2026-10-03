//! SessionStart hook installation for Claude Code and Codex.
//!
//! Both clients run a command when a session starts and feed its stdout back
//! as extra context. Hippocampus points that command at
//! `mci-agent handoff --format <client>-hook`, so every session opens with a
//! short, cited packet saying where the user left off in this project.
//!
//! The two client files are edited structurally, never templated:
//!
//! - Claude Code: `~/.claude/settings.json`, `hooks.SessionStart[]`, one group
//!   with matcher `startup|resume|clear|compact`.
//! - Codex: `~/.codex/hooks.json`, `hooks.SessionStart[]`, one group with
//!   matcher `*` and an `additionalContextLimit`.
//!
//! A Hippocampus handler is recognised by a substring of its command
//! (`handoff --format claude-hook` or `handoff --format codex-hook`). The
//! Hippocampus.app Swift installer wrote an older Claude Code group marked
//! `--claude-session-context`; that group is treated as ours and replaced.
//! Every other handler, group, and top-level key is preserved. Files are
//! rewritten as pretty JSON with sorted keys, which is the same shape the
//! Swift installer produces, and replaced atomically through a temp file and
//! rename. Symlinked client files are refused rather than followed.
//!
//! Nothing here reads the environment: callers hand in paths so tests can
//! point the installer at a temporary home.

use std::fmt;
use std::io::{Read as _, Write as _};
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{json, Map, Value};

/// Substring that marks a Claude Code handler as ours.
pub const CLAUDE_MARKER: &str = "handoff --format claude-hook";
/// Substring that marks a Codex handler as ours.
pub const CODEX_MARKER: &str = "handoff --format codex-hook";
/// Marker of the Claude Code group written by the Hippocampus.app Swift
/// installer before the handoff command existed. Replaced, never duplicated.
pub const LEGACY_CLAUDE_MARKER: &str = "--claude-session-context";
/// Marker the doctor looks for in either client file.
pub const HANDOFF_MARKER: &str = "handoff --format";
/// Claude Code session sources that receive the packet.
pub const CLAUDE_MATCHER: &str = "startup|resume|clear|compact";
/// Codex matcher: every session source.
pub const CODEX_MATCHER: &str = "*";

const HOOK_TIMEOUT_SECONDS: u64 = 10;
const CODEX_ADDITIONAL_CONTEXT_LIMIT: u64 = 2500;
const MAX_FILE_BYTES: u64 = 1_048_576;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Where each client keeps the files this module edits or reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookPaths {
    /// `~/.claude/settings.json`.
    pub claude_settings: PathBuf,
    /// `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`).
    pub codex_hooks: PathBuf,
    /// `~/.codex/config.toml`, read only for the `[features] hooks` flag.
    pub codex_config: PathBuf,
}

impl HookPaths {
    /// Standard locations under `home`, with an optional Codex home override.
    #[must_use]
    pub fn for_home(home: &Path, codex_home: Option<&Path>) -> Self {
        let codex = codex_home.map_or_else(|| home.join(".codex"), Path::to_path_buf);
        Self {
            claude_settings: home.join(".claude").join("settings.json"),
            codex_hooks: codex.join("hooks.json"),
            codex_config: codex.join("config.toml"),
        }
    }
}

/// The command both hooks run, built from the agent binary and the brain path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookCommand {
    executable: PathBuf,
    db_path: PathBuf,
}

impl HookCommand {
    /// Build from explicit paths. Tests use this; the CLI uses [`Self::resolve`].
    #[must_use]
    pub const fn new(executable: PathBuf, db_path: PathBuf) -> Self {
        Self {
            executable,
            db_path,
        }
    }

    /// The running binary, canonicalized, and the brain path made absolute.
    ///
    /// # Errors
    /// When the executable path cannot be resolved.
    pub fn resolve(db_path: &Path) -> Result<Self, HookError> {
        let executable = std::env::current_exe()
            .and_then(|path| path.canonicalize())
            .map_err(|error| HookError::Io(PathBuf::from("current_exe"), error.to_string()))?;
        let db_path = std::path::absolute(db_path)
            .map_err(|error| HookError::Io(db_path.to_path_buf(), error.to_string()))?;
        Ok(Self {
            executable,
            db_path,
        })
    }

    /// The agent binary the hooks invoke.
    #[must_use]
    pub fn executable(&self) -> &Path {
        &self.executable
    }

    /// The brain the hooks read.
    #[must_use]
    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    fn command_for(&self, format: &str) -> String {
        format!(
            "{} handoff --format {format} --db-path {}",
            shell_quote(&self.executable),
            shell_quote(&self.db_path)
        )
    }

    /// Shell command line for the Claude Code hook.
    #[must_use]
    pub fn claude_command(&self) -> String {
        self.command_for("claude-hook")
    }

    /// Shell command line for the Codex hook.
    #[must_use]
    pub fn codex_command(&self) -> String {
        self.command_for("codex-hook")
    }

    /// The exact `hooks.SessionStart[]` group written into Claude Code settings.
    #[must_use]
    pub fn claude_group(&self) -> Value {
        json!({
            "matcher": CLAUDE_MATCHER,
            "hooks": [{
                "type": "command",
                "command": self.claude_command(),
                "timeout": HOOK_TIMEOUT_SECONDS,
            }],
        })
    }

    /// The exact `hooks.SessionStart[]` group written into Codex hooks.
    #[must_use]
    pub fn codex_group(&self) -> Value {
        json!({
            "matcher": CODEX_MATCHER,
            "hooks": [{
                "type": "command",
                "command": self.codex_command(),
                "timeout": HOOK_TIMEOUT_SECONDS,
                "additionalContextLimit": CODEX_ADDITIONAL_CONTEXT_LIMIT,
            }],
        })
    }
}

/// Single-quote a path for `/bin/sh`, the way the Swift installer does.
fn shell_quote(path: &Path) -> String {
    let raw = path.to_string_lossy();
    format!("'{}'", raw.replace('\'', "'\"'\"'"))
}

/// Why a client file could not be edited. Unrelated content is never
/// modified when one of these is returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookError {
    /// The path exists but is a symlink, not a regular file, or too large.
    UnsafePath(PathBuf),
    /// The file is not the JSON shape the client documents.
    Malformed(PathBuf, String),
    /// A filesystem operation failed.
    Io(PathBuf, String),
}

impl fmt::Display for HookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsafePath(path) => write!(
                f,
                "{} must be a regular file, not a link; nothing was changed",
                path.display()
            ),
            Self::Malformed(path, why) => write!(
                f,
                "{} could not be read safely ({why}); repair it before trying again",
                path.display()
            ),
            Self::Io(path, why) => write!(f, "{}: {why}", path.display()),
        }
    }
}

impl std::error::Error for HookError {}

/// What an install or removal did to a client file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookChange {
    /// Our group was added; no earlier Hippocampus handler existed.
    Installed,
    /// An earlier Hippocampus handler (ours or the Swift installer's) was
    /// replaced by the current group.
    Replaced,
    /// The file already held exactly our group. No write happened.
    AlreadyInstalled,
    /// Our handlers were removed.
    Removed,
    /// Nothing of ours was present. No write happened.
    NotInstalled,
}

impl HookChange {
    /// Whether the file was written.
    #[must_use]
    pub const fn wrote(self) -> bool {
        matches!(self, Self::Installed | Self::Replaced | Self::Removed)
    }
}

/// Whether a Hippocampus handoff hook is present. Never fails: the doctor
/// reports what it can see.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookPresence {
    /// A handler whose command carries the handoff marker exists.
    Installed,
    /// The file exists and parses but holds no Hippocampus handler.
    NotInstalled,
    /// The file does not exist.
    FileMissing,
    /// The file could not be read or parsed; a raw text search also found no marker.
    Unreadable,
}

/// The state of the Codex `[features] hooks` switch in `config.toml`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexHooksFeature {
    /// `hooks = true`, or the key is absent (Codex defaults to enabled).
    Enabled,
    /// `hooks = false` (or the deprecated `codex_hooks = false`). Reported,
    /// never flipped.
    Disabled,
    /// No `config.toml` at that path.
    NoConfig,
}

/// Install the Claude Code `SessionStart` group, replacing any earlier
/// Hippocampus handler, including the Swift installer's group.
///
/// # Errors
/// [`HookError`] when the file is unsafe, malformed, or cannot be written.
pub fn install_claude_hook(path: &Path, command: &HookCommand) -> Result<HookChange, HookError> {
    upsert_group(
        path,
        &[CLAUDE_MARKER, LEGACY_CLAUDE_MARKER],
        &command.claude_group(),
    )
}

/// Remove every Hippocampus handler from Claude Code settings, including the
/// Swift installer's group. Other hooks and keys are untouched.
///
/// # Errors
/// [`HookError`] when the file is unsafe, malformed, or cannot be written.
pub fn remove_claude_hook(path: &Path) -> Result<HookChange, HookError> {
    remove_handlers(path, &[CLAUDE_MARKER, LEGACY_CLAUDE_MARKER])
}

/// Whether Claude Code settings disable hooks globally
/// (`disableAllHooks` or `allowManagedHooksOnly`). Missing file means no.
///
/// # Errors
/// [`HookError`] when the file is unsafe or malformed.
pub fn claude_hooks_disabled(path: &Path) -> Result<bool, HookError> {
    let root = parse_root(path, read_file(path)?.as_deref())?;
    Ok(["disableAllHooks", "allowManagedHooksOnly"]
        .iter()
        .any(|key| root.get(*key).and_then(Value::as_bool) == Some(true)))
}

/// Install the Codex `SessionStart` group, creating `hooks.json` if absent and
/// merging into an existing `hooks.SessionStart` array otherwise.
///
/// # Errors
/// [`HookError`] when the file is unsafe, malformed, or cannot be written.
pub fn install_codex_hook(path: &Path, command: &HookCommand) -> Result<HookChange, HookError> {
    upsert_group(path, &[CODEX_MARKER], &command.codex_group())
}

/// Remove every Hippocampus handler from Codex hooks. Everything else stays.
///
/// # Errors
/// [`HookError`] when the file is unsafe, malformed, or cannot be written.
pub fn remove_codex_hook(path: &Path) -> Result<HookChange, HookError> {
    remove_handlers(path, &[CODEX_MARKER])
}

/// Read the Codex `[features] hooks` switch. This never writes.
///
/// # Errors
/// [`HookError`] when the file is unsafe or not valid TOML.
pub fn codex_hooks_feature(config_path: &Path) -> Result<CodexHooksFeature, HookError> {
    let Some(bytes) = read_file(config_path)? else {
        return Ok(CodexHooksFeature::NoConfig);
    };
    let text = String::from_utf8(bytes)
        .map_err(|_| HookError::Malformed(config_path.to_path_buf(), "not UTF-8".into()))?;
    let document = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|error| HookError::Malformed(config_path.to_path_buf(), error.to_string()))?;
    let features = document
        .get("features")
        .and_then(toml_edit::Item::as_table_like);
    let flag = features.and_then(|table| {
        table
            .get("hooks")
            .or_else(|| table.get("codex_hooks"))
            .and_then(toml_edit::Item::as_bool)
    });
    Ok(match flag {
        Some(false) => CodexHooksFeature::Disabled,
        _ => CodexHooksFeature::Enabled,
    })
}

/// Doctor-facing detection: does the file carry a handoff hook?
///
/// Parses the JSON first; on any parse failure it falls back to a raw
/// substring search so a hand-edited file still reports honestly.
#[must_use]
pub fn detect_handoff_hook(path: &Path) -> HookPresence {
    let bytes = match read_file(path) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return HookPresence::FileMissing,
        Err(_) => return HookPresence::Unreadable,
    };
    let parsed = parse_root(path, Some(&bytes)).and_then(|root| session_starts(path, &root));
    match parsed {
        Ok(groups) => {
            if groups
                .iter()
                .any(|group| split_handlers(group, &[HANDOFF_MARKER]).is_some())
            {
                HookPresence::Installed
            } else {
                HookPresence::NotInstalled
            }
        }
        Err(_) => {
            if String::from_utf8_lossy(&bytes).contains(HANDOFF_MARKER) {
                HookPresence::Installed
            } else {
                HookPresence::Unreadable
            }
        }
    }
}

/// Insert `desired` into `hooks.SessionStart`, removing any handler whose
/// command carries one of `markers`. Idempotent: an identical existing group
/// is left alone and nothing is written.
fn upsert_group(path: &Path, markers: &[&str], desired: &Value) -> Result<HookChange, HookError> {
    let mut root = parse_root(path, read_file(path)?.as_deref())?;
    let groups = session_starts(path, &root)?;

    let mut kept: Vec<Value> = Vec::with_capacity(groups.len() + 1);
    let mut insert_at: Option<usize> = None;
    let mut removed_any = false;
    let mut exact_matches = 0usize;
    for group in &groups {
        match split_handlers(group, markers) {
            None => kept.push(group.clone()),
            Some((ours, others)) => {
                removed_any = true;
                if others.is_empty() && group == desired {
                    exact_matches += 1;
                }
                insert_at.get_or_insert(kept.len());
                if !others.is_empty() {
                    let mut trimmed = group.clone();
                    trimmed["hooks"] = Value::Array(others);
                    kept.push(trimmed);
                }
                debug_assert!(!ours.is_empty());
            }
        }
    }
    let marked_groups = groups
        .iter()
        .filter(|group| split_handlers(group, markers).is_some())
        .count();
    if marked_groups == 1 && exact_matches == 1 {
        return Ok(HookChange::AlreadyInstalled);
    }

    let at = insert_at.unwrap_or(kept.len()).min(kept.len());
    kept.insert(at, desired.clone());
    set_session_starts(&mut root, kept);
    write_root(path, &root)?;
    Ok(if removed_any {
        HookChange::Replaced
    } else {
        HookChange::Installed
    })
}

/// Drop every handler carrying one of `markers`. Groups left without
/// handlers are dropped; `SessionStart` and `hooks` are dropped when empty.
fn remove_handlers(path: &Path, markers: &[&str]) -> Result<HookChange, HookError> {
    let Some(bytes) = read_file(path)? else {
        return Ok(HookChange::NotInstalled);
    };
    let mut root = parse_root(path, Some(&bytes))?;
    let groups = session_starts(path, &root)?;
    let mut kept: Vec<Value> = Vec::with_capacity(groups.len());
    let mut removed_any = false;
    for group in &groups {
        match split_handlers(group, markers) {
            None => kept.push(group.clone()),
            Some((_, others)) => {
                removed_any = true;
                if !others.is_empty() {
                    let mut trimmed = group.clone();
                    trimmed["hooks"] = Value::Array(others);
                    kept.push(trimmed);
                }
            }
        }
    }
    if !removed_any {
        return Ok(HookChange::NotInstalled);
    }
    set_session_starts(&mut root, kept);
    write_root(path, &root)?;
    Ok(HookChange::Removed)
}

/// Partition a group's handlers into (ours, others). `None` when no handler
/// is ours, so unrelated groups are never touched.
fn split_handlers(group: &Value, markers: &[&str]) -> Option<(Vec<Value>, Vec<Value>)> {
    let handlers = group.get("hooks")?.as_array()?;
    let is_ours = |handler: &Value| {
        handler
            .get("command")
            .and_then(Value::as_str)
            .is_some_and(|command| markers.iter().any(|marker| command.contains(marker)))
    };
    if !handlers.iter().any(is_ours) {
        return None;
    }
    let (ours, others): (Vec<Value>, Vec<Value>) = handlers.iter().cloned().partition(is_ours);
    Some((ours, others))
}

fn parse_root(path: &Path, bytes: Option<&[u8]>) -> Result<Map<String, Value>, HookError> {
    let Some(bytes) = bytes else {
        return Ok(Map::new());
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(Map::new());
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(_) => Err(HookError::Malformed(
            path.to_path_buf(),
            "top level is not a JSON object".into(),
        )),
        Err(error) => Err(HookError::Malformed(path.to_path_buf(), error.to_string())),
    }
}

/// `hooks.SessionStart` as a list, validating only the two levels we edit.
fn session_starts(path: &Path, root: &Map<String, Value>) -> Result<Vec<Value>, HookError> {
    let Some(hooks) = root.get("hooks") else {
        return Ok(Vec::new());
    };
    let Some(hooks) = hooks.as_object() else {
        return Err(HookError::Malformed(
            path.to_path_buf(),
            "\"hooks\" is not an object".into(),
        ));
    };
    match hooks.get("SessionStart") {
        None => Ok(Vec::new()),
        Some(Value::Array(groups)) => Ok(groups.clone()),
        Some(_) => Err(HookError::Malformed(
            path.to_path_buf(),
            "\"hooks.SessionStart\" is not an array".into(),
        )),
    }
}

fn set_session_starts(root: &mut Map<String, Value>, groups: Vec<Value>) {
    let mut hooks = match root.remove("hooks") {
        Some(Value::Object(map)) => map,
        _ => Map::new(),
    };
    if groups.is_empty() {
        hooks.remove("SessionStart");
    } else {
        hooks.insert("SessionStart".into(), Value::Array(groups));
    }
    if !hooks.is_empty() {
        root.insert("hooks".into(), Value::Object(hooks));
    }
}

/// Read a client file without following links. `None` when absent.
fn read_file(path: &Path) -> Result<Option<Vec<u8>>, HookError> {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(HookError::Io(path.to_path_buf(), error.to_string())),
        Ok(meta) => {
            if meta.file_type().is_symlink() || !meta.is_file() || meta.len() > MAX_FILE_BYTES {
                return Err(HookError::UnsafePath(path.to_path_buf()));
            }
        }
    }
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(nofollow_flag())
        .open(path)
        .map_err(|error| HookError::Io(path.to_path_buf(), error.to_string()))?;
    let opened = file
        .metadata()
        .map_err(|error| HookError::Io(path.to_path_buf(), error.to_string()))?;
    if !opened.is_file() || opened.len() > MAX_FILE_BYTES {
        return Err(HookError::UnsafePath(path.to_path_buf()));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| HookError::Io(path.to_path_buf(), error.to_string()))?;
    Ok(Some(bytes))
}

fn nofollow_flag() -> i32 {
    i32::try_from(rustix::fs::OFlags::NOFOLLOW.bits()).unwrap_or(0)
}

/// Pretty JSON, sorted keys, trailing newline: the shape both clients and
/// the Swift installer already produce.
fn render(root: &Map<String, Value>) -> Vec<u8> {
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(root.clone())).unwrap_or_default();
    bytes.push(b'\n');
    bytes
}

fn write_root(path: &Path, root: &Map<String, Value>) -> Result<(), HookError> {
    write_atomic(path, &render(root))
}

/// Replace `path` through a same-directory temp file and rename, keeping
/// the existing mode (masked to owner-only) or 0600 for a new file.
///
/// # Errors
/// [`HookError`] when the parent is not a plain directory or any step fails.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), HookError> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| HookError::UnsafePath(path.to_path_buf()))?;
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err(HookError::UnsafePath(path.to_path_buf()));
        }
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
        .map_err(|error| HookError::Io(parent.to_path_buf(), error.to_string()))?;
    if !parent.is_dir() {
        return Err(HookError::UnsafePath(parent.to_path_buf()));
    }
    let mode = std::fs::metadata(path).map_or(0o600, |meta| meta.permissions().mode() & 0o600);
    let temp = parent.join(format!(
        ".hippocampus-hooks-{}-{}.tmp",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|error| HookError::Io(temp.clone(), error.to_string()))?;
        file.write_all(bytes)
            .and_then(|()| file.sync_all())
            .and_then(|()| file.set_permissions(std::fs::Permissions::from_mode(mode)))
            .map_err(|error| HookError::Io(temp.clone(), error.to_string()))?;
        std::fs::rename(&temp, path)
            .map_err(|error| HookError::Io(path.to_path_buf(), error.to_string()))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn command() -> HookCommand {
        HookCommand::new(
            PathBuf::from("/Applications/Hippocampus.app/Contents/MacOS/mci-agent"),
            PathBuf::from("/Users/amy/Library/Application Support/MCI/mci.sqlite"),
        )
    }

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).unwrap()
    }

    fn json(path: &Path) -> Value {
        serde_json::from_str(&read(path)).unwrap()
    }

    const GOLDEN_CLAUDE: &str = r#"{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "command": "'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format claude-hook --db-path '/Users/amy/Library/Application Support/MCI/mci.sqlite'",
            "timeout": 10,
            "type": "command"
          }
        ],
        "matcher": "startup|resume|clear|compact"
      }
    ]
  }
}
"#;

    const GOLDEN_CODEX: &str = r#"{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "additionalContextLimit": 2500,
            "command": "'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format codex-hook --db-path '/Users/amy/Library/Application Support/MCI/mci.sqlite'",
            "timeout": 10,
            "type": "command"
          }
        ],
        "matcher": "*"
      }
    ]
  }
}
"#;

    #[test]
    fn golden_json_for_both_clients_from_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);

        assert_eq!(
            install_claude_hook(&paths.claude_settings, &command()).unwrap(),
            HookChange::Installed
        );
        assert_eq!(
            install_codex_hook(&paths.codex_hooks, &command()).unwrap(),
            HookChange::Installed
        );

        assert_eq!(read(&paths.claude_settings), GOLDEN_CLAUDE);
        assert_eq!(read(&paths.codex_hooks), GOLDEN_CODEX);
        assert_eq!(
            std::fs::metadata(&paths.claude_settings)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn command_lines_follow_the_contract_quoting() {
        let cmd = command();
        assert_eq!(
            cmd.claude_command(),
            "'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format claude-hook --db-path '/Users/amy/Library/Application Support/MCI/mci.sqlite'"
        );
        let odd = HookCommand::new(PathBuf::from("/it's/mci-agent"), PathBuf::from("/db"));
        assert_eq!(
            odd.codex_command(),
            "'/it'\"'\"'s/mci-agent' handoff --format codex-hook --db-path '/db'"
        );
    }

    #[test]
    fn install_preserves_unrelated_hooks_and_keys() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        std::fs::create_dir_all(paths.claude_settings.parent().unwrap()).unwrap();
        // Written in the canonical shape (sorted keys, two-space indent) so
        // the only textual difference after install is our group.
        let original = r#"{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "command": "echo pre",
            "type": "command"
          }
        ],
        "matcher": "Bash"
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "command": "echo hello",
            "type": "command"
          }
        ],
        "matcher": "startup"
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(git status)"
    ]
  },
  "theme": "dark"
}
"#;
        std::fs::write(&paths.claude_settings, original).unwrap();

        assert_eq!(
            install_claude_hook(&paths.claude_settings, &command()).unwrap(),
            HookChange::Installed
        );

        let after = read(&paths.claude_settings);
        let ours = "      {\n        \"hooks\": [\n          {\n            \"command\": \"'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format claude-hook --db-path '/Users/amy/Library/Application Support/MCI/mci.sqlite'\",\n            \"timeout\": 10,\n            \"type\": \"command\"\n          }\n        ],\n        \"matcher\": \"startup|resume|clear|compact\"\n      }\n";
        // Our group is appended after the existing SessionStart group; the
        // rest of the file is byte-identical to the original.
        let expected = original.replacen(
            "        \"matcher\": \"startup\"\n      }\n",
            &format!("        \"matcher\": \"startup\"\n      }},\n{ours}"),
            1,
        );
        assert_eq!(after, expected);

        let value: Value = serde_json::from_str(&after).unwrap();
        assert_eq!(value["theme"], "dark");
        assert_eq!(value["permissions"]["allow"][0], "Bash(git status)");
        assert_eq!(value["hooks"]["PreToolUse"][0]["matcher"], "Bash");
        assert_eq!(value["hooks"]["SessionStart"].as_array().unwrap().len(), 2);
        assert_eq!(
            value["hooks"]["SessionStart"][0]["hooks"][0]["command"],
            "echo hello"
        );
    }

    #[test]
    fn install_replaces_the_swift_installer_group_in_place() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        std::fs::create_dir_all(paths.claude_settings.parent().unwrap()).unwrap();
        let swift = json!({
            "hooks": {"SessionStart": [
                {"matcher": "startup", "hooks": [{"type": "command", "command": "echo first"}]},
                {"matcher": "startup|resume|clear|compact", "hooks": [{
                    "type": "command",
                    "command": "'/Applications/Hippocampus.app/Contents/MacOS/Hippocampus' '--claude-session-context' '--db-path' '/Users/amy/Library/Application Support/MCI/mci.sqlite'",
                    "timeout": 10
                }]},
                {"matcher": "compact", "hooks": [{"type": "command", "command": "echo last"}]}
            ]},
            "model": "opus"
        });
        std::fs::write(
            &paths.claude_settings,
            serde_json::to_string_pretty(&swift).unwrap(),
        )
        .unwrap();

        assert_eq!(
            install_claude_hook(&paths.claude_settings, &command()).unwrap(),
            HookChange::Replaced
        );

        let value = json(&paths.claude_settings);
        let groups = value["hooks"]["SessionStart"].as_array().unwrap();
        assert_eq!(groups.len(), 3);
        assert_eq!(groups[0]["hooks"][0]["command"], "echo first");
        assert_eq!(groups[1], command().claude_group());
        assert_eq!(groups[2]["hooks"][0]["command"], "echo last");
        assert_eq!(value["model"], "opus");
        assert!(!read(&paths.claude_settings).contains(LEGACY_CLAUDE_MARKER));
    }

    #[test]
    fn install_is_idempotent_and_does_not_rewrite_an_identical_file() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        for (install, path) in [
            (
                install_claude_hook as fn(&Path, &HookCommand) -> Result<HookChange, HookError>,
                &paths.claude_settings,
            ),
            (install_codex_hook, &paths.codex_hooks),
        ] {
            assert_eq!(install(path, &command()).unwrap(), HookChange::Installed);
            let first = read(path);
            let modified = std::fs::metadata(path).unwrap().modified().unwrap();
            assert_eq!(
                install(path, &command()).unwrap(),
                HookChange::AlreadyInstalled
            );
            assert_eq!(read(path), first);
            assert_eq!(
                std::fs::metadata(path).unwrap().modified().unwrap(),
                modified
            );
        }
    }

    #[test]
    fn install_moves_to_a_new_db_path_by_replacing_the_old_entry() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        install_codex_hook(&paths.codex_hooks, &command()).unwrap();
        let moved = HookCommand::new(
            PathBuf::from("/new/mci-agent"),
            PathBuf::from("/new/brain.sqlite"),
        );
        assert_eq!(
            install_codex_hook(&paths.codex_hooks, &moved).unwrap(),
            HookChange::Replaced
        );
        let groups = json(&paths.codex_hooks)["hooks"]["SessionStart"].clone();
        assert_eq!(groups.as_array().unwrap().len(), 1);
        assert_eq!(groups[0], moved.codex_group());
    }

    #[test]
    fn codex_install_merges_into_existing_hooks_and_keeps_description() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        std::fs::create_dir_all(paths.codex_hooks.parent().unwrap()).unwrap();
        let existing = json!({
            "description": "Optional lifecycle hooks for this workspace.",
            "hooks": {
                "SessionStart": [{"matcher": "startup|resume", "hooks": [{
                    "type": "command",
                    "command": "python3 ~/.codex/hooks/session_start.py",
                    "statusMessage": "Loading session notes",
                    "additionalContextLimit": 5000
                }]}],
                "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo pre"}]}]
            }
        });
        std::fs::write(
            &paths.codex_hooks,
            serde_json::to_string_pretty(&existing).unwrap(),
        )
        .unwrap();

        assert_eq!(
            install_codex_hook(&paths.codex_hooks, &command()).unwrap(),
            HookChange::Installed
        );

        let value = json(&paths.codex_hooks);
        assert_eq!(
            value["description"],
            "Optional lifecycle hooks for this workspace."
        );
        assert_eq!(
            value["hooks"]["PreToolUse"],
            existing["hooks"]["PreToolUse"]
        );
        let groups = value["hooks"]["SessionStart"].as_array().unwrap();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0], existing["hooks"]["SessionStart"][0]);
        assert_eq!(groups[1], command().codex_group());
    }

    #[test]
    fn remove_takes_only_ours_and_prunes_empty_containers() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        std::fs::create_dir_all(paths.claude_settings.parent().unwrap()).unwrap();
        // A shared group: one foreign handler next to ours. Only ours goes.
        let mixed = json!({
            "hooks": {"SessionStart": [{"matcher": "startup", "hooks": [
                {"type": "command", "command": "echo keep"},
                {"type": "command", "command": command().claude_command(), "timeout": 10}
            ]}]},
            "theme": "dark"
        });
        std::fs::write(&paths.claude_settings, mixed.to_string()).unwrap();
        assert_eq!(
            remove_claude_hook(&paths.claude_settings).unwrap(),
            HookChange::Removed
        );
        let value = json(&paths.claude_settings);
        assert_eq!(
            value["hooks"]["SessionStart"][0]["hooks"],
            json!([{"type": "command", "command": "echo keep"}])
        );
        assert_eq!(value["theme"], "dark");
        assert_eq!(
            remove_claude_hook(&paths.claude_settings).unwrap(),
            HookChange::NotInstalled
        );

        // Only ours present: SessionStart and hooks disappear entirely.
        install_codex_hook(&paths.codex_hooks, &command()).unwrap();
        assert_eq!(
            remove_codex_hook(&paths.codex_hooks).unwrap(),
            HookChange::Removed
        );
        assert_eq!(read(&paths.codex_hooks), "{}\n");
        assert_eq!(
            remove_codex_hook(&temp.path().join("absent.json")).unwrap(),
            HookChange::NotInstalled
        );
    }

    #[test]
    fn remove_claude_also_clears_the_swift_installer_group() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        std::fs::create_dir_all(paths.claude_settings.parent().unwrap()).unwrap();
        let swift = json!({"hooks": {"SessionStart": [{"matcher": "startup|resume|clear|compact", "hooks": [{
            "type": "command",
            "command": "'/Applications/Hippocampus.app/Contents/MacOS/Hippocampus' '--claude-session-context' '--db-path' '/x'",
            "timeout": 10
        }]}]}});
        std::fs::write(&paths.claude_settings, swift.to_string()).unwrap();
        assert_eq!(
            remove_claude_hook(&paths.claude_settings).unwrap(),
            HookChange::Removed
        );
        assert_eq!(read(&paths.claude_settings), "{}\n");
    }

    #[test]
    fn symlinked_client_files_are_refused() {
        let temp = tempfile::tempdir().unwrap();
        let real = temp.path().join("real.json");
        std::fs::write(&real, "{}").unwrap();
        let link = temp.path().join("settings.json");
        symlink(&real, &link).unwrap();
        assert_eq!(
            install_claude_hook(&link, &command()).unwrap_err(),
            HookError::UnsafePath(link.clone())
        );
        assert_eq!(
            remove_claude_hook(&link).unwrap_err(),
            HookError::UnsafePath(link.clone())
        );
        assert_eq!(detect_handoff_hook(&link), HookPresence::Unreadable);
        assert_eq!(read(&real), "{}");
    }

    #[test]
    fn malformed_files_are_left_alone() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        for bad in [
            "not json",
            "[]",
            r#"{"hooks": []}"#,
            r#"{"hooks": {"SessionStart": {}}}"#,
        ] {
            std::fs::write(&path, bad).unwrap();
            assert!(matches!(
                install_claude_hook(&path, &command()),
                Err(HookError::Malformed(..))
            ));
            assert_eq!(read(&path), bad);
        }
    }

    #[test]
    fn empty_or_whitespace_files_count_as_empty_objects() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("hooks.json");
        std::fs::write(&path, "  \n").unwrap();
        assert_eq!(
            install_codex_hook(&path, &command()).unwrap(),
            HookChange::Installed
        );
        assert_eq!(read(&path), GOLDEN_CODEX);
    }

    #[test]
    fn detection_sees_our_hook_and_survives_hand_edits() {
        let temp = tempfile::tempdir().unwrap();
        let paths = HookPaths::for_home(temp.path(), None);
        assert_eq!(
            detect_handoff_hook(&paths.claude_settings),
            HookPresence::FileMissing
        );
        std::fs::create_dir_all(paths.claude_settings.parent().unwrap()).unwrap();
        std::fs::write(&paths.claude_settings, "{}").unwrap();
        assert_eq!(
            detect_handoff_hook(&paths.claude_settings),
            HookPresence::NotInstalled
        );
        install_claude_hook(&paths.claude_settings, &command()).unwrap();
        assert_eq!(
            detect_handoff_hook(&paths.claude_settings),
            HookPresence::Installed
        );
        // Trailing garbage breaks the parse; the raw search still finds us.
        let mut text = read(&paths.claude_settings);
        text.push_str("trailing");
        std::fs::write(&paths.claude_settings, text).unwrap();
        assert_eq!(
            detect_handoff_hook(&paths.claude_settings),
            HookPresence::Installed
        );
    }

    #[test]
    fn claude_disable_switches_are_reported() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        assert!(!claude_hooks_disabled(&path).unwrap());
        std::fs::write(&path, r#"{"disableAllHooks": true}"#).unwrap();
        assert!(claude_hooks_disabled(&path).unwrap());
        std::fs::write(&path, r#"{"allowManagedHooksOnly": true}"#).unwrap();
        assert!(claude_hooks_disabled(&path).unwrap());
        std::fs::write(&path, r#"{"disableAllHooks": false}"#).unwrap();
        assert!(!claude_hooks_disabled(&path).unwrap());
    }

    #[test]
    fn codex_feature_flag_is_read_and_never_written() {
        let temp = tempfile::tempdir().unwrap();
        let config = temp.path().join("config.toml");
        assert_eq!(
            codex_hooks_feature(&config).unwrap(),
            CodexHooksFeature::NoConfig
        );
        let disabled = "# keep me\nmodel = \"gpt-5\"\n\n[features]\nhooks = false\n";
        std::fs::write(&config, disabled).unwrap();
        assert_eq!(
            codex_hooks_feature(&config).unwrap(),
            CodexHooksFeature::Disabled
        );
        assert_eq!(read(&config), disabled);
        std::fs::write(&config, "[features]\nhooks = true\n").unwrap();
        assert_eq!(
            codex_hooks_feature(&config).unwrap(),
            CodexHooksFeature::Enabled
        );
        std::fs::write(&config, "model = \"gpt-5\"\n").unwrap();
        assert_eq!(
            codex_hooks_feature(&config).unwrap(),
            CodexHooksFeature::Enabled
        );
        std::fs::write(&config, "[features]\ncodex_hooks = false\n").unwrap();
        assert_eq!(
            codex_hooks_feature(&config).unwrap(),
            CodexHooksFeature::Disabled
        );
        std::fs::write(&config, "not = = toml").unwrap();
        assert!(matches!(
            codex_hooks_feature(&config),
            Err(HookError::Malformed(..))
        ));
    }

    #[test]
    fn atomic_write_masks_the_mode_to_owner_only_and_leaves_no_temp_files() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        std::fs::write(&path, "{}").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        install_claude_hook(&path, &command()).unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let leftovers: Vec<_> = std::fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
    }
}
