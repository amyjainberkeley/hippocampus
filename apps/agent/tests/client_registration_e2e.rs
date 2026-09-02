use std::collections::BTreeMap;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use mci_agent::client_registry::{ClientRegistry, RegistrationStatus};

#[derive(Debug, PartialEq, Eq)]
struct GeneratedServer {
    command: PathBuf,
    args: Vec<String>,
    env: BTreeMap<String, String>,
}

#[test]
fn generated_claude_and_codex_commands_are_idempotent_secret_free_and_callable() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex_home = home.join(".codex-fixture");
    let app_macos = temp
        .path()
        .join("Applications/Hippocampus.app/Contents/MacOS");
    std::fs::create_dir_all(&app_macos).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let agent = app_macos.join("mci-agent");
    write_mcp_fixture(&agent);
    let brain = home.join("brain.sqlite");
    let registry = ClientRegistry::new(
        home.clone(),
        agent,
        Some(PathBuf::from("/bin/true")),
        Some(codex_home.clone()),
    );

    let first = registry.connect_all(&brain);
    assert_eq!(first.claude.status, RegistrationStatus::Registered);
    assert_eq!(first.codex.status, RegistrationStatus::Registered);
    let claude_path = home.join(".claude.json");
    let codex_path = codex_home.join("config.toml");
    let claude_first = std::fs::read(&claude_path).unwrap();
    let codex_first = std::fs::read(&codex_path).unwrap();
    let claude_metadata = std::fs::metadata(&claude_path).unwrap();
    let codex_metadata = std::fs::metadata(&codex_path).unwrap();

    let second = registry.connect_all(&brain);
    assert_eq!(second.claude.status, RegistrationStatus::Unchanged);
    assert_eq!(second.codex.status, RegistrationStatus::Unchanged);
    assert_eq!(std::fs::read(&claude_path).unwrap(), claude_first);
    assert_eq!(std::fs::read(&codex_path).unwrap(), codex_first);
    assert_eq!(
        std::fs::metadata(&claude_path).unwrap().modified().unwrap(),
        claude_metadata.modified().unwrap()
    );
    assert_eq!(
        std::fs::metadata(&codex_path).unwrap().modified().unwrap(),
        codex_metadata.modified().unwrap()
    );

    let claude = parse_claude(&claude_path);
    let codex = parse_codex(&codex_path);
    assert_eq!(claude, codex);
    assert_canonical_environment(&claude.env, &brain);
    exercise_generated_server(&claude, &home);
    exercise_generated_server(&codex, &home);
}

fn write_mcp_fixture(path: &Path) {
    let script = r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
      ;;
    *'"method":"tools/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"mci_context","description":"fixture","inputSchema":{"type":"object"}}]}}'
      ;;
    *'"name":"mci_context"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"packet":{"outcome":"observations_only","focus":"hippocampus"},"content":[{"type":"text","text":"fixture context"}],"isError":false}}'
      ;;
  esac
done
"#;
    std::fs::write(path, script).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn parse_claude(path: &Path) -> GeneratedServer {
    let root: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let server = &root["mcpServers"]["hippocampus"];
    GeneratedServer {
        command: PathBuf::from(server["command"].as_str().unwrap()),
        args: server["args"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect(),
        env: server["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, value)| (key.clone(), value.as_str().unwrap().to_owned()))
            .collect(),
    }
}

fn parse_codex(path: &Path) -> GeneratedServer {
    let document = std::fs::read_to_string(path)
        .unwrap()
        .parse::<toml_edit::DocumentMut>()
        .unwrap();
    let server = document["mcp_servers"]["hippocampus"]
        .as_table_like()
        .unwrap();
    let env = server
        .get("env")
        .and_then(toml_edit::Item::as_table_like)
        .unwrap();
    GeneratedServer {
        command: PathBuf::from(
            server
                .get("command")
                .and_then(toml_edit::Item::as_str)
                .unwrap(),
        ),
        args: server
            .get("args")
            .and_then(toml_edit::Item::as_array)
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect(),
        env: env
            .iter()
            .map(|(key, value)| (key.to_owned(), value.as_str().unwrap().to_owned()))
            .collect(),
    }
}

fn assert_canonical_environment(env: &BTreeMap<String, String>, brain: &Path) {
    assert_eq!(env.len(), 4);
    assert_eq!(env["MCI_DB_PATH"], brain.to_str().unwrap());
    assert_eq!(env["MCI_DB_KEYCHAIN_SERVICE"], "ai.hippocampus.brain");
    assert_eq!(env["MCI_DB_KEYCHAIN_ACCOUNT"], "database-key-v1");
    assert_eq!(env["MCI_DB_KEYCHAIN_STORAGE_MODEL"], "file-keychain-acl-v1");
    assert!(!env.contains_key("MCI_DB_KEY_HEX"));
    assert!(!env.contains_key("MCI_DEVELOPMENT_FILE_KEY"));
}

fn exercise_generated_server(server: &GeneratedServer, home: &Path) {
    let mut child = Command::new(&server.command)
        .args(&server.args)
        .env_clear()
        .env("HOME", home)
        .envs(&server.env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn generated MCP command");
    let requests = [
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "registry-e2e", "version": "1"}
            }
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "mci_context",
                "arguments": {"project": "hippocampus"}
            }
        }),
    ];
    {
        let stdin = child.stdin.as_mut().unwrap();
        for request in requests {
            writeln!(stdin, "{}", serde_json::to_string(&request).unwrap()).unwrap();
        }
    }
    drop(child.stdin.take());

    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let _ = child.wait();
            panic!("generated MCP command exceeded three-second timeout");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "fixture failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let responses = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(responses.len(), 3);
    assert_eq!(responses[0]["result"]["serverInfo"]["name"], "fixture");
    assert_eq!(
        responses[1]["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|tool| tool["name"] == "mci_context")
            .count(),
        1
    );
    assert_eq!(
        responses[2]["result"]["packet"]["outcome"],
        "observations_only"
    );
}
