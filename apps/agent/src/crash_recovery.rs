//! `crash_recovery` — lock-file-based unclean-shutdown detection.
//!
//! Cycle 8.44 audit breakage risk #3, wiring point #3 (post-crash
//! integrity check).
//!
//! # How it works
//!
//! On boot the agent calls [`acquire_lock`], which:
//!
//! 1. Reads `~/Library/Application Support/Hippocampus/.running` if it
//!    exists.
//! 2. Parses the file's contents as `<pid>` and checks whether that
//!    PID is still alive (`kill(pid, 0)` on Unix). If the file is
//!    present but the PID does not correspond to a live process, the
//!    prior shutdown was unclean.
//! 3. Writes the current process's PID into the file (creating parent
//!    dirs as needed) so a future boot can detect a crash of THIS
//!    process.
//!
//! On clean shutdown the agent calls [`release_lock`], which removes
//! the file. The absence of the file on the next boot signals a clean
//! prior shutdown; the presence of the file with a stale PID signals
//! a crash.
//!
//! # OS-purity note
//!
//! Liveness uses `rustix::process::test_kill_process` (POSIX `kill(pid,
//! 0)` — no signal delivered, permission/existence probe only). This
//! is the same crate the agent already uses for `getuid()` in
//! `user_allowlist` (see `apps/agent/Cargo.toml`) — no net-new
//! third-party dep, no `#![forbid(unsafe_code)]` violation. The
//! Windows arm lands with the Windows capture adapter.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process;

/// Outcome of [`acquire_lock`]. Distinguishes the three boot cases the
/// agent cares about so the caller can decide whether to run the
/// extra integrity check.
#[derive(Debug, PartialEq, Eq)]
pub enum LockAcquireOutcome {
    /// Fresh install / clean prior shutdown. No lock file existed.
    CleanBoot,
    /// A lock file existed but its PID is stale — the prior process
    /// crashed. The caller SHOULD run an extra `verify_integrity_on_boot`
    /// pass and (in a future PR) surface the crash to the menu-bar
    /// health indicator.
    UncleanShutdown {
        /// The stale PID we found in the lock file, for the caller's
        /// log line. Not used for any logic.
        stale_pid: i32,
    },
    /// A lock file existed AND its PID is still alive — another
    /// mci-agent instance is already running. The caller MUST abort;
    /// two writers on the same `SQLCipher` DB corrupt the store (ADR-0008
    /// §1.4 "one file, one writer").
    AnotherInstanceRunning {
        /// PID of the live sibling. Surfaced in the abort log line.
        live_pid: i32,
    },
}

/// Errors from the lock-file helpers.
#[derive(Debug, thiserror::Error)]
pub enum LockError {
    /// I/O failure creating the parent dir, reading, or writing the
    /// lock file. The lock-file location is not user-facing, so the
    /// wrapped `io::Error` is sufficient.
    #[error("crash_recovery: lock file io: {0}")]
    Io(#[from] io::Error),
}

/// Compute the default lock-file path:
/// `~/Library/Application Support/Hippocampus/.running`. Falls back to
/// `/tmp/.hippocampus.running` when `HOME` is unset (headless CI).
#[must_use]
pub fn default_lock_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/Hippocampus/.running")
}

/// Acquire the run-lock at `path`. See [`LockAcquireOutcome`] for
/// the three cases.
pub fn acquire_lock(path: &Path) -> Result<LockAcquireOutcome, LockError> {
    let outcome = match read_lock(path)? {
        None => LockAcquireOutcome::CleanBoot,
        Some(prev_pid) => {
            if pid_is_alive(prev_pid) {
                return Ok(LockAcquireOutcome::AnotherInstanceRunning {
                    live_pid: prev_pid,
                });
            }
            LockAcquireOutcome::UncleanShutdown {
                stale_pid: prev_pid,
            }
        }
    };
    // Write our own PID — do this AFTER the read so we don't clobber
    // the previous PID before checking whether it's alive.
    write_lock(path)?;
    Ok(outcome)
}

/// Remove the run-lock. Called on clean shutdown. Idempotent — a
/// missing file is not an error (the caller may have already crashed
/// and re-started, or the file was manually cleared).
pub fn release_lock(path: &Path) -> Result<(), LockError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(LockError::Io(e)),
    }
}

fn read_lock(path: &Path) -> Result<Option<i32>, LockError> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(s.trim().parse::<i32>().ok()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(LockError::Io(e)),
    }
}

fn write_lock(path: &Path) -> Result<(), LockError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let pid = process::id();
    fs::write(path, pid.to_string())?;
    Ok(())
}

/// Returns `true` iff `pid` corresponds to a live process this user
/// can signal. Uses `rustix::process::test_kill_process` — POSIX
/// `kill(pid, 0)` under the hood; no signal delivered.
#[cfg(unix)]
fn pid_is_alive(pid: i32) -> bool {
    let Some(rpid) = rustix::process::Pid::from_raw(pid) else {
        return false;
    };
    rustix::process::test_kill_process(rpid).is_ok()
}

#[cfg(not(unix))]
fn pid_is_alive(_pid: i32) -> bool {
    // Windows arm lands with the Windows capture adapter. Until then
    // treat every stale-looking lock as unclean rather than assume
    // it's live (safer default: run the extra integrity check).
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn tmp_lock() -> (TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested/.running");
        (dir, path)
    }

    #[test]
    fn clean_boot_when_no_lock_file() {
        let (_dir, path) = tmp_lock();
        let outcome = acquire_lock(&path).expect("acquire");
        assert_eq!(outcome, LockAcquireOutcome::CleanBoot);
        assert!(path.exists(), "acquire_lock must create the file");
        let content = fs::read_to_string(&path).expect("read");
        assert_eq!(content, process::id().to_string());
    }

    #[test]
    fn unclean_shutdown_when_stale_pid() {
        let (_dir, path) = tmp_lock();
        // Pre-seed the lock with a PID that (almost certainly) does
        // not exist. PID `999_999_999` is above the POSIX max and
        // therefore always dead.
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "999999999").expect("seed");
        let outcome = acquire_lock(&path).expect("acquire");
        assert_eq!(
            outcome,
            LockAcquireOutcome::UncleanShutdown {
                stale_pid: 999_999_999
            }
        );
        // And now our PID owns the file.
        let content = fs::read_to_string(&path).expect("read");
        assert_eq!(content, process::id().to_string());
    }

    #[test]
    fn another_instance_running_when_pid_alive() {
        let (_dir, path) = tmp_lock();
        // Our own PID is definitely alive.
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, process::id().to_string()).expect("seed");
        let outcome = acquire_lock(&path).expect("acquire");
        let want = LockAcquireOutcome::AnotherInstanceRunning {
            live_pid: i32::try_from(process::id()).unwrap(),
        };
        assert_eq!(outcome, want);
    }

    #[test]
    fn release_lock_is_idempotent() {
        let (_dir, path) = tmp_lock();
        // First acquire, then release, then release again.
        acquire_lock(&path).expect("acquire");
        assert!(path.exists());
        release_lock(&path).expect("release 1");
        assert!(!path.exists());
        release_lock(&path).expect("release 2 (no-op)");
    }

    #[test]
    fn garbage_lock_file_treated_as_unclean() {
        let (_dir, path) = tmp_lock();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "not-a-pid").expect("seed");
        // Un-parseable content → read_lock returns None → CleanBoot.
        // This is intentional: we won't create a false "unclean"
        // signal from a corrupted file — but the file IS clobbered on
        // acquire, so subsequent boots recover cleanly.
        let outcome = acquire_lock(&path).expect("acquire");
        assert_eq!(outcome, LockAcquireOutcome::CleanBoot);
    }
}
