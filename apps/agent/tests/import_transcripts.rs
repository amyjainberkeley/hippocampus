//! Transcript import against the contract in `docs/handoff/CONTRACT.md`
//! section 1, over synthetic fixtures and temp databases.
//!
//! The fixtures under `tests/fixtures/` are copied into a temp dir first,
//! because several tests append to them to prove the cursors resume.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use mci_agent::import_codex::import_codex;
use mci_agent::import_sessions::import_sessions;
use mci_agent::refresh::{refresh, RefreshRoots, RefreshStage};
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{Event, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use tempfile::TempDir;

const CLAUDE_FILE: &str = "-Users-amy-demo/11111111-aaaa-bbbb-cccc-000000000001.jsonl";
const CODEX_FILE: &str =
    "2026/09/25/rollout-2026-09-25T11-00-00-01a0f000-0000-7000-8000-000000000001.jsonl";
const CODEX_SESSION: &str = "01a0f000-0000-7000-8000-000000000001";

/// Events the Claude fixture yields: user, assistant, tool, tool, assistant,
/// and a dictated user line.
const CLAUDE_EVENTS: u64 = 6;
/// Events the Codex fixture yields: user, assistant, tool, tool, tool, assistant.
const CODEX_EVENTS: u64 = 6;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn copy_dir_all(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst).expect("mkdir");
    for entry in std::fs::read_dir(src).expect("read_dir").flatten() {
        let target = dst.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir_all(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("copy");
        }
    }
}

struct Sandbox {
    _dir: TempDir,
    claude_root: PathBuf,
    codex_root: PathBuf,
    db_path: PathBuf,
    key: DbKey,
}

impl Sandbox {
    fn new() -> Self {
        let dir = TempDir::new().expect("tempdir");
        let claude_root = dir.path().join("claude/projects");
        let codex_root = dir.path().join("codex/sessions");
        copy_dir_all(&fixtures().join("claude-code"), &claude_root);
        copy_dir_all(&fixtures().join("codex"), &codex_root);
        Self {
            db_path: dir.path().join("brain.sqlite"),
            key: DbKey::from_bytes([0xaa; 32]),
            _dir: dir,
            claude_root,
            codex_root,
        }
    }

    fn store(&self) -> SqlCipherBrainStore {
        SqlCipherBrainStore::new(&self.db_path, &self.key).expect("open store")
    }

    fn claude_file(&self) -> PathBuf {
        self.claude_root.join(CLAUDE_FILE)
    }

    fn codex_file(&self) -> PathBuf {
        self.codex_root.join(CODEX_FILE)
    }

    fn append(path: &Path, line: &str) {
        use std::io::Write as _;
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .expect("open for append");
        f.write_all(line.as_bytes()).expect("append");
        // Push the mtime forward: same-second appends must still register.
        let later = std::time::SystemTime::now() + Duration::from_secs(2);
        f.set_modified(later).expect("set mtime");
    }
}

fn all_events(store: &SqlCipherBrainStore) -> Vec<Event> {
    store.events_after_id(0, 10_000).expect("events")
}

fn body(event: &Event) -> &str {
    event.text.split_once('\n').map_or("", |(_, b)| b)
}

fn header(event: &Event) -> &str {
    event.text.split_once('\n').map_or(&event.text, |(h, _)| h)
}

#[test]
fn claude_fixture_yields_exactly_the_contract_events() {
    let sb = Sandbox::new();
    let store = sb.store();
    let stats = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");

    assert_eq!(stats.files_scanned, 1);
    assert_eq!(stats.records_read, 17);
    assert_eq!(stats.events_written, CLAUDE_EVENTS);
    assert_eq!(stats.tool_events_written, 2);
    assert_eq!(
        stats.skipped_injected, 5,
        "system-reminder, files list, interrupted, task-notification, image placeholder"
    );
    assert_eq!(stats.skipped_sidechain, 1);
    assert_eq!(stats.skipped_meta, 1);
    assert_eq!(stats.skipped_no_text, 3, "Read, tool_result, git status");
    assert_eq!(stats.malformed_lines, 0);

    let events = all_events(&store);
    let titles: Vec<&str> = events
        .iter()
        .map(|e| e.window_title.as_deref().unwrap_or(""))
        .collect();
    assert_eq!(
        titles,
        [
            "demo · user",
            "demo · assistant",
            "demo · tool",
            "demo · tool",
            "demo · assistant",
            "demo · user"
        ]
    );
    for e in &events {
        assert_eq!(
            e.app_bundle_id.as_deref(),
            Some("com.anthropic.claude-code")
        );
        assert_eq!(e.url.as_deref(), Some("/Users/amy/demo"));
    }

    let src = sb.claude_file();
    assert_eq!(
        header(&events[0]),
        format!(
            "[app=claude-code | title=demo · user | url=/Users/amy/demo#main | session=sess-1 | src={}:2]",
            src.display()
        )
    );
    assert_eq!(body(&events[0]), "Please add an import cursor table.");
    assert_eq!(body(&events[2]), "Edit /Users/amy/demo/src/store.rs");
    assert!(header(&events[2]).ends_with(":5]"));
    assert_eq!(
        body(&events[3]),
        "Bash git add -A && git commit -m \"feat: import cursors\""
    );
    assert!(header(&events[3]).ends_with(":8]"));
    assert_eq!(body(&events[4]), "Done. Next: run the tests.");
    assert!(header(&events[4]).ends_with(":14]"));
    assert_eq!(
        body(&events[5]),
        "<dictation>Ship it tonight.</dictation>",
        "dictation is something the person said"
    );
    assert!(header(&events[5]).ends_with(":16]"));
    // 2026-09-25T10:00:00Z
    assert_eq!(events[0].ts_us, 1_790_330_400_000_000);
}

#[test]
fn codex_fixture_yields_exactly_the_contract_events() {
    let sb = Sandbox::new();
    let store = sb.store();
    let stats = import_codex(&store, &sb.codex_root, |_| {}).expect("import");

    assert_eq!(stats.files_scanned, 1, "the subagent rollout is not opened");
    assert_eq!(stats.files_skipped_subagent, 1);
    assert_eq!(stats.records_read, 15);
    assert_eq!(stats.events_written, CODEX_EVENTS);
    assert_eq!(stats.tool_events_written, 3);
    assert_eq!(
        stats.skipped_injected, 2,
        "recommended_plugins, environment_context"
    );
    assert_eq!(stats.skipped_no_text, 1, "developer message");

    let events = all_events(&store);
    let titles: Vec<&str> = events
        .iter()
        .map(|e| e.window_title.as_deref().unwrap_or(""))
        .collect();
    assert_eq!(
        titles,
        [
            "demo · user",
            "demo · assistant",
            "demo · tool",
            "demo · tool",
            "demo · tool",
            "demo · assistant"
        ]
    );
    for e in &events {
        assert_eq!(e.app_bundle_id.as_deref(), Some("com.openai.codex"));
        assert_eq!(e.url.as_deref(), Some("/Users/amy/demo"));
    }
    let src = sb.codex_file();
    assert_eq!(
        header(&events[0]),
        format!(
            "[app=codex | title=demo · user | url=/Users/amy/demo# | session={CODEX_SESSION} | src={}:6]",
            src.display()
        )
    );
    assert_eq!(body(&events[0]), "Wire the Codex importer.");
    assert_eq!(body(&events[1]), "Starting with the rollout parser.");
    assert_eq!(
        body(&events[2]),
        "shell bash -lc git commit -am \"feat: codex importer\""
    );
    assert!(header(&events[2]).ends_with(":11]"));
    assert_eq!(
        body(&events[3]),
        "apply_patch /Users/amy/demo/apps/agent/src/import_codex.rs\napply_patch /Users/amy/demo/docs/notes.md"
    );
    assert_eq!(body(&events[4]), "exec_command git push origin main");
    assert_eq!(body(&events[5]), "Pushed. Next: tests.");
    assert!(
        !events.iter().any(|e| e.text.contains("reviewer")),
        "subagent thread content must not be imported"
    );
}

#[test]
fn a_second_run_reads_nothing_and_writes_nothing() {
    let sb = Sandbox::new();
    let store = sb.store();
    import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    import_codex(&store, &sb.codex_root, |_| {}).expect("import");

    let claude = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    let codex = import_codex(&store, &sb.codex_root, |_| {}).expect("import");
    assert_eq!(claude.events_written, 0);
    assert_eq!(claude.files_scanned, 0);
    assert_eq!(claude.files_unchanged, 1);
    assert_eq!(claude.bytes_read, 0);
    assert_eq!(codex.events_written, 0);
    assert_eq!(codex.files_scanned, 0);
    assert_eq!(codex.files_unchanged, 1);
    assert_eq!(
        all_events(&store).len() as u64,
        CLAUDE_EVENTS + CODEX_EVENTS
    );
}

#[test]
fn appending_lines_imports_exactly_the_new_events() {
    let sb = Sandbox::new();
    let store = sb.store();
    import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    import_codex(&store, &sb.codex_root, |_| {}).expect("import");

    Sandbox::append(
        &sb.claude_file(),
        "{\"type\":\"user\",\"isSidechain\":false,\"cwd\":\"/Users/amy/demo\",\"sessionId\":\"sess-1\",\
         \"gitBranch\":\"main\",\"timestamp\":\"2026-09-25T10:20:00.000Z\",\
         \"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Now the Codex side.\"}]}}\n",
    );
    Sandbox::append(
        &sb.codex_file(),
        "{\"timestamp\":\"2026-09-25T11:20:00.000Z\",\"ordinal\":15,\"type\":\"response_item\",\
         \"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Cursors resume.\"}]}}\n",
    );

    let claude = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    let codex = import_codex(&store, &sb.codex_root, |_| {}).expect("import");
    assert_eq!(claude.events_written, 1);
    assert_eq!(claude.files_resumed, 1);
    assert_eq!(claude.records_read, 1, "only the appended line is parsed");
    assert_eq!(codex.events_written, 1);
    assert_eq!(codex.files_resumed, 1);
    assert_eq!(codex.records_read, 1);

    let events = all_events(&store);
    assert_eq!(events.len() as u64, CLAUDE_EVENTS + CODEX_EVENTS + 2);
    let claude_new = &events[events.len() - 2];
    assert_eq!(body(claude_new), "Now the Codex side.");
    assert!(
        header(claude_new).ends_with(":18]"),
        "line numbers continue across resumes: {}",
        header(claude_new)
    );
    let codex_new = &events[events.len() - 1];
    assert_eq!(body(codex_new), "Cursors resume.");
    assert!(
        header(codex_new).contains(&format!("session={CODEX_SESSION} |")),
        "session id survives a resume past line 1: {}",
        header(codex_new)
    );
    assert!(header(codex_new).ends_with(":16]"));
}

#[test]
fn a_partial_trailing_line_waits_for_the_next_run() {
    let sb = Sandbox::new();
    let store = sb.store();
    import_sessions(&store, &sb.claude_root, |_| {}).expect("import");

    let head = "{\"type\":\"user\",\"cwd\":\"/Users/amy/demo\",\"sessionId\":\"sess-1\",\"gitBranch\":\"main\",\
                \"timestamp\":\"2026-09-25T10:30:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",";
    let tail = "\"text\":\"half written\"}]}}\n";
    Sandbox::append(&sb.claude_file(), head);
    let partial = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    assert_eq!(partial.events_written, 0);
    assert_eq!(
        partial.malformed_lines, 0,
        "an unfinished line is not malformed"
    );

    Sandbox::append(&sb.claude_file(), tail);
    let done = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    assert_eq!(done.events_written, 1);
    assert_eq!(body(all_events(&store).last().unwrap()), "half written");
}

#[test]
fn clearing_cursors_reimports_everything() {
    let sb = Sandbox::new();
    let store = sb.store();
    import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    import_codex(&store, &sb.codex_root, |_| {}).expect("import");

    let cleared = store
        .clear_import_cursors(&sb.claude_root.to_string_lossy())
        .expect("clear");
    assert_eq!(cleared, 1);
    assert_eq!(
        store
            .list_import_cursors(&sb.codex_root.to_string_lossy())
            .expect("list")
            .len(),
        1,
        "the other root's cursor is untouched"
    );

    let again = import_sessions(&store, &sb.claude_root, |_| {}).expect("import");
    assert_eq!(again.events_written, CLAUDE_EVENTS);
    assert_eq!(again.files_resumed, 0);
    assert_eq!(
        all_events(&store).len() as u64,
        2 * CLAUDE_EVENTS + CODEX_EVENTS
    );
}

#[test]
fn refresh_enriches_only_the_events_it_just_imported() {
    let sb = Sandbox::new();
    let store = sb.store();
    let roots = RefreshRoots {
        claude: Some(sb.claude_root.clone()),
        codex: Some(sb.codex_root.clone()),
    };

    let first = refresh(&store, None, Duration::from_secs(30), &roots);
    assert!(first.notes.is_empty(), "{:?}", first.notes);
    assert!(!first.deadline_hit);
    assert_eq!(first.last_event_id_before, 0);
    assert_eq!(first.new_events, CLAUDE_EVENTS + CODEX_EVENTS);
    assert_eq!(first.extracted, CLAUDE_EVENTS + CODEX_EVENTS);
    assert_eq!(first.segmented, CLAUDE_EVENTS + CODEX_EVENTS);
    assert!(first.episodes_created >= 1);
    assert_eq!(first.embedded, 0);
    assert!(!first.embedder_available);

    let second = refresh(&store, None, Duration::from_secs(30), &roots);
    assert_eq!(second.new_events, 0);
    assert_eq!(second.extracted, 0);
    assert_eq!(second.segmented, 0);
    assert_eq!(second.claude.files_unchanged, 1);

    Sandbox::append(
        &sb.claude_file(),
        "{\"type\":\"assistant\",\"cwd\":\"/Users/amy/demo\",\"sessionId\":\"sess-1\",\"gitBranch\":\"main\",\
         \"timestamp\":\"2026-09-25T10:40:00.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Ask Dana at Harborlane about the invoice.\"}]}}\n",
    );
    let embedder = FixedDimEmbedder::default();
    let third = refresh(&store, Some(&embedder), Duration::from_secs(30), &roots);
    assert_eq!(third.new_events, 1);
    assert_eq!(third.extracted, 1);
    assert_eq!(third.segmented, 1);
    assert_eq!(third.embedded, 1, "only the new event is embedded");
    assert!(third.embedder_available);
    assert_eq!(
        store.unembedded_events(100).expect("unembedded").len() as u64,
        CLAUDE_EVENTS + CODEX_EVENTS,
        "older events are left for embed-backfill, not this budgeted pass"
    );
    assert_eq!(store.unsegmented_events(100).expect("unsegmented").len(), 0);
}

#[test]
fn refresh_with_no_time_stops_early_and_the_next_run_finishes() {
    let sb = Sandbox::new();
    let store = sb.store();
    let roots = RefreshRoots {
        claude: Some(sb.claude_root.clone()),
        codex: Some(sb.codex_root.clone()),
    };
    let starved = refresh(&store, None, Duration::ZERO, &roots);
    assert!(starved.deadline_hit);
    assert_eq!(starved.stopped_at, Some(RefreshStage::ImportClaude));
    assert_eq!(starved.new_events, 0);
    assert!(starved
        .summary_line()
        .contains("budget spent during import claude-code"));

    let fed = refresh(&store, None, Duration::from_secs(30), &roots);
    assert!(!fed.deadline_hit);
    assert_eq!(fed.new_events, CLAUDE_EVENTS + CODEX_EVENTS);
}

#[test]
fn refresh_never_fails_on_a_missing_root() {
    let sb = Sandbox::new();
    let store = sb.store();
    let roots = RefreshRoots {
        claude: Some(sb.claude_root.join("does-not-exist")),
        codex: Some(sb.codex_root.clone()),
    };
    let stats = refresh(&store, None, Duration::from_secs(30), &roots);
    assert_eq!(stats.new_events, CODEX_EVENTS);
    assert_eq!(stats.notes.len(), 1);
    assert!(stats.notes[0].contains("no transcripts"));
    assert!(!stats.deadline_hit);
}

// ---------------------------------------------------------------------------
// The built binary.
// ---------------------------------------------------------------------------

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn agent(sb: &Sandbox, home: &Path) -> Command {
    let mut cmd = Command::new(agent_bin());
    cmd.env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", "aa".repeat(32))
        .env(
            "MCI_DB_KEYCHAIN_SERVICE",
            "ai.hippocampus.tests.import.missing",
        )
        .env("MCI_DB_KEYCHAIN_ACCOUNT", "never-created")
        .env("MCI_DB_KEYCHAIN_STORAGE_MODEL", "file-keychain-acl-v1")
        .env("MCI_EMBEDDER_DISABLED", "1")
        .arg("--db-path")
        .arg(&sb.db_path);
    cmd
}

#[test]
fn cli_import_sessions_is_incremental_and_full_reimports() {
    let sb = Sandbox::new();
    let home = TempDir::new().expect("home");
    let run = |extra: &[&str]| {
        let out = agent(&sb, home.path())
            .arg("import-sessions")
            .arg("--root")
            .arg(&sb.claude_root)
            .arg("--codex-root")
            .arg(&sb.codex_root)
            .args(extra)
            .output()
            .expect("spawn mci-agent");
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert!(out.status.success(), "stderr: {stderr}");
        stderr
    };

    let first = run(&[]);
    assert!(
        first.contains("claude-code: 6 events written (2 tool) from 1 file(s) read"),
        "{first}"
    );
    assert!(
        first.contains("codex: 6 events written (3 tool) from 1 file(s) read"),
        "{first}"
    );
    assert!(first.contains("1 subagent skipped"), "{first}");

    let second = run(&[]);
    assert!(
        second.contains(
            "claude-code: 0 events written (0 tool) from 0 file(s) read, 0 resumed, 1 unchanged"
        ),
        "{second}"
    );
    assert!(
        second.contains(
            "codex: 0 events written (0 tool) from 0 file(s) read, 0 resumed, 1 unchanged"
        ),
        "{second}"
    );

    let full = run(&["--full"]);
    assert!(full.contains("--full: forgot 1 cursor(s)"), "{full}");
    assert!(full.contains("claude-code: 6 events written"), "{full}");
    assert!(full.contains("codex: 6 events written"), "{full}");

    let store = sb.store();
    assert_eq!(
        all_events(&store).len() as u64,
        2 * (CLAUDE_EVENTS + CODEX_EVENTS)
    );
}

#[test]
fn cli_refresh_prints_one_summary_line_and_exits_zero() {
    let sb = Sandbox::new();
    // HOME is the sandbox, so the default roots do not exist: refresh must
    // still print its line and exit 0.
    let home = TempDir::new().expect("home");
    let out = agent(&sb, home.path())
        .arg("refresh")
        .arg("--budget-ms")
        .arg("2000")
        .output()
        .expect("spawn mci-agent");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "stderr: {stderr}");
    assert_eq!(stdout.lines().count(), 1, "stdout: {stdout}");
    assert!(stdout.starts_with("refresh: "), "{stdout}");
    assert!(stdout.contains("0 new"), "{stdout}");
    assert!(
        stdout.trim_end().ends_with("2 note(s) on stderr"),
        "{stdout}"
    );
    assert!(stderr.contains("no transcripts at"), "{stderr}");
    assert!(stderr.contains("no rollouts at"), "{stderr}");
}

#[test]
fn cli_refresh_skips_with_exit_zero_when_the_app_holds_the_lease() {
    use mci_agent::crash_recovery::{acquire_lock, lock_path_for_brain};
    let sb = Sandbox::new();
    let home = TempDir::new().expect("home");
    // This test process plays the running app: it holds the brain's writer
    // lease for the duration of the command.
    let (_outcome, lock) = acquire_lock(&lock_path_for_brain(&sb.db_path)).expect("hold lease");
    let out = agent(&sb, home.path())
        .arg("refresh")
        .output()
        .expect("spawn mci-agent");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        stdout.trim_end(),
        format!(
            "refresh: skipped, the Hippocampus app is importing in the background \
             (writer lease held by pid {})",
            std::process::id()
        )
    );
    assert!(
        !sb.db_path.exists(),
        "a skipped refresh must not create the brain"
    );
    lock.release().expect("release lease");
}

#[test]
fn help_describes_both_roots_and_refresh() {
    let out = Command::new(agent_bin())
        .arg("--help")
        .output()
        .expect("spawn mci-agent");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("refresh"), "{text}");
    assert!(text.contains("--codex-root DIR"), "{text}");
    assert!(text.contains("--full"), "{text}");
    assert!(text.contains("--budget-ms N"), "{text}");
    // The paragraphs this stream added carry no em dashes (older text may).
    for needle in [
        "import-sessions",
        "refresh",
        "--codex-root",
        "--full",
        "--budget-ms",
    ] {
        let para: String = text
            .lines()
            .skip_while(|l| !l.contains(needle))
            .take(6)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!para.contains('\u{2014}'), "em dash near {needle}: {para}");
    }
}
