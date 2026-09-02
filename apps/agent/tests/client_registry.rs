use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::{symlink, MetadataExt};
use std::path::Path;
use std::process::Command;

use mci_agent::client_registry::{
    ClientRegistration, ClientRegistry, RegistrationChange, RegistrationStatus,
};

fn registry(home: &Path, agent: &Path, codex: Option<&Path>) -> ClientRegistry {
    ClientRegistry::new(
        home.to_path_buf(),
        agent.to_path_buf(),
        codex.map(Path::to_path_buf),
        None,
    )
}

fn executable(path: &Path) {
    std::fs::write(path, b"#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn agent_bin() -> std::path::PathBuf {
    let mut path = std::env::current_exe().expect("current executable");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

#[test]
fn claude_registration_is_idempotent_private_and_preserves_unrelated_config() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    std::fs::write(
        &config,
        r#"{"theme":"dark","mcpServers":{"other":{"command":"keep-me"}}}"#,
    )
    .unwrap();
    std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o600)).unwrap();
    let brain = home.join("brain.sqlite");
    let registry = registry(home, &agent, None);

    assert_eq!(
        registry.register_claude(&brain).unwrap(),
        RegistrationChange::Updated
    );
    let first = std::fs::read(&config).unwrap();
    assert_eq!(
        registry.register_claude(&brain).unwrap(),
        RegistrationChange::AlreadyCurrent
    );
    assert_eq!(std::fs::read(&config).unwrap(), first);

    let parsed: serde_json::Value = serde_json::from_slice(&first).unwrap();
    assert_eq!(parsed["theme"], "dark");
    assert_eq!(parsed["mcpServers"]["other"]["command"], "keep-me");
    assert_eq!(
        parsed["mcpServers"]["hippocampus"]["command"],
        agent.to_str().unwrap()
    );
    let serialized = String::from_utf8(first).unwrap();
    assert!(!serialized.contains("MCI_DB_KEY_HEX"));
    assert_eq!(
        std::fs::metadata(&config).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[test]
fn malformed_claude_config_is_left_byte_identical() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    let malformed = b"{not-json";
    std::fs::write(&config, malformed).unwrap();

    assert!(registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .is_err());
    assert_eq!(std::fs::read(config).unwrap(), malformed);
}

#[test]
fn stale_atomic_temp_file_does_not_block_claude_registration() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let stale = home.join(format!("..claude.json.tmp-{}", std::process::id()));
    std::fs::write(&stale, b"interrupted older registration").unwrap();

    assert_eq!(
        registry(home, &agent, None)
            .register_claude(&home.join("brain.sqlite"))
            .unwrap(),
        RegistrationChange::Updated
    );
    assert_eq!(
        std::fs::read(&stale).unwrap(),
        b"interrupted older registration"
    );
    let parsed: serde_json::Value =
        serde_json::from_slice(&std::fs::read(home.join(".claude.json")).unwrap()).unwrap();
    assert_eq!(
        parsed["mcpServers"]["hippocampus"]["command"],
        agent.to_str().unwrap()
    );
}

#[test]
fn codex_registration_writes_canonical_reference_only_toml() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let fake_codex = home.join("codex");
    executable(&fake_codex);
    let brain = home.join("brain.sqlite");

    let change = registry(home, &agent, Some(&fake_codex))
        .register_codex(&brain)
        .unwrap();
    assert_eq!(change, RegistrationChange::Updated);
    let config = std::fs::read_to_string(home.join(".codex/config.toml")).unwrap();
    let parsed = config.parse::<toml_edit::DocumentMut>().unwrap();
    let server = parsed["mcp_servers"]["hippocampus"]
        .as_table_like()
        .unwrap();
    assert_eq!(
        server.get("command").and_then(toml_edit::Item::as_str),
        agent.to_str()
    );
    let env = server
        .get("env")
        .and_then(toml_edit::Item::as_table_like)
        .unwrap();
    assert_eq!(
        env.get("MCI_DB_KEYCHAIN_SERVICE")
            .and_then(toml_edit::Item::as_str),
        Some("ai.hippocampus.brain")
    );
    assert!(env
        .get("MCI_DB_PATH")
        .and_then(toml_edit::Item::as_str)
        .is_some());
    assert!(!config.contains("MCI_DB_KEY_HEX"));
}

#[test]
fn connect_all_reports_each_client_without_turning_absence_into_success() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let report = registry(home, &agent, None).connect_all(&home.join("brain.sqlite"));

    assert_eq!(
        report.claude,
        ClientRegistration {
            status: RegistrationStatus::Registered,
            detail: None,
        }
    );
    assert_eq!(
        report.codex,
        ClientRegistration {
            status: RegistrationStatus::NotInstalled,
            detail: None,
        }
    );
}

#[test]
fn unrelated_claude_server_named_hippocampus_is_a_non_destructive_conflict() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    let original =
        br#"{"mcpServers":{"hippocampus":{"command":"unrelated-memory-tool","args":["serve"]}}}"#;
    std::fs::write(&config, original).unwrap();

    assert!(registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .is_err());
    assert_eq!(std::fs::read(config).unwrap(), original);
}

#[test]
fn managed_stale_claude_entry_is_replaced_completely() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    std::fs::write(
        &config,
        r#"{"mcpServers":{"hippocampus":{"command":"/missing/mci-agent","args":["old"],"env":{"MCI_DB_KEYCHAIN_SERVICE":"ai.hippocampus.brain","MCI_DB_KEY_HEX":"must-go"}}}}"#,
    )
    .unwrap();

    registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .unwrap();
    let updated = std::fs::read_to_string(config).unwrap();
    assert!(updated.contains(agent.to_str().unwrap()));
    assert!(!updated.contains("MCI_DB_KEY_HEX"));
    assert!(!updated.contains("\"old\""));
}

#[test]
fn claude_dotfile_symlink_target_is_updated_without_replacing_the_link() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let dotfiles = home.join("dotfiles");
    std::fs::create_dir(&dotfiles).unwrap();
    let target = dotfiles.join("claude.json");
    std::fs::write(&target, b"{}").unwrap();
    let config = home.join(".claude.json");
    symlink(Path::new("dotfiles/claude.json"), &config).unwrap();

    registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .unwrap();

    assert!(config.symlink_metadata().unwrap().file_type().is_symlink());
    let parsed: serde_json::Value =
        serde_json::from_slice(&std::fs::read(target).unwrap()).unwrap();
    assert_eq!(
        parsed["mcpServers"]["hippocampus"]["command"],
        agent.to_str().unwrap()
    );
}

#[test]
fn dangling_claude_dotfile_symlink_is_refused_without_creating_its_target() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    let missing = home.join("dotfiles/missing-claude.json");
    symlink(Path::new("dotfiles/missing-claude.json"), &config).unwrap();

    assert!(registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .is_err());
    assert!(config.symlink_metadata().unwrap().file_type().is_symlink());
    assert!(!missing.exists());
}

#[test]
fn hard_linked_claude_config_is_refused_unchanged() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    let mirror = home.join("claude-mirror.json");
    std::fs::write(&config, b"{}").unwrap();
    std::fs::hard_link(&config, &mirror).unwrap();
    assert_eq!(std::fs::metadata(&config).unwrap().nlink(), 2);

    assert!(registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .is_err());
    assert_eq!(std::fs::read(&config).unwrap(), b"{}");
    assert_eq!(std::fs::read(&mirror).unwrap(), b"{}");
}

#[test]
fn codex_toml_update_preserves_unrelated_comments_mode_and_noop_metadata() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let fake_codex = home.join("codex");
    std::fs::write(&fake_codex, b"#!/bin/sh\nexit 99\n").unwrap();
    std::fs::set_permissions(&fake_codex, std::fs::Permissions::from_mode(0o700)).unwrap();
    let codex_home = home.join(".codex-test");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = "# keep top comment\ntheme = \"light\"\n\n[mcp_servers.other]\n# keep nested comment\ncommand = \"other-agent\"\n";
    std::fs::write(&config, original).unwrap();
    std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o640)).unwrap();
    let registry = ClientRegistry::new(
        home.to_path_buf(),
        agent,
        Some(fake_codex),
        Some(codex_home),
    );

    assert_eq!(
        registry.register_codex(&home.join("brain.sqlite")).unwrap(),
        RegistrationChange::Updated
    );
    let first = std::fs::read(&config).unwrap();
    let first_metadata = std::fs::metadata(&config).unwrap();
    assert!(String::from_utf8_lossy(&first).contains("# keep top comment"));
    assert!(String::from_utf8_lossy(&first).contains("# keep nested comment"));
    assert!(String::from_utf8_lossy(&first).contains("[mcp_servers.hippocampus]"));
    assert_eq!(first_metadata.permissions().mode() & 0o777, 0o640);

    assert_eq!(
        registry.register_codex(&home.join("brain.sqlite")).unwrap(),
        RegistrationChange::AlreadyCurrent
    );
    let second_metadata = std::fs::metadata(&config).unwrap();
    assert_eq!(std::fs::read(&config).unwrap(), first);
    assert_eq!(second_metadata.ino(), first_metadata.ino());
    assert_eq!(
        second_metadata.modified().unwrap(),
        first_metadata.modified().unwrap()
    );
}

#[test]
fn malformed_codex_toml_is_left_byte_identical() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex = home.join("codex");
    executable(&codex);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = b"password = SENSITIVE_USER_CONTENT\n[mcp_servers.hippocampus\n";
    std::fs::write(&config, original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, Some(codex), Some(codex_home));

    let error = registry
        .register_codex(&home.join("brain.sqlite"))
        .unwrap_err();
    assert!(!error.to_string().contains("SENSITIVE_USER_CONTENT"));
    assert_eq!(std::fs::read(config).unwrap(), original);
}

#[test]
fn unrelated_codex_server_named_hippocampus_is_a_non_destructive_conflict() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex = home.join("codex");
    executable(&codex);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original =
        b"[mcp_servers.hippocampus]\ncommand = \"unrelated-memory-tool\"\nargs = [\"serve\"]\n";
    std::fs::write(&config, original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, Some(codex), Some(codex_home));

    assert!(registry.register_codex(&home.join("brain.sqlite")).is_err());
    assert_eq!(std::fs::read(config).unwrap(), original);
}

#[test]
fn wrong_typed_client_roots_are_refused_unchanged() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude = home.join(".claude.json");
    let original_claude = br#"{"mcpServers":"not-an-object"}"#;
    std::fs::write(&claude, original_claude).unwrap();
    assert!(registry(home, &agent, None)
        .register_claude(&home.join("brain.sqlite"))
        .is_err());
    assert_eq!(std::fs::read(claude).unwrap(), original_claude);

    let codex = home.join("codex");
    executable(&codex);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original_codex = b"mcp_servers = \"not-a-table\"\n";
    std::fs::write(&config, original_codex).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, Some(codex), Some(codex_home));
    assert!(registry.register_codex(&home.join("brain.sqlite")).is_err());
    assert_eq!(std::fs::read(config).unwrap(), original_codex);
}

#[test]
fn concurrent_claude_updates_leave_one_complete_canonical_entry() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let first_registry = registry(home, &agent, None);
    let second_registry = first_registry.clone();
    let first_brain = home.join("first.sqlite");
    let second_brain = home.join("second.sqlite");

    std::thread::scope(|scope| {
        let first = scope.spawn(|| first_registry.register_claude(&first_brain));
        let second = scope.spawn(|| second_registry.register_claude(&second_brain));
        first.join().unwrap().unwrap();
        second.join().unwrap().unwrap();
    });

    let bytes = std::fs::read(home.join(".claude.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let entry = &parsed["mcpServers"]["hippocampus"];
    assert_eq!(entry["type"], "stdio");
    assert_eq!(entry["args"], serde_json::json!(["mcp-serve"]));
    let db = entry["env"]["MCI_DB_PATH"].as_str().unwrap();
    assert!(db.ends_with("first.sqlite") || db.ends_with("second.sqlite"));
    assert!(!String::from_utf8(bytes).unwrap().contains("MCI_DB_KEY_HEX"));
}

#[test]
fn connect_all_cli_registers_claude_and_codex_without_a_database_key() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let fake_codex = home.join("codex");
    std::fs::write(
        &fake_codex,
        b"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/codex-args.txt\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake_codex, std::fs::Permissions::from_mode(0o700)).unwrap();
    let brain = home.join("brain.sqlite");

    let output = Command::new(agent_bin())
        .args(["connect", "--all", "--db-path"])
        .arg(&brain)
        .env("HOME", home)
        .env("MCI_CODEX_BINARY", &fake_codex)
        .env("MCI_CLAUDE_BINARY", &fake_codex)
        .env("MCI_DB_KEY_HEX", "c".repeat(64))
        .env_remove("CODEX_HOME")
        .output()
        .expect("run connect --all");

    assert!(
        output.status.success(),
        "connect --all failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let claude = std::fs::read_to_string(home.join(".claude.json")).unwrap();
    assert!(!claude.contains("MCI_DB_KEY_HEX"));
    let codex = std::fs::read_to_string(home.join(".codex/config.toml")).unwrap();
    assert!(codex.contains("hippocampus"));
    assert!(!codex.contains("MCI_DB_KEY_HEX"));
}
