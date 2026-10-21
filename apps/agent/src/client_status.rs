//! `mci-agent clients --json`: the AI tools Hippocampus connects and what
//! each has of it, for the window's AI Tools page (SPEC 3.8): whether its
//! look-up entry is there, whether its sessions start with the person's
//! recent work and how, and the step it needs, if any. Content-free: it says
//! nothing of the memory and never opens it, so it needs no key.
//!
//! `--disconnect <claude-code|codex|all>` takes Hippocampus's look-up entry
//! out of each tool's settings (SPEC 5.5), under the registry's safety
//! rules: an entry that isn't Hippocampus's is never touched. The session
//! hooks and Codex's instruction are removed by the app, which wrote them,
//! so each settings file returns to how it was.
//!
//! Every path is read from the environment the tools themselves honor:
//! `HOME`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::Serialize;

use crate::client_hooks::{
    self, CodexHooksFeature, HookPresence, CLAUDE_MARKER, CODEX_MARKER, LEGACY_CLAUDE_MARKER,
};
use crate::client_registry::{ClientRegistry, RegistrationRepair};
use crate::understanding::ReadError;

/// The first line of Codex's instruction block, in any version.
pub const CODEX_BLOCK_MARK: &str = "<!-- hippocampus-session-context:v";
/// The file the app's Codex hook touches each time it runs, beside the
/// memory: content-free, its time says the hook has run.
pub const CODEX_HOOK_RAN_FILE: &str = "codex-session-start";

/// The tools, in the order AI Tools lists them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Clients {
    /// One entry per tool.
    pub tools: Vec<ClientTool>,
}

/// One AI tool and what it has of Hippocampus.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClientTool {
    /// Its stable id: `claude-code` or `codex`.
    pub id: String,
    /// Its name, as the tool writes it.
    pub name: String,
    /// Whether it is on this Mac: its command or its settings were found.
    pub installed: bool,
    /// "Look things up in my memory": `on`, `off`, or `unavailable` when its
    /// settings can't be read safely or the name is someone else's.
    pub look_ups: String,
    /// "Start each session with my recent work": `on`, `off`,
    /// `turned_off_in_tool` (its own settings turn hooks off),
    /// `overridden` (Codex's `AGENTS.override.md` takes over) or
    /// `unavailable`.
    pub session_start: String,
    /// How a session starts with it, when it does: `hook` (each session
    /// start) or `instruction` (Codex is asked to fetch it; Codex decides).
    pub start_kind: Option<String>,
    /// The step the person still has to take in the tool: `allow_hooks`
    /// while Codex hasn't run Hippocampus's new hook yet.
    pub needs_step: Option<String>,
}

/// Where each tool keeps the files read here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientPaths {
    /// The person's home folder.
    pub home: PathBuf,
    /// `CLAUDE_CONFIG_DIR`, when set.
    pub claude_config_dir: Option<PathBuf>,
    /// `CODEX_HOME`, when set.
    pub codex_home: Option<PathBuf>,
    /// The folder the memory is in, where the Codex hook leaves its mark.
    pub memory_dir: PathBuf,
}

impl ClientPaths {
    /// The paths this process's environment names.
    #[must_use]
    pub fn from_environment() -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
        let directory = |name: &str| {
            std::env::var_os(name)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
        };
        let memory = std::env::var_os("MCI_DB_PATH")
            .filter(|value| !value.is_empty())
            .map_or_else(
                || home.join("Library/Application Support/MCI/mci.sqlite"),
                PathBuf::from,
            );
        Self {
            claude_config_dir: directory("CLAUDE_CONFIG_DIR"),
            codex_home: directory("CODEX_HOME"),
            memory_dir: memory
                .parent()
                .map_or_else(|| home.clone(), Path::to_path_buf),
            home,
        }
    }

    fn codex_dir(&self) -> PathBuf {
        self.codex_home
            .clone()
            .unwrap_or_else(|| self.home.join(".codex"))
    }

    fn hooks(&self) -> client_hooks::HookPaths {
        client_hooks::HookPaths::for_dirs(
            &self.home,
            self.claude_config_dir.as_deref(),
            self.codex_home.as_deref(),
        )
    }
}

/// What each tool has of Hippocampus now.
#[must_use]
pub fn clients(paths: &ClientPaths, registry: Option<&ClientRegistry>) -> Clients {
    let hooks = paths.hooks();
    let look_ups = |result: Option<Result<bool, crate::client_registry::RegistrationError>>| {
        match result {
            Some(Ok(true)) => "on",
            Some(Ok(false)) => "off",
            Some(Err(_)) | None => "unavailable",
        }
        .to_owned()
    };

    // Claude Code: its settings' SessionStart hook.
    let claude_hook = has_handler(
        &hooks.claude_settings,
        &[CLAUDE_MARKER, LEGACY_CLAUDE_MARKER],
    );
    let claude_off = client_hooks::claude_hooks_disabled(&hooks.claude_settings).unwrap_or(false);
    let (claude_start, claude_kind) = match (claude_hook, claude_off) {
        (Ok(true), false) => ("on", Some("hook")),
        (Ok(true), true) => ("turned_off_in_tool", None),
        (Ok(false), _) => ("off", None),
        (Err(()), _) => ("unavailable", None),
    };
    let claude = ClientTool {
        id: "claude-code".into(),
        name: "Claude Code".into(),
        installed: registry.is_some_and(ClientRegistry::claude_detected)
            || paths
                .claude_config_dir
                .clone()
                .unwrap_or_else(|| paths.home.join(".claude"))
                .is_dir(),
        look_ups: look_ups(registry.map(ClientRegistry::claude_registered)),
        session_start: claude_start.into(),
        start_kind: claude_kind.map(str::to_owned),
        needs_step: None,
    };

    // Codex: its SessionStart hook, else the instruction in AGENTS.md.
    let codex_dir = paths.codex_dir();
    let codex_hook = has_handler(&hooks.codex_hooks, &[CODEX_MARKER]).unwrap_or(false);
    let hooks_off = matches!(
        client_hooks::codex_hooks_feature(&hooks.codex_config),
        Ok(CodexHooksFeature::Disabled)
    );
    let instruction = read_small(&codex_dir.join("AGENTS.md"))
        .is_some_and(|text| text.contains(CODEX_BLOCK_MARK));
    let overridden = read_small(&codex_dir.join("AGENTS.override.md"))
        .is_some_and(|text| !text.trim().is_empty());
    let (codex_start, codex_kind, needs_step) = if codex_hook && !hooks_off {
        let ran = hook_ran_since_installed(
            &paths.memory_dir.join(CODEX_HOOK_RAN_FILE),
            &hooks.codex_hooks,
        );
        ("on", Some("hook"), (!ran).then_some("allow_hooks"))
    } else if instruction && !overridden {
        ("on", Some("instruction"), None)
    } else if instruction {
        ("overridden", None, None)
    } else if codex_hook {
        ("turned_off_in_tool", None, None)
    } else {
        ("off", None, None)
    };
    let codex = ClientTool {
        id: "codex".into(),
        name: "Codex".into(),
        installed: registry.is_some_and(ClientRegistry::codex_detected) || codex_dir.is_dir(),
        look_ups: look_ups(registry.map(ClientRegistry::codex_registered)),
        session_start: codex_start.into(),
        start_kind: codex_kind.map(str::to_owned),
        needs_step: needs_step.map(str::to_owned),
    };
    Clients {
        tools: vec![claude, codex],
    }
}

/// Whether `path` holds a `SessionStart` handler carrying one of `markers`.
/// `Err` when the file exists but can't be read safely.
fn has_handler(path: &Path, markers: &[&str]) -> Result<bool, ()> {
    match client_hooks::detect_handoff_hook(path) {
        HookPresence::FileMissing | HookPresence::NotInstalled => Ok(false),
        HookPresence::Unreadable => Err(()),
        HookPresence::Installed => {
            let text = read_small(path).ok_or(())?;
            Ok(markers.iter().any(|marker| text.contains(marker)))
        }
    }
}

/// Whether the Codex hook has run since its file last changed: Codex skips
/// a new or changed hook until the person allows it with `/hooks`.
fn hook_ran_since_installed(mark: &Path, hooks: &Path) -> bool {
    let modified = |path: &Path| -> Option<SystemTime> {
        std::fs::symlink_metadata(path)
            .ok()
            .filter(std::fs::Metadata::is_file)
            .and_then(|meta| meta.modified().ok())
    };
    match (modified(mark), modified(hooks)) {
        (Some(ran), Some(installed)) => ran >= installed,
        _ => false,
    }
}

/// A small settings file as text: never through a link, never over 1 MiB.
fn read_small(path: &Path) -> Option<String> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > 1_048_576 {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

/// What `--disconnect` did to one tool's look-up entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Disconnected {
    /// The tool's id.
    pub id: String,
    /// `removed`, `none` (there was none) or `failed`.
    pub look_ups: String,
}

/// Take Hippocampus's look-up entry out of `ids`' settings.
#[must_use]
pub fn disconnect(registry: &ClientRegistry, ids: &[&str]) -> Vec<Disconnected> {
    ids.iter()
        .map(|id| {
            let result = match *id {
                "claude-code" => registry.unregister_claude(),
                _ => registry.unregister_codex(),
            };
            Disconnected {
                id: (*id).to_owned(),
                look_ups: match result {
                    Ok(RegistrationRepair::Updated) => "removed",
                    Ok(
                        RegistrationRepair::AlreadyCurrent
                        | RegistrationRepair::NotRegistered
                        | RegistrationRepair::SkippedNotInstalled,
                    ) => "none",
                    Err(_) => "failed",
                }
                .to_owned(),
            }
        })
        .collect()
}

/// `mci-agent clients`: the tools as JSON. With `--disconnect <id|all>`,
/// their look-up entries are taken out first and the answer says what
/// happened to each, then what each has now.
///
/// # Errors
/// [`ReadError::Usage`] for a tool it doesn't know; [`ReadError::Failed`]
/// only if the answer can't be written.
pub fn run_cli(args: &[String]) -> Result<serde_json::Value, ReadError> {
    // What was asked is checked before anything on this Mac is looked at.
    let disconnecting: Option<Vec<&str>> = match args.iter().position(|arg| arg == "--disconnect") {
        None => None,
        Some(at) => Some(match args.get(at + 1).map(String::as_str) {
            Some("all") => vec!["claude-code", "codex"],
            Some(id @ ("claude-code" | "codex")) => vec![id],
            _ => {
                return Err(ReadError::Usage(
                    "--disconnect takes claude-code, codex or all".into(),
                ))
            }
        }),
    };
    let paths = ClientPaths::from_environment();
    let registry = ClientRegistry::discover()
        .ok()
        .map(|registry| registry.with_claude_config_dir(paths.claude_config_dir.clone()));
    let mut answer = serde_json::Map::new();
    if let Some(ids) = disconnecting {
        let Some(registry) = registry.as_ref() else {
            return Err(ReadError::Failed(
                "clients could not find this Mac's AI tools".into(),
            ));
        };
        let done = disconnect(registry, &ids);
        answer.insert(
            "disconnected".into(),
            serde_json::to_value(done)
                .map_err(|_| ReadError::Failed("clients could not be written".into()))?,
        );
    }
    let tools = serde_json::to_value(clients(&paths, registry.as_ref()))
        .map_err(|_| ReadError::Failed("clients could not be written".into()))?;
    if let serde_json::Value::Object(tools) = tools {
        answer.extend(tools);
    }
    Ok(serde_json::Value::Object(answer))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(home: &Path) -> ClientPaths {
        ClientPaths {
            home: home.to_path_buf(),
            claude_config_dir: None,
            codex_home: None,
            memory_dir: home.join("MCI"),
        }
    }

    fn tool<'a>(clients: &'a Clients, id: &str) -> &'a ClientTool {
        clients.tools.iter().find(|tool| tool.id == id).unwrap()
    }

    #[test]
    fn nothing_connected_reads_as_off() {
        let home = tempfile::tempdir().unwrap();
        let answer = clients(&paths(home.path()), None);
        let ids: Vec<&str> = answer.tools.iter().map(|tool| tool.id.as_str()).collect();
        assert_eq!(ids, ["claude-code", "codex"]);
        for tool in &answer.tools {
            assert!(!tool.installed);
            assert_eq!(tool.session_start, "off");
            assert_eq!(tool.look_ups, "unavailable", "no registry, no answer");
        }
    }

    #[test]
    fn claude_codes_hook_and_its_off_switch_are_read() {
        let home = tempfile::tempdir().unwrap();
        let settings = home.path().join(".claude/settings.json");
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let command = client_hooks::HookCommand::new("/A/mci-agent".into(), "/db".into());
        client_hooks::install_claude_hook(&settings, &command).unwrap();
        let answer = clients(&paths(home.path()), None);
        let claude = tool(&answer, "claude-code");
        assert!(claude.installed);
        assert_eq!(claude.session_start, "on");
        assert_eq!(claude.start_kind.as_deref(), Some("hook"));
        let mut value: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&settings).unwrap()).unwrap();
        value["disableAllHooks"] = serde_json::Value::Bool(true);
        std::fs::write(&settings, value.to_string()).unwrap();
        let answer = clients(&paths(home.path()), None);
        assert_eq!(
            tool(&answer, "claude-code").session_start,
            "turned_off_in_tool"
        );
    }

    #[test]
    fn claude_config_dir_moves_where_settings_are_read() {
        let home = tempfile::tempdir().unwrap();
        let moved = home.path().join("elsewhere");
        std::fs::create_dir_all(&moved).unwrap();
        let command = client_hooks::HookCommand::new("/A/mci-agent".into(), "/db".into());
        client_hooks::install_claude_hook(&moved.join("settings.json"), &command).unwrap();
        let mut paths = paths(home.path());
        assert_eq!(
            tool(&clients(&paths, None), "claude-code").session_start,
            "off"
        );
        paths.claude_config_dir = Some(moved);
        assert_eq!(
            tool(&clients(&paths, None), "claude-code").session_start,
            "on"
        );
    }

    #[test]
    fn codex_needs_a_step_until_its_hook_runs() {
        let home = tempfile::tempdir().unwrap();
        let codex = home.path().join(".codex");
        std::fs::create_dir_all(&codex).unwrap();
        std::fs::write(
            codex.join("AGENTS.md"),
            "# Mine\n\n<!-- hippocampus-session-context:v2 -->\nblock\n<!-- /hippocampus-session-context:v2 -->\n",
        )
        .unwrap();
        let answer = clients(&paths(home.path()), None);
        let codex_tool = tool(&answer, "codex");
        assert_eq!(codex_tool.session_start, "on");
        assert_eq!(codex_tool.start_kind.as_deref(), Some("instruction"));
        assert_eq!(codex_tool.needs_step, None);

        let command = client_hooks::HookCommand::new("/A/mci-agent".into(), "/db".into());
        client_hooks::install_codex_hook(&codex.join("hooks.json"), &command).unwrap();
        let answer = clients(&paths(home.path()), None);
        let codex_tool = tool(&answer, "codex");
        assert_eq!(codex_tool.start_kind.as_deref(), Some("hook"));
        assert_eq!(codex_tool.needs_step.as_deref(), Some("allow_hooks"));

        // The hook ran: its mark is newer than the hooks file.
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::create_dir_all(home.path().join("MCI")).unwrap();
        std::fs::write(home.path().join("MCI").join(CODEX_HOOK_RAN_FILE), "").unwrap();
        let answer = clients(&paths(home.path()), None);
        assert_eq!(tool(&answer, "codex").needs_step, None);

        // Hooks turned off in Codex: the instruction still asks.
        std::fs::write(codex.join("config.toml"), "[features]\nhooks = false\n").unwrap();
        let answer = clients(&paths(home.path()), None);
        assert_eq!(
            tool(&answer, "codex").start_kind.as_deref(),
            Some("instruction")
        );

        // An override shadows the instruction.
        std::fs::write(codex.join("AGENTS.override.md"), "Mine only").unwrap();
        let answer = clients(&paths(home.path()), None);
        assert_eq!(tool(&answer, "codex").session_start, "overridden");
    }

    #[test]
    fn a_tool_it_doesnt_know_is_refused() {
        let error = run_cli(&["--disconnect".into(), "cursor".into()]).unwrap_err();
        assert!(matches!(error, ReadError::Usage(_)));
    }
}
