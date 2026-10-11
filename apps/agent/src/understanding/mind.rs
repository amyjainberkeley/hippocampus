//! Client for `hippocampus-mind`, the on-device model process.
//!
//! One child process, started on first use, kept warm, restarted after a
//! timeout or crash. Requests and replies are JSON lines. The child gets only
//! `PATH` and `HOME`: no provider keys, no database key.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::Serialize;

/// The binary's name next to `mci-agent` in `Contents/MacOS`.
pub const MIND_BINARY: &str = "hippocampus-mind";

/// Why a call did not produce an answer.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum MindCallError {
    /// No binary, an OS older than macOS 26, or Apple Intelligence off.
    #[error("on-device model unavailable: {0}")]
    Unavailable(String),
    /// The input did not fit the model's window.
    #[error("input too long for the on-device model")]
    ContextTooLong,
    /// The model declined.
    #[error("the on-device model declined")]
    Refused,
    /// No reply in time; the child was stopped.
    #[error("the on-device model timed out")]
    Timeout,
    /// Anything else.
    #[error("on-device model failed: {0}")]
    Failed(String),
}

struct Session {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

enum State {
    NotStarted,
    Running(Session),
    /// Unavailable until `retry_at`; the reason is kept for callers.
    Unavailable { reason: String, retry_at: Instant },
}

/// A lazily started, self-healing connection to the mind process.
pub struct MindClient {
    path: Option<PathBuf>,
    state: Mutex<State>,
    next_id: std::sync::atomic::AtomicU64,
}

impl MindClient {
    /// Use `MCI_MIND_PATH`, else the binary beside the running executable.
    #[must_use]
    pub fn locate() -> Self {
        let path = std::env::var_os("MCI_MIND_PATH")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::current_exe()
                    .ok()
                    .and_then(|exe| exe.parent().map(|dir| dir.join(MIND_BINARY)))
            })
            .filter(|path| path.is_file());
        Self::new(path)
    }

    /// A client for a specific binary (`None`: always unavailable).
    #[must_use]
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            state: Mutex::new(State::NotStarted),
            next_id: std::sync::atomic::AtomicU64::new(1),
        }
    }

    /// The binary in use, if found.
    #[must_use]
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Start the child if needed and report whether the model is usable.
    ///
    /// # Errors
    /// [`MindCallError::Unavailable`] with the reason.
    pub fn ensure_available(&self) -> Result<(), MindCallError> {
        let mut state = self.state.lock().expect("mind state poisoned");
        self.ensure_running(&mut state).map(|_| ())
    }

    fn ensure_running<'a>(&self, state: &'a mut State) -> Result<&'a mut Session, MindCallError> {
        if let State::Unavailable { reason, retry_at } = &*state {
            if Instant::now() < *retry_at {
                return Err(MindCallError::Unavailable(reason.clone()));
            }
            *state = State::NotStarted;
        }
        if matches!(state, State::NotStarted) {
            match self.start() {
                Ok(session) => *state = State::Running(session),
                Err(reason) => {
                    // An unavailable model rarely changes; check again later.
                    *state = State::Unavailable {
                        reason: reason.clone(),
                        retry_at: Instant::now() + Duration::from_secs(30 * 60),
                    };
                    return Err(MindCallError::Unavailable(reason));
                }
            }
        }
        match state {
            State::Running(session) => Ok(session),
            _ => unreachable!("state set above"),
        }
    }

    fn start(&self) -> Result<Session, String> {
        let path = self.path.as_ref().ok_or_else(|| "not_installed".to_owned())?;
        let mut command = Command::new(path);
        command
            .arg("--serve")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(home) = std::env::var_os("HOME") {
            command.env("HOME", home);
        }
        let mut child = command.spawn().map_err(|_| "cannot_launch".to_owned())?;
        let stdin = child.stdin.take().ok_or("no_stdin")?;
        let stdout = child.stdout.take().ok_or("no_stdout")?;
        let (sender, lines) = mpsc::channel();
        std::thread::Builder::new()
            .name("mind-reader".into())
            .spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    match line {
                        Ok(line) => {
                            if sender.send(line).is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
            })
            .map_err(|_| "cannot_read".to_owned())?;
        let session = Session { child, stdin, lines };
        let ready = session
            .lines
            .recv_timeout(Duration::from_secs(20))
            .map_err(|_| "no_ready_line".to_owned())?;
        let value: serde_json::Value =
            serde_json::from_str(&ready).map_err(|_| "bad_ready_line".to_owned())?;
        if value["ready"] != true {
            return Err("bad_ready_line".into());
        }
        if value["available"] != true {
            return Err(value["reason"].as_str().unwrap_or("unavailable").to_owned());
        }
        Ok(session)
    }

    /// Run one task. The child is restarted on the next call after a timeout
    /// or crash.
    ///
    /// # Errors
    /// See [`MindCallError`].
    pub fn call<I: Serialize, O: DeserializeOwned>(
        &self,
        task: &str,
        input: &I,
        timeout: Duration,
    ) -> Result<O, MindCallError> {
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let request = serde_json::json!({ "id": id, "task": task, "input": input });
        let mut line = serde_json::to_vec(&request)
            .map_err(|_| MindCallError::Failed("encode".into()))?;
        line.push(b'\n');
        let mut state = self.state.lock().expect("mind state poisoned");
        let session = self.ensure_running(&mut state)?;
        if session.stdin.write_all(&line).and_then(|()| session.stdin.flush()).is_err() {
            *state = State::NotStarted;
            return Err(MindCallError::Failed("the model process exited".into()));
        }
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match session.lines.recv_timeout(remaining) {
                Ok(reply) => {
                    let value: serde_json::Value = match serde_json::from_str(&reply) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if value["id"].as_u64() != Some(id) {
                        // A late reply to an earlier, abandoned request.
                        continue;
                    }
                    if value["ok"] == true {
                        return serde_json::from_value(value["output"].clone())
                            .map_err(|_| MindCallError::Failed("unexpected output".into()));
                    }
                    return Err(match value["error"].as_str().unwrap_or("failed") {
                        "unavailable" => MindCallError::Unavailable("unavailable".into()),
                        "context_too_long" => MindCallError::ContextTooLong,
                        "refused" => MindCallError::Refused,
                        other => MindCallError::Failed(other.to_owned()),
                    });
                }
                Err(RecvTimeoutError::Timeout) => {
                    *state = State::NotStarted;
                    return Err(MindCallError::Timeout);
                }
                Err(RecvTimeoutError::Disconnected) => {
                    *state = State::NotStarted;
                    return Err(MindCallError::Failed("the model process exited".into()));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fake_mind(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("fake-mind");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[test]
    fn a_missing_binary_is_unavailable() {
        let client = MindClient::new(None);
        assert_eq!(
            client.ensure_available(),
            Err(MindCallError::Unavailable("not_installed".into()))
        );
    }

    #[test]
    fn an_unavailable_model_reports_its_reason() {
        let dir = tempfile::tempdir().unwrap();
        let path = fake_mind(dir.path(), r#"echo '{"ready":true,"available":false,"reason":"apple_intelligence_off"}'; cat >/dev/null"#);
        let client = MindClient::new(Some(path));
        assert_eq!(
            client.ensure_available(),
            Err(MindCallError::Unavailable("apple_intelligence_off".into()))
        );
    }

    #[test]
    fn replies_are_matched_by_id_and_errors_are_mapped() {
        let dir = tempfile::tempdir().unwrap();
        // Echo a canned reply carrying the request's id (assumed 1, then 2).
        let path = fake_mind(
            dir.path(),
            r#"echo '{"ready":true,"available":true}'
read line; echo '{"id":1,"ok":true,"output":{"title":"T","surface":"S","beneath":"B"}}'
read line; echo '{"id":2,"ok":false,"error":"context_too_long"}'
read line; sleep 5"#,
        );
        let client = MindClient::new(Some(path));
        let out: serde_json::Value = client
            .call("episode", &serde_json::json!({}), Duration::from_secs(5))
            .unwrap();
        assert_eq!(out["title"], "T");
        let err = client
            .call::<_, serde_json::Value>("episode", &serde_json::json!({}), Duration::from_secs(5))
            .unwrap_err();
        assert_eq!(err, MindCallError::ContextTooLong);
        let started = Instant::now();
        let err = client
            .call::<_, serde_json::Value>("episode", &serde_json::json!({}), Duration::from_millis(300))
            .unwrap_err();
        assert_eq!(err, MindCallError::Timeout);
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
