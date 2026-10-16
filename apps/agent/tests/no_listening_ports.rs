//! No agent process listens on a TCP port (launch plan item 9, D29:
//! `lsof -nP -iTCP -sTCP:LISTEN` with Hippocampus running shows none of its
//! processes). The MCP server talks over stdin and stdout, the daemon reads
//! the capture helper's frames from a pipe, and the browser extension's
//! host reaches it over a Unix socket in the user's own folder.
//!
//! Each long-running mode of the built `mci-agent` is started against a
//! synthetic memory in a throwaway home and asked, while it runs, which TCP
//! sockets it listens on. The control first shows that the same `lsof`
//! question finds a listener when there is one.
//!
//! One test, run in order: a child started while another test made a
//! socket could inherit it, and then show a listener that is not its own.
#![cfg(target_os = "macos")]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

const KEY_HEX: &str = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";
const LSOF: &str = "/usr/sbin/lsof";

fn agent_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mci-agent"))
}

/// The TCP sockets `pid` listens on, one `lsof` line each.
fn listening(pid: u32) -> Vec<String> {
    let output = Command::new(LSOF)
        .args(["-nP", "-a", "-p", &pid.to_string(), "-iTCP", "-sTCP:LISTEN"])
        .env_clear()
        .stdin(Stdio::null())
        .output()
        .expect("run lsof");
    // lsof exits 1 when it finds nothing; anything else is a broken check.
    assert!(
        output.status.success() || output.status.code() == Some(1),
        "lsof failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .skip(1) // the header
        .map(str::to_owned)
        .collect()
}

/// A throwaway home with a synthetic, empty memory in it.
struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    /// Under /tmp: the daemon's Unix socket lives in the home, and a socket
    /// path may be at most 104 bytes on macOS, which a home in the per-user
    /// temporary folder passes.
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("hl")
            .tempdir_in("/tmp")
            .expect("temp home");
        let key = DbKey::from_bytes([0x5a; 32]);
        drop(SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).expect("memory"));
        Self { dir }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn brain(&self) -> PathBuf {
        self.dir.path().join("brain.sqlite")
    }

    fn agent(&self) -> Command {
        let mut command = Command::new(agent_bin());
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", self.path())
            .env("MCI_DEVELOPMENT_FILE_KEY", "1")
            .env("MCI_DB_KEY_HEX", KEY_HEX)
            .env("MCI_UNDERSTANDING", "0")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
}

/// The child's lines on `pipe`, as they come.
fn lines(pipe: impl std::io::Read + Send + 'static) -> mpsc::Receiver<String> {
    let (send, receive) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(pipe).lines().map_while(Result::ok) {
            if send.send(line).is_err() {
                break;
            }
        }
    });
    receive
}

/// Wait for a line containing `marker`, failing with what came instead.
fn wait_for(lines: &mpsc::Receiver<String>, marker: &str, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut seen = Vec::new();
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match lines.recv_timeout(left) {
            Ok(line) if line.contains(marker) => return,
            Ok(line) => seen.push(line),
            Err(_) => break,
        }
    }
    panic!("{what} never said {marker:?}; it said: {seen:#?}");
}

/// Ask `lsof` about `child` a few times while it runs; it must never list a
/// listening TCP socket.
fn assert_listens_on_nothing(child: &mut Child, what: &str) {
    for _ in 0..3 {
        assert!(
            child.try_wait().expect("poll").is_none(),
            "{what} exited before it could be checked"
        );
        let found = listening(child.id());
        assert!(found.is_empty(), "{what} listens on a TCP port: {found:#?}");
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn finish(mut child: Child, what: &str) {
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(60);
    while child.try_wait().expect("poll").is_none() {
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("{what} did not exit once its input closed");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn no_agent_process_listens_on_a_tcp_port() {
    // The control: a listener this process holds is found.
    let control = std::net::TcpListener::bind("127.0.0.1:0").expect("bind a control listener");
    let port = control.local_addr().expect("control address").port();
    let found = listening(std::process::id());
    assert!(
        found.iter().any(|line| line.contains(&format!(":{port}"))),
        "lsof did not find the control listener on {port}: {found:#?}"
    );
    drop(control);

    let home = Home::new();
    for (what, assist) in [("mcp-serve", false), ("mcp-serve --assist", true)] {
        let mut command = home.agent();
        command.arg("mcp-serve");
        if assist {
            command.arg("--assist");
        }
        let mut child = command
            .arg("--db-path")
            .arg(home.brain())
            .spawn()
            .expect("spawn mcp-serve");
        let replies = lines(child.stdout.take().expect("stdout"));
        let _stderr = lines(child.stderr.take().expect("stderr"));
        child
            .stdin
            .as_mut()
            .expect("stdin")
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n")
            .expect("send initialize");
        wait_for(&replies, "\"serverInfo\"", what);
        assert_listens_on_nothing(&mut child, what);
        finish(child, what);
    }

    // The daemon with capture on: every worker it starts, the extension's
    // Unix socket (the last thing it opens before reading frames) and the
    // MCP aggregator included.
    let mut daemon = home
        .agent()
        .env("MCI_CAPTURE_ENABLED", "1")
        .arg("--device-id-path")
        .arg(home.path().join("device-id"))
        .arg("--log-path")
        .arg(home.path().join("helper-health.jsonl"))
        .arg("--db-path")
        .arg(home.brain())
        .arg("--drain-stdin")
        .spawn()
        .expect("spawn the daemon");
    let _stdout = lines(daemon.stdout.take().expect("stdout"));
    let log = lines(daemon.stderr.take().expect("stderr"));
    wait_for(&log, "page-content listener on", "the daemon");
    assert_listens_on_nothing(&mut daemon, "the daemon");
    finish(daemon, "the daemon");
}
