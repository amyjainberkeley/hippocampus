//! `crash_recovery` — process-lifetime writer lease and crash detection.
//!
//! Cycle 8.44 audit breakage risk #3, wiring point #3 (post-crash
//! integrity check).
//!
//! # How it works
//!
//! On boot the agent calls [`acquire_lock`], which:
//!
//! 1. Opens the stable `.writer.lock` sibling and takes an exclusive,
//!    nonblocking advisory lock. The descriptor is retained for the
//!    complete writer lifetime, and the kernel releases it on process death.
//! 2. Reads the `.running` crash marker. Its presence means the previous
//!    lease owner did not complete a clean release, regardless of PID reuse.
//! 3. Writes the current PID to `.running` for diagnostics.
//!
//! [`RunLock::release`] removes only `.running`; `.writer.lock` is never
//! unlinked, because replacing an advisory-lock inode can let two processes
//! lock different files at the same path. Recall uses the same lease around
//! its complete mutation scope, so agent startup and delete/wipe are mutually
//! exclusive without a check/open race.
//!
//! # OS-purity note
//!
//! Locking uses the safe `rustix::fs::flock` wrapper. This is the same crate
//! the agent already uses for file locking and `getuid()`; no raw `unsafe`
//! call or new dependency is required.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Seek, Write};
use std::path::{Path, PathBuf};
use std::process;

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

#[cfg(unix)]
use rustix::fs::{flock, FlockOperation, OFlags};

/// Outcome of a successful [`acquire_lock`]. Distinguishes clean boot from
/// crash recovery so the caller can decide whether to run an extra integrity
/// check. A live writer is returned as [`LockError::WriterLeaseHeld`].
#[derive(Debug, PartialEq, Eq)]
pub enum LockAcquireOutcome {
    /// Fresh install / clean prior shutdown. No lock file existed.
    CleanBoot,
    /// A lock file existed but its PID is stale — the prior process
    /// crashed. The caller SHOULD run an extra `verify_integrity_on_boot`
    /// pass and (in a future PR) surface the crash to the menu-bar
    /// health indicator.
    UncleanShutdown {
        /// Diagnostic PID from the marker, or `None` when the marker was
        /// malformed. The advisory lease, not this value, is authoritative.
        stale_pid: Option<i32>,
    },
}

/// Exclusive agent writer lease. Keeping this value alive keeps the kernel
/// lock alive; dropping it after a crash simulation releases the lock but
/// deliberately leaves `.running` as unclean-shutdown evidence.
#[derive(Debug)]
pub struct RunLock {
    sentinel_path: PathBuf,
    _lease_file: File,
}

impl RunLock {
    /// Mark the current run clean and release the writer lease. The stable
    /// lease file remains on disk so future lockers always address one inode.
    pub fn release(self) -> Result<(), LockError> {
        remove_crash_marker(&self.sentinel_path)
    }

    /// Mark shutdown clean while retaining the advisory descriptor until the
    /// operating system tears down the process. This is the long-running
    /// agent's normal exit path: Tokio task/runtime teardown cannot outlive
    /// the writer lease, even after the main drain loop has completed.
    pub fn release_at_process_exit(self) -> Result<(), LockError> {
        remove_crash_marker(&self.sentinel_path)?;
        std::mem::forget(self);
        Ok(())
    }
}

fn remove_crash_marker(path: &Path) -> Result<(), LockError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(LockError::Io(error)),
    }
}

/// Errors from the lock-file helpers.
#[derive(Debug, thiserror::Error)]
pub enum LockError {
    /// I/O failure creating the parent dir, reading, or writing the
    /// lock file. The lock-file location is not user-facing, so the
    /// wrapped `io::Error` is sufficient.
    #[error("crash_recovery: lock file io: {0}")]
    Io(#[from] io::Error),
    /// Another cooperating process owns the kernel-enforced writer lease.
    #[error("crash_recovery: writer lease is held (owner pid: {owner_pid:?})")]
    WriterLeaseHeld {
        /// Best-effort diagnostic PID from `.running`. The lock itself is
        /// authoritative, so a missing or malformed marker still blocks.
        owner_pid: Option<i32>,
    },
}

enum CrashMarker {
    Absent,
    Present(Option<i32>),
}

/// Compute the default lock-file path:
/// `~/Library/Application Support/Hippocampus/.running`. Falls back to
/// `/tmp/.hippocampus.running` when `HOME` is unset (headless CI).
#[must_use]
pub fn default_lock_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/Hippocampus/.running")
}

/// Return the crash-marker path paired with a brain database. Production
/// stores under `Application Support/MCI` share the app-wide Hippocampus
/// marker; fixture/custom stores use a sibling marker.
#[must_use]
pub fn lock_path_for_brain(brain_path: &Path) -> PathBuf {
    let Some(parent) = brain_path.parent() else {
        return PathBuf::from(".running");
    };
    if parent.file_name().is_some_and(|name| name == "MCI") {
        return parent.parent().map_or_else(
            || parent.join(".running"),
            |support| support.join("Hippocampus/.running"),
        );
    }
    parent.join(".running")
}

/// Derive the stable advisory-lock path paired with a `.running` marker.
#[must_use]
pub fn writer_lease_path(run_lock_path: &Path) -> PathBuf {
    run_lock_path.with_file_name(".writer.lock")
}

/// Acquire the run-lock at `path`. The returned [`RunLock`] must remain alive
/// for every operation that can write the paired brain.
pub fn acquire_lock(path: &Path) -> Result<(LockAcquireOutcome, RunLock), LockError> {
    let lease_file = acquire_writer_lease(path)?;
    let outcome = match read_lock(path)? {
        CrashMarker::Absent => LockAcquireOutcome::CleanBoot,
        CrashMarker::Present(stale_pid) => LockAcquireOutcome::UncleanShutdown { stale_pid },
    };
    write_lock(path)?;
    Ok((
        outcome,
        RunLock {
            sentinel_path: path.to_owned(),
            _lease_file: lease_file,
        },
    ))
}

fn read_lock(path: &Path) -> Result<CrashMarker, LockError> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(CrashMarker::Present(s.trim().parse::<i32>().ok())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(CrashMarker::Absent),
        Err(e) => Err(LockError::Io(e)),
    }
}

#[cfg(unix)]
fn write_lock(path: &Path) -> Result<(), LockError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(
            i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
                .expect("open flags fit platform c_int"),
        )
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != rustix::process::getuid().as_raw()
        || metadata.nlink() != 1
    {
        return Err(LockError::Io(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "crash marker must be a current-user regular file with one link",
        )));
    }
    if metadata.mode() & 0o077 != 0 {
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    let secured = file.metadata()?;
    if secured.mode() & 0o077 != 0 {
        return Err(LockError::Io(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "crash marker permissions must be private",
        )));
    }
    file.rewind()?;
    file.set_len(0)?;
    write!(file, "{}", process::id())?;
    file.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn write_lock(path: &Path) -> Result<(), LockError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, process::id().to_string())?;
    Ok(())
}

#[cfg(unix)]
fn acquire_writer_lease(run_lock_path: &Path) -> Result<File, LockError> {
    let lease_path = writer_lease_path(run_lock_path);
    if let Some(parent) = lease_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if lease_path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(LockError::Io(io::Error::new(
            io::ErrorKind::InvalidData,
            "writer lease path must not be a symlink",
        )));
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(
            i32::try_from((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits())
                .expect("open flags fit platform c_int"),
        )
        .open(&lease_path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != rustix::process::getuid().as_raw()
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
    {
        return Err(LockError::Io(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "writer lease must be a private current-user regular file",
        )));
    }
    match flock(&file, FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(file),
        Err(error) if error == rustix::io::Errno::WOULDBLOCK => {
            let owner_pid = match read_lock(run_lock_path) {
                Ok(CrashMarker::Present(pid)) => pid,
                Ok(CrashMarker::Absent) | Err(_) => None,
            };
            Err(LockError::WriterLeaseHeld { owner_pid })
        }
        Err(error) => Err(LockError::Io(io::Error::from_raw_os_error(
            error.raw_os_error(),
        ))),
    }
}

#[cfg(not(unix))]
fn acquire_writer_lease(_run_lock_path: &Path) -> Result<File, LockError> {
    Err(LockError::Io(io::Error::new(
        io::ErrorKind::Unsupported,
        "process-lifetime writer lease is not implemented on this platform",
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;
    use tempfile::TempDir;

    fn tmp_lock() -> (TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested/.running");
        (dir, path)
    }

    #[test]
    fn clean_boot_when_no_lock_file() {
        let (_dir, path) = tmp_lock();
        let (outcome, lock) = acquire_lock(&path).expect("acquire");
        assert_eq!(outcome, LockAcquireOutcome::CleanBoot);
        assert!(path.exists(), "acquire_lock must create the file");
        let content = fs::read_to_string(&path).expect("read");
        assert_eq!(content, process::id().to_string());
        lock.release().expect("release");
    }

    #[test]
    fn unclean_shutdown_when_stale_pid() {
        let (_dir, path) = tmp_lock();
        // Pre-seed the lock with a PID that (almost certainly) does
        // not exist. PID `999_999_999` is above the POSIX max and
        // therefore always dead.
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "999999999").expect("seed");
        let (outcome, lock) = acquire_lock(&path).expect("acquire");
        assert_eq!(
            outcome,
            LockAcquireOutcome::UncleanShutdown {
                stale_pid: Some(999_999_999)
            }
        );
        // And now our PID owns the file.
        let content = fs::read_to_string(&path).expect("read");
        assert_eq!(content, process::id().to_string());
        lock.release().expect("release");
    }

    #[test]
    fn another_instance_running_when_pid_alive() {
        let (_dir, path) = tmp_lock();
        let (_outcome, first) = acquire_lock(&path).expect("first acquire");
        let error = acquire_lock(&path).expect_err("second acquire must fail");
        assert!(matches!(
            error,
            LockError::WriterLeaseHeld {
                owner_pid: Some(pid)
            } if pid == i32::try_from(process::id()).unwrap()
        ));
        first.release().expect("release");
    }

    #[test]
    fn release_lock_is_idempotent() {
        let (_dir, path) = tmp_lock();
        let (_outcome, lock) = acquire_lock(&path).expect("acquire");
        assert!(path.exists());
        fs::remove_file(&path).expect("simulate marker already removed");
        lock.release().expect("release missing marker");
        assert!(!path.exists());
    }

    #[test]
    fn garbage_lock_file_treated_as_unclean() {
        let (_dir, path) = tmp_lock();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "not-a-pid").expect("seed");
        let (outcome, lock) = acquire_lock(&path).expect("acquire");
        assert_eq!(
            outcome,
            LockAcquireOutcome::UncleanShutdown { stale_pid: None }
        );
        lock.release().expect("release");
    }

    #[test]
    fn writer_lease_is_a_stable_sibling_of_the_crash_marker() {
        let path = Path::new("/tmp/Hippocampus/.running");
        assert_eq!(
            writer_lease_path(path),
            PathBuf::from("/tmp/Hippocampus/.writer.lock")
        );
    }

    #[test]
    fn production_and_custom_brains_map_to_the_expected_marker() {
        assert_eq!(
            lock_path_for_brain(Path::new(
                "/Users/test/Library/Application Support/MCI/mci.sqlite"
            )),
            PathBuf::from("/Users/test/Library/Application Support/Hippocampus/.running")
        );
        assert_eq!(
            lock_path_for_brain(Path::new("/tmp/fixture/brain.sqlite")),
            PathBuf::from("/tmp/fixture/.running")
        );
    }

    #[test]
    fn a_held_writer_lease_blocks_a_second_agent() {
        let (_dir, path) = tmp_lock();
        let (_outcome, first) = acquire_lock(&path).expect("first agent acquires");

        let error = acquire_lock(&path).expect_err("second agent must be blocked");
        assert!(matches!(
            error,
            LockError::WriterLeaseHeld {
                owner_pid: Some(pid)
            } if pid == i32::try_from(process::id()).unwrap()
        ));

        first.release().expect("clean release");
    }

    #[test]
    #[cfg(unix)]
    fn recall_style_lease_without_a_pid_marker_blocks_agent_startup() {
        let (_dir, path) = tmp_lock();
        let lease_path = writer_lease_path(&path);
        fs::create_dir_all(lease_path.parent().expect("lease parent")).expect("create parent");
        let recall_lease = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(lease_path)
            .expect("open Recall-style lease");
        flock(&recall_lease, FlockOperation::NonBlockingLockExclusive)
            .expect("hold Recall-style lease");

        assert!(matches!(
            acquire_lock(&path),
            Err(LockError::WriterLeaseHeld { owner_pid: None })
        ));
    }

    #[test]
    #[cfg(unix)]
    fn unsafe_writer_lease_path_fails_closed() {
        let (dir, path) = tmp_lock();
        let lease_path = writer_lease_path(&path);
        fs::create_dir_all(lease_path.parent().expect("lease parent")).expect("create parent");
        let target = dir.path().join("unexpected-target");
        fs::write(&target, b"do not lock through this path").expect("write target");
        std::os::unix::fs::symlink(target, lease_path).expect("create symlink");

        let error = acquire_lock(&path).expect_err("symlink lease must be rejected");
        assert!(matches!(
            error,
            LockError::Io(error) if error.kind() == io::ErrorKind::InvalidData
        ));
    }

    #[test]
    #[cfg(unix)]
    fn crash_marker_symlink_is_rejected_without_truncating_its_target() {
        let (dir, path) = tmp_lock();
        fs::create_dir_all(path.parent().expect("marker parent")).expect("create parent");
        let target = dir.path().join("must-survive");
        fs::write(&target, b"sensitive target contents").expect("write target");
        std::os::unix::fs::symlink(&target, &path).expect("create marker symlink");

        acquire_lock(&path).expect_err("marker symlink must fail closed");

        assert_eq!(
            fs::read(&target).expect("read untouched target"),
            b"sensitive target contents"
        );
    }

    #[test]
    #[cfg(unix)]
    fn existing_crash_marker_is_made_private_before_publication() {
        let (_dir, path) = tmp_lock();
        fs::create_dir_all(path.parent().expect("marker parent")).expect("create parent");
        fs::write(&path, "999999999").expect("seed legacy marker");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
            .expect("set legacy marker mode");

        let (_outcome, lock) = acquire_lock(&path).expect("secure legacy marker");

        assert_eq!(
            fs::metadata(&path).expect("marker metadata").mode() & 0o777,
            0o600
        );
        lock.release().expect("clean release");
    }

    #[test]
    fn dropped_lease_is_recoverable_and_preserves_unclean_shutdown_evidence() {
        let (_dir, path) = tmp_lock();
        let (_outcome, first) = acquire_lock(&path).expect("first agent acquires");
        drop(first);

        let (outcome, second) = acquire_lock(&path).expect("kernel released dropped lease");
        assert_eq!(
            outcome,
            LockAcquireOutcome::UncleanShutdown {
                stale_pid: Some(i32::try_from(process::id()).unwrap())
            }
        );
        second.release().expect("clean release");
    }

    #[test]
    fn clean_release_removes_marker_but_keeps_stable_lease_inode() {
        let (_dir, path) = tmp_lock();
        let lease_path = writer_lease_path(&path);
        let (_outcome, lock) = acquire_lock(&path).expect("acquire");

        lock.release().expect("clean release");

        assert!(!path.exists(), "clean release removes crash evidence");
        assert!(
            lease_path.exists(),
            "advisory-lock inode must remain stable"
        );
        let (outcome, next) = acquire_lock(&path).expect("next clean boot");
        assert_eq!(outcome, LockAcquireOutcome::CleanBoot);
        next.release().expect("clean release");
    }

    #[test]
    fn process_death_releases_lease_but_leaves_crash_marker() {
        let (_dir, path) = tmp_lock();
        let ready_path = path.with_file_name("child-ready");
        let mut child = process::Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "crash_recovery::tests::child_holds_writer_lease",
                "--nocapture",
            ])
            .env("MCI_TEST_CHILD_LOCK_PATH", &path)
            .env("MCI_TEST_CHILD_READY_PATH", &ready_path)
            .stdout(process::Stdio::null())
            .stderr(process::Stdio::null())
            .spawn()
            .expect("spawn lock-holder child");

        for _ in 0..250 {
            if ready_path.exists() {
                break;
            }
            assert!(
                child.try_wait().expect("poll child").is_none(),
                "lock-holder child exited before publishing readiness"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(ready_path.exists(), "lock-holder child never became ready");
        assert!(matches!(
            acquire_lock(&path),
            Err(LockError::WriterLeaseHeld { .. })
        ));

        child.kill().expect("kill lock-holder child");
        let child_pid = i32::try_from(child.id()).expect("child pid fits i32");
        child.wait().expect("reap lock-holder child");

        let (outcome, recovered) = acquire_lock(&path).expect("kernel releases on process death");
        assert_eq!(
            outcome,
            LockAcquireOutcome::UncleanShutdown {
                stale_pid: Some(child_pid)
            }
        );
        recovered.release().expect("clean recovery release");
    }

    #[test]
    fn clean_marker_removal_does_not_release_process_lifetime_lease_early() {
        let (_dir, path) = tmp_lock();
        let ready_path = path.with_file_name("clean-child-ready");
        let mut child = process::Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "crash_recovery::tests::child_marks_clean_but_holds_process_lease",
                "--nocapture",
            ])
            .env("MCI_TEST_CLEAN_CHILD_LOCK_PATH", &path)
            .env("MCI_TEST_CLEAN_CHILD_READY_PATH", &ready_path)
            .stdout(process::Stdio::null())
            .stderr(process::Stdio::null())
            .spawn()
            .expect("spawn clean lock-holder child");

        for _ in 0..250 {
            if ready_path.exists() {
                break;
            }
            assert!(
                child.try_wait().expect("poll child").is_none(),
                "clean lock-holder child exited before readiness"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            ready_path.exists(),
            "clean lock-holder child never became ready"
        );
        assert!(!path.exists(), "child removed its clean-shutdown marker");
        assert!(matches!(
            acquire_lock(&path),
            Err(LockError::WriterLeaseHeld { owner_pid: None })
        ));

        child.kill().expect("kill clean lock-holder child");
        child.wait().expect("reap clean lock-holder child");
        let (outcome, acquired) = acquire_lock(&path).expect("lease released at process death");
        assert_eq!(outcome, LockAcquireOutcome::CleanBoot);
        acquired.release().expect("clean release");
    }

    #[test]
    fn child_holds_writer_lease() {
        let Some(path) = std::env::var_os("MCI_TEST_CHILD_LOCK_PATH") else {
            return;
        };
        let ready_path =
            std::env::var_os("MCI_TEST_CHILD_READY_PATH").expect("child ready path environment");
        let (_outcome, _lock) = acquire_lock(Path::new(&path)).expect("child acquires lease");
        fs::write(ready_path, b"ready").expect("publish child readiness");
        std::thread::sleep(Duration::from_secs(60));
    }

    #[test]
    fn child_marks_clean_but_holds_process_lease() {
        let Some(path) = std::env::var_os("MCI_TEST_CLEAN_CHILD_LOCK_PATH") else {
            return;
        };
        let ready_path = std::env::var_os("MCI_TEST_CLEAN_CHILD_READY_PATH")
            .expect("clean child ready path environment");
        let (_outcome, lock) = acquire_lock(Path::new(&path)).expect("child acquires lease");
        lock.release_at_process_exit()
            .expect("child marks shutdown clean");
        fs::write(ready_path, b"ready").expect("publish clean child readiness");
        std::thread::sleep(Duration::from_secs(60));
    }
}
