//! `mci-agent` never panics when the reader of its stdout or stderr has gone.
//!
//! Rust ignores `SIGPIPE`, so a write to a pipe with no reader fails with
//! `EPIPE`, and `println!`/`eprintln!` turn that failure into a panic. The
//! audit found 23 crash records of exactly that ("failed printing to stderr:
//! Broken pipe") from runs an MCP client or a hook had started. Each test
//! hands the built binary a pipe whose reader has already exited, in a mode
//! that runs for a long time or that clients start, and checks the exit code
//! and that no crash record was written.
//!
//! Every child runs with an explicitly built environment: a throwaway home,
//! a synthetic brain and the development key gate, never the Keychain.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

const KEY_HEX: &str = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";
/// What a Rust process exits with when it panics.
const PANIC_EXIT: i32 = 101;

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

/// Pipes and child processes are made one at a time. macOS has no
/// `pipe2`, so std marks a new pipe close-on-exec only after making it; a
/// child another test starts in that gap inherits the pipe, keeps a reader
/// open, and the write that must fail succeeds.
static SPAWNING: Mutex<()> = Mutex::new(());

fn one_at_a_time() -> std::sync::MutexGuard<'static, ()> {
    SPAWNING.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Start `command`, making no pipe or child while another test does.
fn spawn(command: &mut Command) -> Child {
    let _turn = one_at_a_time();
    command.spawn().expect("spawn mci-agent")
}

/// The write end of a pipe whose only reader has exited. Writing to it
/// fails with `EPIPE`; the test checks that before handing it over.
fn closed_pipe() -> Stdio {
    let _turn = one_at_a_time();
    let mut reader = Command::new("/usr/bin/true")
        .stdin(Stdio::piped())
        .spawn()
        .expect("spawn a reader that exits at once");
    let mut write_end: ChildStdin = reader.stdin.take().expect("pipe to the reader");
    reader.wait().expect("reader exits");
    let error = write_end
        .write_all(b"x")
        .expect_err("a pipe with no reader refuses writes");
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    Stdio::from(write_end)
}

/// A throwaway home with a synthetic, empty brain in it.
struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("temp home");
        let brain = dir.path().join("brain.sqlite");
        let key = DbKey::from_bytes([0x5a; 32]);
        drop(SqlCipherBrainStore::new(&brain, &key).expect("synthetic brain"));
        Self { dir }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn brain(&self) -> PathBuf {
        self.dir.path().join("brain.sqlite")
    }

    fn crash_record(&self) -> PathBuf {
        self.dir.path().join("Library/Logs/MCI/panic.jsonl")
    }

    fn agent(&self) -> Command {
        let mut command = Command::new(agent_bin());
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", self.path())
            .env("MCI_DEVELOPMENT_FILE_KEY", "1")
            .env("MCI_DB_KEY_HEX", KEY_HEX)
            // The daemon's model worker is not under test here.
            .env("MCI_UNDERSTANDING", "0");
        command
    }

    /// The exit status was not a panic, and no crash record was written.
    fn assert_no_panic(&self, status: ExitStatus, what: &str) {
        assert_ne!(status.code(), Some(PANIC_EXIT), "{what} panicked");
        let record = std::fs::read_to_string(self.crash_record()).unwrap_or_default();
        assert!(record.is_empty(), "{what} left a crash record: {record}");
    }
}

fn wait(mut child: Child, limit: Duration) -> ExitStatus {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().expect("poll child") {
            return status;
        }
        if started.elapsed() > limit {
            let _ = child.kill();
            panic!("mci-agent did not finish within {limit:?}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

const MCP_REQUESTS: &str = concat!(
    r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
    "\n",
    r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
    "\n",
    r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mci_stats","arguments":{}}}"#,
    "\n",
);

#[test]
fn the_mcp_server_answers_and_exits_cleanly_when_stderr_has_no_reader() {
    let home = Home::new();
    let mut child = spawn(
        home.agent()
            .args(["mcp-serve", "--db-path"])
            .arg(home.brain())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(closed_pipe()),
    );
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(MCP_REQUESTS.as_bytes())
        .expect("send requests");
    let mut stdout = String::new();
    child
        .stdout
        .take()
        .expect("stdout")
        .read_to_string(&mut stdout)
        .expect("read responses");
    let status = wait(child, Duration::from_secs(60));

    home.assert_no_panic(status, "mcp-serve with a closed stderr");
    assert!(status.success(), "mcp-serve exits 0 at EOF: {status:?}");
    let ids: Vec<i64> = stdout
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).expect("one JSON reply"))
        .map(|reply| reply["id"].as_i64().expect("reply id"))
        .collect();
    assert_eq!(ids, vec![1, 2, 3], "every request answered: {stdout}");
    assert!(
        stdout.lines().all(|line| !line.contains("\"error\"")),
        "every request succeeded: {stdout}"
    );
}

#[test]
fn the_mcp_server_ends_quietly_when_its_client_closes_stdout() {
    let home = Home::new();
    let mut child = spawn(
        home.agent()
            .args(["mcp-serve", "--db-path"])
            .arg(home.brain())
            .stdin(Stdio::piped())
            .stdout(closed_pipe())
            .stderr(closed_pipe()),
    );
    // The write may fail once the server has gone; that is the point.
    let _ = child
        .stdin
        .take()
        .expect("stdin")
        .write_all(MCP_REQUESTS.as_bytes());
    let status = wait(child, Duration::from_secs(60));

    home.assert_no_panic(status, "mcp-serve with a closed stdout");
    assert!(
        status.success(),
        "a client that went away ends the session like EOF: {status:?}"
    );
}

#[test]
fn the_capture_daemon_drains_and_exits_cleanly_when_stderr_has_no_reader() {
    let home = Home::new();
    let child = spawn(
        home.agent()
            .env("MCI_CAPTURE_ENABLED", "0")
            .arg("--device-id-path")
            .arg(home.path().join("device-id"))
            .arg("--log-path")
            .arg(home.path().join("helper-health.jsonl"))
            .arg("--db-path")
            .arg(home.brain())
            .arg("--drain-stdin")
            .stdin(Stdio::null())
            .stdout(closed_pipe())
            .stderr(closed_pipe()),
    );
    let status = wait(child, Duration::from_secs(120));

    home.assert_no_panic(status, "the daemon with closed stdout and stderr");
    assert!(
        status.success(),
        "the daemon drains EOF and exits 0: {status:?}"
    );
}

#[test]
fn the_session_hook_exits_zero_when_nobody_reads_its_output() {
    let home = Home::new();
    let mut child = spawn(
        home.agent()
            .args([
                "handoff",
                "--format",
                "claude-hook",
                "--no-refresh",
                "--db-path",
            ])
            .arg(home.brain())
            .stdin(Stdio::piped())
            .stdout(closed_pipe())
            .stderr(closed_pipe()),
    );
    // Claude Code sends the hook a JSON object; its fields are logged to
    // stderr, which has no reader.
    let _ = child
        .stdin
        .take()
        .expect("stdin")
        .write_all(br#"{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}"#);
    let status = wait(child, Duration::from_secs(60));

    home.assert_no_panic(status, "the session hook");
    assert!(status.success(), "a hook always exits 0: {status:?}");
}

#[test]
fn a_one_shot_command_exits_zero_when_stdout_has_no_reader() {
    let home = Home::new();
    let child = spawn(
        home.agent()
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(closed_pipe())
            .stderr(closed_pipe()),
    );
    let status = wait(child, Duration::from_secs(30));

    home.assert_no_panic(status, "--version");
    assert!(status.success(), "{status:?}");
}
