//! Helper-process supervisor scaffold.
//!
//! Per ADR-0007 the macOS Swift `mci-capture-helper` runs as a
//! separate signed child process. This module owns:
//!
//! - The spawn protocol (binary path + CLI args + env + inherited
//!   `AF_UNIX` socket fd — the fd-pass mechanics land cycle 3; this
//!   iteration scaffolds the [`HelperSpawnConfig`] shape).
//! - The crash-relaunch policy with exponential backoff (skeleton —
//!   cycle 3 wires it to a `tokio::process::Child`).
//! - The shutdown protocol (send `CaptureStop`, await ack, kill if
//!   helper does not exit within a grace window).
//!
//! **Crash-isolation note.** Per ADR-0007 §5, a helper crash is a
//! brief recording gap, never an agent crash. The supervisor logs the
//! exit + relaunches; the agent stays up so the recall UI + the
//! menu-bar shell stay accessible.
//!
//! **What this module does NOT do.** No live `SCStream` wiring (the
//! helper handles that). No `AF_UNIX` `socketpair(2)` fd passing yet
//! (cycle 3). No production async loop yet — this iteration locks the
//! types + the policy + the smoke tests so cycle 3 builds on them.

use std::path::PathBuf;
use std::time::Duration;

use thiserror::Error;

/// Errors the supervisor surfaces.
#[derive(Debug, Error)]
pub enum SupervisorError {
    /// The helper binary path is missing or not executable.
    #[error("helper binary not found / not executable: {0}")]
    HelperNotFound(PathBuf),
    /// Underlying process / I/O failure.
    #[error("supervisor io: {0}")]
    Io(#[from] std::io::Error),
}

/// Configuration for one helper spawn.
///
/// Held in the agent's startup config + passed to the supervisor's
/// `spawn` method (cycle 3). Owning the config in a typed struct lets
/// the tests construct fixtures deterministically.
#[derive(Debug, Clone)]
pub struct HelperSpawnConfig {
    /// Absolute path to the `mci-capture-helper` binary. In production
    /// this is the co-bundled binary the agent's resource resolver
    /// returns; in tests it's the `swift build` output.
    pub binary_path: PathBuf,

    /// Path to the user's denylist TOML. The helper reads this at
    /// start-up. Defaults to `~/Library/Application Support/MCI/denylist.toml`.
    pub denylist_path: PathBuf,

    /// Heartbeat interval the helper uses for `HelperHealth` emission.
    /// Default 30 s per the CRS telemetry-gap memo.
    pub heartbeat_seconds: u32,

    /// Path the helper should write IPC frames into. In cycle 3 this
    /// becomes an inherited fd; for the iter-6 scaffold it's a file
    /// path the helper's `--output` CLI flag honors.
    pub output_path: PathBuf,
}

impl HelperSpawnConfig {
    /// Validate that the binary exists and is executable.
    ///
    /// # Errors
    /// [`SupervisorError::HelperNotFound`] if the path is missing /
    /// not executable.
    pub fn validate(&self) -> Result<(), SupervisorError> {
        use std::os::unix::fs::PermissionsExt;

        let meta = std::fs::metadata(&self.binary_path)
            .map_err(|_| SupervisorError::HelperNotFound(self.binary_path.clone()))?;
        if !meta.is_file() {
            return Err(SupervisorError::HelperNotFound(self.binary_path.clone()));
        }
        let mode = meta.permissions().mode();
        if mode & 0o111 == 0 {
            // Not executable by anyone.
            return Err(SupervisorError::HelperNotFound(self.binary_path.clone()));
        }
        Ok(())
    }

    /// Render the CLI args this config produces. Matches the flags the
    /// Swift helper's `main.swift` parses today.
    #[must_use]
    pub fn cli_args(&self) -> Vec<String> {
        vec![
            "--output".to_string(),
            self.output_path.display().to_string(),
            "--denylist".to_string(),
            self.denylist_path.display().to_string(),
            "--heartbeat-seconds".to_string(),
            self.heartbeat_seconds.to_string(),
        ]
    }
}

/// Crash-relaunch policy — exponential backoff with a ceiling.
///
/// On the Nth consecutive crash within `reset_window`, wait
/// `min(base × 2^N, ceiling)` before relaunching. After a full
/// `reset_window` of healthy uptime the counter resets to 0.
///
/// Default: `base = 100 ms`, `ceiling = 30 s`, `reset_window = 60 s`.
#[derive(Debug, Clone, Copy)]
pub struct CrashBackoff {
    /// Base delay between crashes. Multiplied by `2^N` for the Nth
    /// consecutive crash.
    pub base: Duration,
    /// Maximum delay between crashes (the cap on `base × 2^N`).
    pub ceiling: Duration,
    /// Healthy-uptime window after which the consecutive-crash count
    /// resets to 0.
    pub reset_window: Duration,
}

impl CrashBackoff {
    /// Default policy.
    #[must_use]
    pub const fn default_policy() -> Self {
        Self {
            base: Duration::from_millis(100),
            ceiling: Duration::from_secs(30),
            reset_window: Duration::from_secs(60),
        }
    }

    /// Compute the delay to wait before the `crash_index`-th
    /// consecutive crash. `0` = first crash (just-launched), `1` =
    /// second consecutive crash, etc.
    #[must_use]
    pub fn delay_for(self, crash_index: u32) -> Duration {
        // `2^crash_index` — saturating into `ceiling`.
        let nanos: u128 = self
            .base
            .as_nanos()
            .saturating_mul(1_u128 << crash_index.min(31));
        let ceiling_nanos = self.ceiling.as_nanos();
        #[allow(clippy::cast_possible_truncation)]
        let bounded = nanos.min(ceiling_nanos) as u64;
        Duration::from_nanos(bounded)
    }
}

impl Default for CrashBackoff {
    fn default() -> Self {
        Self::default_policy()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn config_validate_rejects_missing_binary() {
        let cfg = HelperSpawnConfig {
            binary_path: PathBuf::from("/nope/does/not/exist"),
            denylist_path: PathBuf::from("/dev/null"),
            heartbeat_seconds: 30,
            output_path: PathBuf::from("/tmp/x"),
        };
        let err = cfg.validate().unwrap_err();
        assert!(matches!(err, SupervisorError::HelperNotFound(_)));
    }

    #[tokio::test]
    async fn config_validate_accepts_executable_file() {
        // /bin/sh is universally present + executable on macOS + every
        // POSIX target MCI will ever build for.
        let cfg = HelperSpawnConfig {
            binary_path: PathBuf::from("/bin/sh"),
            denylist_path: PathBuf::from("/dev/null"),
            heartbeat_seconds: 30,
            output_path: PathBuf::from("/tmp/x"),
        };
        cfg.validate().expect("sh is executable");
    }

    #[tokio::test]
    async fn config_validate_rejects_non_executable_file() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("notexec");
        tokio::fs::write(&p, "not a binary").await.unwrap();
        let mut perms = tokio::fs::metadata(&p).await.unwrap().permissions();
        perms.set_mode(0o600); // r/w but no x
        tokio::fs::set_permissions(&p, perms).await.unwrap();

        let cfg = HelperSpawnConfig {
            binary_path: p,
            denylist_path: PathBuf::from("/dev/null"),
            heartbeat_seconds: 30,
            output_path: PathBuf::from("/tmp/x"),
        };
        let err = cfg.validate().unwrap_err();
        assert!(matches!(err, SupervisorError::HelperNotFound(_)));
    }

    #[test]
    fn cli_args_shape() {
        let cfg = HelperSpawnConfig {
            binary_path: PathBuf::from("/bin/sh"),
            denylist_path: PathBuf::from("/tmp/denylist.toml"),
            heartbeat_seconds: 30,
            output_path: PathBuf::from("/tmp/out.bin"),
        };
        let args = cfg.cli_args();
        assert_eq!(
            args,
            vec![
                "--output".to_string(),
                "/tmp/out.bin".to_string(),
                "--denylist".to_string(),
                "/tmp/denylist.toml".to_string(),
                "--heartbeat-seconds".to_string(),
                "30".to_string(),
            ]
        );
    }

    #[test]
    fn backoff_starts_at_base() {
        let b = CrashBackoff::default_policy();
        assert_eq!(b.delay_for(0), Duration::from_millis(100));
    }

    #[test]
    fn backoff_doubles_each_index() {
        let b = CrashBackoff::default_policy();
        assert_eq!(b.delay_for(1), Duration::from_millis(200));
        assert_eq!(b.delay_for(2), Duration::from_millis(400));
        assert_eq!(b.delay_for(3), Duration::from_millis(800));
    }

    #[test]
    fn backoff_caps_at_ceiling() {
        let b = CrashBackoff::default_policy();
        // 2^20 × 100 ms = ~10⁵ s — should clamp at 30 s.
        assert_eq!(b.delay_for(20), Duration::from_secs(30));
        // Even a giant index doesn't overflow.
        assert_eq!(b.delay_for(31), Duration::from_secs(30));
    }
}
