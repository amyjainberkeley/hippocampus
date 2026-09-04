#![cfg(debug_assertions)]

use std::fs::OpenOptions;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::fs::{symlink, FileExt as _, MetadataExt};
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, Barrier};

use mci_agent::client_registry::{
    ClientRegistration, ClientRegistry, ClientRegistryDebugEvent, RegistrationChange,
    RegistrationErrorKind, RegistrationRepair, RegistrationStatus,
};
use sha2::{Digest as _, Sha256};

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
fn repair_existing_registrations_never_creates_missing_client_configs() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);

    let report =
        registry(home, &agent, None).repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(report.claude.unwrap(), RegistrationRepair::NotRegistered);
    assert_eq!(report.codex.unwrap(), RegistrationRepair::NotRegistered);
    assert!(!home.join(".claude.json").exists());
    assert!(!home.join(".codex").exists());
}

#[test]
fn repair_existing_registrations_leaves_unrelated_configs_byte_identical() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"theme":"dark","mcpServers":{"other":{"command":"keep-me"}}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();
    std::fs::set_permissions(&claude_config, std::fs::Permissions::from_mode(0o640)).unwrap();
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original =
        b"# keep this comment\ntheme = \"light\"\n\n[mcp_servers.other]\ncommand = \"keep-me\"\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    std::fs::set_permissions(&codex_config, std::fs::Permissions::from_mode(0o640)).unwrap();
    let claude_before = std::fs::metadata(&claude_config).unwrap();
    let codex_before = std::fs::metadata(&codex_config).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home.clone()));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(report.claude.unwrap(), RegistrationRepair::NotRegistered);
    assert_eq!(report.codex.unwrap(), RegistrationRepair::NotRegistered);
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
    let claude_after = std::fs::metadata(&claude_config).unwrap();
    let codex_after = std::fs::metadata(&codex_config).unwrap();
    assert_eq!(claude_after.ino(), claude_before.ino());
    assert_eq!(
        claude_after.modified().unwrap(),
        claude_before.modified().unwrap()
    );
    assert_eq!(codex_after.ino(), codex_before.ino());
    assert_eq!(
        codex_after.modified().unwrap(),
        codex_before.modified().unwrap()
    );
    assert!(!home.join("..claude.json.hippocampus.lock").exists());
    assert!(!codex_home.join(".config.toml.hippocampus.lock").exists());
}

#[test]
fn repair_existing_registrations_do_not_validate_replacement_for_unrelated_configs() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let missing_agent = home.join("missing-mci-agent");
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"mcpServers":{"other":{"command":"keep-me"}}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = b"[mcp_servers.other]\ncommand = \"keep-me\"\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), missing_agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(report.claude.unwrap(), RegistrationRepair::NotRegistered);
    assert_eq!(report.codex.unwrap(), RegistrationRepair::NotRegistered);
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
}

#[test]
fn repair_existing_registrations_replace_legacy_secrets_with_keychain_references() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude_config = home.join(".claude.json");
    let legacy_secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    std::fs::write(
        &claude_config,
        format!(
            r#"{{"theme":"light","mcpServers":{{"other":{{"command":"keep-me"}},"hippocampus":{{"type":"stdio","command":"/old/Hippocampus.app/Contents/MacOS/mci-agent","args":["mcp-serve"],"env":{{"MCI_DB_PATH":"/old/brain.sqlite","MCI_DB_KEY_HEX":"{legacy_secret}","MCI_DB_KEY_FILE":"/old/dev.key","UNRELATED_LEGACY_FIELD":"remove-me"}}}}}}}}"#
        ),
    )
    .unwrap();
    std::fs::set_permissions(&claude_config, std::fs::Permissions::from_mode(0o640)).unwrap();

    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    std::fs::write(
        &codex_config,
        format!(
            "# keep top comment\ntheme = \"light\"\n\n[mcp_servers.other]\n# keep unrelated comment\ncommand = \"keep-me\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/Hippocampus.app/Contents/MacOS/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_PATH = \"/old/brain.sqlite\"\nMCI_DB_KEY_HEX = \"{legacy_secret}\"\nMCI_DB_KEY_FILE = \"/old/dev.key\"\nUNRELATED_LEGACY_FIELD = \"remove-me\"\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&codex_config, std::fs::Permissions::from_mode(0o640)).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent.clone(), None, Some(codex_home));
    let brain = home.join("current-brain.sqlite");

    let report = registry.repair_existing_registrations(&brain);

    assert_eq!(report.claude.unwrap(), RegistrationRepair::Updated);
    assert_eq!(report.codex.unwrap(), RegistrationRepair::Updated);

    let claude_bytes = std::fs::read(&claude_config).unwrap();
    let claude: serde_json::Value = serde_json::from_slice(&claude_bytes).unwrap();
    assert_eq!(claude["theme"], "light");
    assert_eq!(claude["mcpServers"]["other"]["command"], "keep-me");
    assert_eq!(
        claude["mcpServers"]["hippocampus"],
        serde_json::json!({
            "type": "stdio",
            "command": agent.to_str().unwrap(),
            "args": ["mcp-serve"],
            "env": {
                "MCI_DB_PATH": brain.to_str().unwrap(),
                "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.brain",
                "MCI_DB_KEYCHAIN_ACCOUNT": "database-key-v1",
                "MCI_DB_KEYCHAIN_STORAGE_MODEL": "file-keychain-acl-v1",
            },
        })
    );
    let claude_text = String::from_utf8(claude_bytes).unwrap();
    assert!(!claude_text.contains(legacy_secret));
    assert!(!claude_text.contains("MCI_DB_KEY_HEX"));
    assert!(!claude_text.contains("MCI_DB_KEY_FILE"));
    assert_eq!(
        std::fs::metadata(&claude_config)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o640
    );

    let codex_text = std::fs::read_to_string(&codex_config).unwrap();
    assert!(codex_text.contains("# keep top comment"));
    assert!(codex_text.contains("# keep unrelated comment"));
    assert!(!codex_text.contains(legacy_secret));
    assert!(!codex_text.contains("MCI_DB_KEY_HEX"));
    assert!(!codex_text.contains("MCI_DB_KEY_FILE"));
    let codex = codex_text.parse::<toml_edit::DocumentMut>().unwrap();
    assert_eq!(codex["theme"].as_str(), Some("light"));
    assert_eq!(
        codex["mcp_servers"]["other"]["command"].as_str(),
        Some("keep-me")
    );
    let server = codex["mcp_servers"]["hippocampus"].as_table_like().unwrap();
    assert_eq!(server.len(), 3);
    assert_eq!(
        server.get("command").and_then(toml_edit::Item::as_str),
        agent.to_str()
    );
    let env = server
        .get("env")
        .and_then(toml_edit::Item::as_table_like)
        .unwrap();
    assert_eq!(env.len(), 4);
    assert_eq!(
        env.get("MCI_DB_PATH").and_then(toml_edit::Item::as_str),
        brain.to_str()
    );
    assert_eq!(
        env.get("MCI_DB_KEYCHAIN_SERVICE")
            .and_then(toml_edit::Item::as_str),
        Some("ai.hippocampus.brain")
    );
    assert_eq!(
        std::fs::metadata(&codex_config)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o640
    );
}

#[test]
fn repair_existing_registrations_fail_closed_on_conflicting_ownership_markers() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"mcpServers":{"hippocampus":{"command":"unrelated-memory-tool","args":["serve"],"env":{"MCI_DB_KEYCHAIN_SERVICE":"ai.hippocampus.brain","MCI_DB_KEY_HEX":"do-not-echo"}}}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();

    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = b"[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEYCHAIN_SERVICE = \"unrelated.key.service\"\nMCI_DB_KEY_HEX = \"do-not-echo\"\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    let claude_error = report.claude.unwrap_err();
    assert_eq!(claude_error.kind, RegistrationErrorKind::NameConflict);
    assert!(!claude_error.to_string().contains("do-not-echo"));
    let codex_error = report.codex.unwrap_err();
    assert_eq!(codex_error.kind, RegistrationErrorKind::NameConflict);
    assert!(!codex_error.to_string().contains("do-not-echo"));
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
}

#[test]
fn repair_existing_registrations_fail_closed_on_malformed_named_entries() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"mcpServers":{"hippocampus":["not-an-entry"]}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();

    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = b"[mcp_servers]\nhippocampus = 17\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(
        report.claude.unwrap_err().kind,
        RegistrationErrorKind::BlockedMalformed
    );
    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::BlockedMalformed
    );
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
}

#[test]
fn repair_existing_registrations_leave_canonical_entries_metadata_identical() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let brain = home.join("brain.sqlite");
    let claude_config = home.join(".claude.json");
    let claude_original = format!(
        r#"{{"mcpServers":{{"hippocampus":{{"type":"stdio","command":"{}","args":["mcp-serve"],"env":{{"MCI_DB_PATH":"{}","MCI_DB_KEYCHAIN_SERVICE":"ai.hippocampus.brain","MCI_DB_KEYCHAIN_ACCOUNT":"database-key-v1","MCI_DB_KEYCHAIN_STORAGE_MODEL":"file-keychain-acl-v1"}}}}}}}}"#,
        agent.to_str().unwrap(),
        brain.to_str().unwrap()
    );
    std::fs::write(&claude_config, claude_original.as_bytes()).unwrap();
    std::fs::set_permissions(&claude_config, std::fs::Permissions::from_mode(0o640)).unwrap();

    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = format!(
        "# canonical and intentionally compact\n[mcp_servers.hippocampus]\ncommand = \"{}\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEYCHAIN_ACCOUNT = \"database-key-v1\"\nMCI_DB_KEYCHAIN_SERVICE = \"ai.hippocampus.brain\"\nMCI_DB_KEYCHAIN_STORAGE_MODEL = \"file-keychain-acl-v1\"\nMCI_DB_PATH = \"{}\"\n",
        agent.to_str().unwrap(),
        brain.to_str().unwrap()
    );
    std::fs::write(&codex_config, codex_original.as_bytes()).unwrap();
    std::fs::set_permissions(&codex_config, std::fs::Permissions::from_mode(0o640)).unwrap();
    let claude_before = std::fs::metadata(&claude_config).unwrap();
    let codex_before = std::fs::metadata(&codex_config).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home.clone()));

    let report = registry.repair_existing_registrations(&brain);

    assert_eq!(report.claude.unwrap(), RegistrationRepair::AlreadyCurrent);
    assert_eq!(report.codex.unwrap(), RegistrationRepair::AlreadyCurrent);
    assert_eq!(
        std::fs::read(&claude_config).unwrap(),
        claude_original.as_bytes()
    );
    assert_eq!(
        std::fs::read(&codex_config).unwrap(),
        codex_original.as_bytes()
    );
    let claude_after = std::fs::metadata(&claude_config).unwrap();
    let codex_after = std::fs::metadata(&codex_config).unwrap();
    assert_eq!(claude_after.ino(), claude_before.ino());
    assert_eq!(
        claude_after.modified().unwrap(),
        claude_before.modified().unwrap()
    );
    assert_eq!(claude_after.permissions().mode() & 0o777, 0o640);
    assert_eq!(codex_after.ino(), codex_before.ino());
    assert_eq!(
        codex_after.modified().unwrap(),
        codex_before.modified().unwrap()
    );
    assert_eq!(codex_after.permissions().mode() & 0o777, 0o640);
    assert!(!home.join("..claude.json.hippocampus.lock").exists());
    assert!(!codex_home.join(".config.toml.hippocampus.lock").exists());
}

#[test]
fn repair_detects_same_byte_inode_replacement_before_atomic_replace() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = format!(
        "padding = \"{}\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"legacy-secret\"\n",
        "a".repeat(8 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&config, &original).unwrap();
    let replacement = codex_home.join("same-byte-replacement.toml");
    std::fs::write(&replacement, &original).unwrap();
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home))
        .with_debug_hook(Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::BeforeAtomicReplace {
                ready_hook.wait();
                resume_hook.wait();
            }
        }));
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    std::fs::rename(&replacement, &config).unwrap();
    let replacement_inode = std::fs::metadata(&config).unwrap().ino();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    assert_eq!(std::fs::metadata(&config).unwrap().ino(), replacement_inode);
    assert_eq!(std::fs::read(config).unwrap(), original);
}

#[test]
fn repair_preserves_concurrent_symlink_replacement_and_reports_concurrent_change() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = format!(
        "padding = \"{}\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"legacy-secret\"\n",
        "a".repeat(8 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&config, &original).unwrap();
    let alternate = codex_home.join("concurrent-config.toml");
    std::fs::write(&alternate, &original).unwrap();
    let replacement = codex_home.join("concurrent-link.toml");
    symlink(Path::new("concurrent-config.toml"), &replacement).unwrap();
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home))
        .with_debug_hook(Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::BeforeAtomicReplace {
                ready_hook.wait();
                resume_hook.wait();
            }
        }));
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    std::fs::rename(&replacement, &config).unwrap();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    assert!(config.symlink_metadata().unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read(config).unwrap(), original);
}

#[test]
fn repair_resolves_two_hop_symlink_without_replacing_intermediate_link() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let dotfiles = home.join("dotfiles");
    std::fs::create_dir(&dotfiles).unwrap();
    let target = dotfiles.join("claude.json");
    std::fs::write(
        &target,
        br#"{"mcpServers":{"hippocampus":{"command":"/old/mci-agent","args":["mcp-serve"],"env":{"MCI_DB_KEY_HEX":"legacy-secret"}}}}"#,
    )
    .unwrap();
    let intermediate = dotfiles.join("current-claude.json");
    symlink(Path::new("claude.json"), &intermediate).unwrap();
    let config = home.join(".claude.json");
    symlink(Path::new("dotfiles/current-claude.json"), &config).unwrap();

    let report =
        registry(home, &agent, None).repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(report.claude.unwrap(), RegistrationRepair::Updated);
    assert!(config.symlink_metadata().unwrap().file_type().is_symlink());
    assert!(intermediate
        .symlink_metadata()
        .unwrap()
        .file_type()
        .is_symlink());
    let updated = std::fs::read_to_string(target).unwrap();
    assert!(updated.contains(agent.to_str().unwrap()));
    assert!(!updated.contains("MCI_DB_KEY_HEX"));
}

#[test]
fn repair_detects_logical_symlink_chain_retarget_during_atomic_prepare() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let dotfiles = home.join("dotfiles");
    std::fs::create_dir(&dotfiles).unwrap();
    let old_target = dotfiles.join("old-claude.json");
    let old_original = format!(
        r#"{{"padding":"{}","mcpServers":{{"hippocampus":{{"command":"/old/mci-agent","args":["mcp-serve"],"env":{{"MCI_DB_KEY_HEX":"old-secret"}}}}}}}}"#,
        "a".repeat(8 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&old_target, &old_original).unwrap();
    let new_target = dotfiles.join("new-claude.json");
    let new_original = br#"{"mcpServers":{"hippocampus":{"command":"/old/mci-agent","args":["mcp-serve"],"env":{"MCI_DB_KEY_HEX":"active-secret"}}}}"#;
    std::fs::write(&new_target, new_original).unwrap();
    let intermediate = dotfiles.join("current-claude.json");
    symlink(Path::new("old-claude.json"), &intermediate).unwrap();
    let config = home.join(".claude.json");
    symlink(Path::new("dotfiles/current-claude.json"), &config).unwrap();
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, None).with_debug_hook(
        Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::BeforeAtomicReplace {
                ready_hook.wait();
                resume_hook.wait();
            }
        }),
    );
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    let replacement = dotfiles.join("retargeted-link");
    symlink(Path::new("new-claude.json"), &replacement).unwrap();
    std::fs::rename(replacement, &intermediate).unwrap();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.claude.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    assert_eq!(
        std::fs::read_link(&intermediate).unwrap(),
        Path::new("new-claude.json")
    );
    assert_eq!(std::fs::read(&old_target).unwrap(), old_original);
    assert_eq!(std::fs::read(config).unwrap(), new_original);
}

#[test]
fn repair_detects_parent_symlink_chain_retarget_without_leaving_transaction_residue() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let roots = home.join("roots");
    let old_home = roots.join("old");
    let new_home = roots.join("new");
    std::fs::create_dir_all(&old_home).unwrap();
    std::fs::create_dir(&new_home).unwrap();
    let old_config = old_home.join("config.toml");
    let old_original = format!(
        "padding = \"{}\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"old-secret\"\n",
        "a".repeat(8 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&old_config, &old_original).unwrap();
    let new_config = new_home.join("config.toml");
    let new_original = b"[mcp_servers.hippocampus]\ncommand = \"/new/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"active-secret\"\n";
    std::fs::write(&new_config, new_original).unwrap();

    let current = roots.join("current");
    symlink(Path::new("old"), &current).unwrap();
    let codex_home = home.join("codex-home");
    symlink(Path::new("roots/current"), &codex_home).unwrap();
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home))
        .with_debug_hook(Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::BeforeAtomicReplace {
                ready_hook.wait();
                resume_hook.wait();
            }
        }));
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    let replacement = roots.join("retargeted-current");
    symlink(Path::new("new"), &replacement).unwrap();
    std::fs::rename(replacement, &current).unwrap();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    assert_eq!(std::fs::read(&old_config).unwrap(), old_original);
    assert_eq!(std::fs::read(&new_config).unwrap(), new_original);
    assert!(std::fs::read_dir(&old_home).unwrap().all(|entry| {
        let name = entry.unwrap().file_name();
        let name = name.to_string_lossy();
        !name.starts_with(".config.toml.tmp-")
            && !name.starts_with(".config.toml.hippocampus-exchange-")
    }));
}

#[test]
fn repair_rolls_back_when_retained_original_descriptor_changes_after_exchange() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = format!(
        "padding = \"{}\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"legacy-secret\"\n",
        "a".repeat(16 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&config, &original).unwrap();
    let retained = OpenOptions::new().write(true).open(&config).unwrap();
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home))
        .with_debug_hook(Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::AfterAtomicExchange {
                ready_hook.wait();
                resume_hook.wait();
            }
        }));
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    retained.write_all_at(b"b", 12).unwrap();
    retained.sync_all().unwrap();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    let mut expected = original;
    expected[12] = b'b';
    let restored = std::fs::read(config).unwrap();
    assert_eq!(restored.len(), expected.len());
    assert_eq!(restored[12], b'b');
    assert_eq!(&restored[..12], &expected[..12]);
    assert_eq!(&restored[13..], &expected[13..]);
}

#[test]
fn repair_rolls_back_when_displaced_original_gains_a_hard_link() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let config = codex_home.join("config.toml");
    let original = format!(
        "padding = \"{}\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = \"legacy-secret\"\n",
        "a".repeat(16 * 1024 * 1024)
    )
    .into_bytes();
    std::fs::write(&config, &original).unwrap();
    let original_inode = std::fs::metadata(&config).unwrap().ino();
    let leaked_link = codex_home.join("concurrent-original-link.toml");
    let ready = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let ready_hook = Arc::clone(&ready);
    let resume_hook = Arc::clone(&resume);
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home.clone()))
        .with_debug_hook(Arc::new(move |event| {
            if event == ClientRegistryDebugEvent::AfterAtomicExchange {
                ready_hook.wait();
                resume_hook.wait();
            }
        }));
    let brain = home.join("brain.sqlite");
    let repairer = std::thread::spawn(move || registry.repair_existing_registrations(&brain));

    ready.wait();
    let displaced = std::fs::read_dir(&codex_home)
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".config.toml.tmp-")
                && entry
                    .metadata()
                    .is_ok_and(|metadata| metadata.ino() == original_inode)
        })
        .expect("displaced original remains named until validation");
    std::fs::hard_link(displaced.path(), &leaked_link).unwrap();
    resume.wait();
    let report = repairer.join().unwrap();

    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::ConcurrentChange
    );
    assert_eq!(std::fs::metadata(&config).unwrap().ino(), original_inode);
    assert_eq!(
        std::fs::metadata(&leaked_link).unwrap().ino(),
        original_inode
    );
    assert!(std::fs::read_to_string(config)
        .unwrap()
        .contains("MCI_DB_KEY_HEX = \"legacy-secret\""));
}

#[test]
fn repair_recovers_identifiable_exchange_artifact_after_logical_symlink_retarget() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let brain = home.join("brain.sqlite");
    let old_home = home.join("old-codex-home");
    let new_home = home.join("new-codex-home");
    std::fs::create_dir(&old_home).unwrap();
    std::fs::create_dir(&new_home).unwrap();
    let codex_home = home.join("codex-home");
    symlink(Path::new("old-codex-home"), &codex_home).unwrap();
    let old_config = old_home.join("config.toml");
    let new_config = new_home.join("config.toml");
    let canonical = format!(
        "[mcp_servers.hippocampus]\ncommand = \"{}\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEYCHAIN_ACCOUNT = \"database-key-v1\"\nMCI_DB_KEYCHAIN_SERVICE = \"ai.hippocampus.brain\"\nMCI_DB_KEYCHAIN_STORAGE_MODEL = \"file-keychain-acl-v1\"\nMCI_DB_PATH = \"{}\"\n",
        agent.to_str().unwrap(),
        brain.to_str().unwrap()
    )
    .into_bytes();
    std::fs::write(&old_config, &canonical).unwrap();
    std::fs::write(&new_config, &canonical).unwrap();
    let artifact_name = ".config.toml.tmp-deadbeef";
    let artifact = old_home.join(artifact_name);
    let displaced = b"MCI_DB_KEY_HEX = \"crash-residue-secret\"\n";
    std::fs::write(&artifact, displaced).unwrap();
    let unrelated = old_home.join(".config.toml.hippocampus-exchange-unrelated.artifact");
    std::fs::write(&unrelated, b"do not delete").unwrap();
    let artifact_metadata = std::fs::metadata(&artifact).unwrap();
    let config_metadata = std::fs::metadata(&old_config).unwrap();
    let logical_config = codex_home.join("config.toml");
    let logical_path_sha256 = format!(
        "{:x}",
        Sha256::digest(logical_config.as_os_str().as_bytes())
    );
    let marker = home.join(format!(
        ".hippocampus-client-registry-journal-{logical_path_sha256}-deadbeef.marker"
    ));
    let physical_old_config = std::fs::canonicalize(&old_config).unwrap();
    let marker_value = serde_json::json!({
        "version": 2,
        "logical_path_sha256": logical_path_sha256,
        "target_path": physical_old_config.as_os_str().as_bytes(),
        "artifact_name": artifact_name,
        "original": {
            "device": artifact_metadata.dev(),
            "inode": artifact_metadata.ino(),
            "length": artifact_metadata.len(),
            "sha256": format!("{:x}", Sha256::digest(displaced)),
        },
        "output": {
            "device": config_metadata.dev(),
            "inode": config_metadata.ino(),
            "length": config_metadata.len(),
            "sha256": format!("{:x}", Sha256::digest(&canonical)),
        }
    });
    let marker_bytes = serde_json::to_vec(&marker_value).unwrap();
    assert!(!String::from_utf8_lossy(&marker_bytes).contains("crash-residue-secret"));
    assert!(!String::from_utf8_lossy(&marker_bytes).contains("MCI_DB_KEY_HEX"));
    std::fs::write(&marker, marker_bytes).unwrap();
    std::fs::set_permissions(&marker, std::fs::Permissions::from_mode(0o600)).unwrap();
    let replacement = home.join("retargeted-codex-home");
    symlink(Path::new("new-codex-home"), &replacement).unwrap();
    std::fs::rename(replacement, &codex_home).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&brain);

    assert_eq!(report.codex.unwrap(), RegistrationRepair::AlreadyCurrent);
    assert!(!artifact.exists());
    assert!(!marker.exists());
    assert_eq!(std::fs::read(unrelated).unwrap(), b"do not delete");
    assert_eq!(std::fs::read(new_config).unwrap(), canonical);
}

#[test]
fn repair_classifies_named_conflicts_before_validating_missing_replacement() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let missing_agent = home.join("missing-mci-agent");
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"mcpServers":{"hippocampus":{"command":"unrelated-agent","args":["serve"],"env":{}}}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = b"[mcp_servers.hippocampus]\ncommand = \"unrelated-agent\"\nargs = [\"serve\"]\n\n[mcp_servers.hippocampus.env]\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), missing_agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(
        report.claude.unwrap_err().kind,
        RegistrationErrorKind::NameConflict
    );
    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::NameConflict
    );
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
}

#[test]
fn repair_rejects_non_string_values_anywhere_in_owned_entry_env() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let claude_config = home.join(".claude.json");
    let claude_original = br#"{"mcpServers":{"hippocampus":{"command":"/old/mci-agent","args":["mcp-serve"],"env":{"MCI_DB_KEY_HEX":17}}}}"#;
    std::fs::write(&claude_config, claude_original).unwrap();
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let codex_original = b"[mcp_servers.hippocampus]\ncommand = \"/old/mci-agent\"\nargs = [\"mcp-serve\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_KEY_HEX = 17\n";
    std::fs::write(&codex_config, codex_original).unwrap();
    let registry = ClientRegistry::new(home.to_path_buf(), agent, None, Some(codex_home));

    let report = registry.repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(
        report.claude.unwrap_err().kind,
        RegistrationErrorKind::BlockedMalformed
    );
    assert_eq!(
        report.codex.unwrap_err().kind,
        RegistrationErrorKind::BlockedMalformed
    );
    assert_eq!(std::fs::read(&claude_config).unwrap(), claude_original);
    assert_eq!(std::fs::read(&codex_config).unwrap(), codex_original);
}

#[test]
fn repair_rejects_duplicate_claude_json_ownership_keys() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let config = home.join(".claude.json");
    let original = br#"{"mcpServers":{"hippocampus":{"command":"unrelated-agent","command":"/old/mci-agent","args":["mcp-serve"],"env":{"MCI_DB_KEY_HEX":"legacy-secret"}}}}"#;
    std::fs::write(&config, original).unwrap();

    let report =
        registry(home, &agent, None).repair_existing_registrations(&home.join("brain.sqlite"));

    assert_eq!(
        report.claude.unwrap_err().kind,
        RegistrationErrorKind::BlockedMalformed
    );
    assert_eq!(std::fs::read(config).unwrap(), original);
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
fn dangling_codex_home_symlink_is_refused_without_creating_its_target() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let agent = home.join("mci-agent");
    executable(&agent);
    let codex = home.join("codex");
    executable(&codex);
    let codex_home = home.join("codex-home");
    let missing_home = home.join("missing-codex-home");
    symlink(Path::new("missing-codex-home"), &codex_home).unwrap();
    let registry = ClientRegistry::new(
        home.to_path_buf(),
        agent,
        Some(codex),
        Some(codex_home.clone()),
    );

    assert!(registry.register_codex(&home.join("brain.sqlite")).is_err());
    assert!(codex_home
        .symlink_metadata()
        .unwrap()
        .file_type()
        .is_symlink());
    assert!(!missing_home.exists());
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
