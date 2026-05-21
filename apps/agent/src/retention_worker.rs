//! Retention-purger daily cron — ADR-0017 §4.
//!
//! Reads `retention.json` (written by Swift `DiskRetentionStore`) on each
//! cycle, converts to [`RetentionConfig`], calls [`purge_once`]. Runs
//! once per `check_interval` (default 24 h). Same shutdown-channel
//! pattern as [`idle_batch`](crate::idle_batch) and
//! [`episode_worker`](crate::episode_worker).
//!
//! # Privacy invariants
//!
//! - DELETE only — worker never inserts rows.
//! - `retention.json` is the SOLE source of truth (user's onboarding
//!   choice, CSO-ratified per ADR-0017 §4).
//! - Safety floor: events younger than 1 hour are never purged
//!   (enforced in [`purge_once`]).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::retention_purger::{self, PurgeStats, RetentionConfig};
use mci_brain::SqlCipherBrainStore;
use serde::Deserialize;
use tokio::sync::watch;

/// Stats returned when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetentionWorkerStats {
    /// Total purge cycles run.
    pub cycles_run: u64,
    /// Total events deleted across all cycles.
    pub total_events_deleted: u64,
    /// Total vectors deleted across all cycles.
    pub total_vectors_deleted: u64,
    /// Total episodes deleted across all cycles.
    pub total_episodes_deleted: u64,
    /// Cycles that returned an error (logged, not fatal).
    pub cycle_errors: u64,
}

/// Errors the retention worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum RetentionWorkerError {
    /// A purge cycle failed fatally (join error).
    #[error("retention-worker: {0}")]
    Fatal(String),
}

#[derive(Deserialize)]
struct PersistedRetention {
    mode: String,
    days: Option<u64>,
}

/// Parse `retention.json` into a [`RetentionConfig`].
///
/// Missing file, unreadable file, or unrecognized mode all default to
/// [`RetentionConfig::Forever`] — the safest fallback (never deletes).
fn load_retention_config(path: &Path) -> RetentionConfig {
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(_) => return RetentionConfig::Forever,
    };
    let parsed: PersistedRetention = match serde_json::from_slice(&data) {
        Ok(p) => p,
        Err(_) => return RetentionConfig::Forever,
    };
    match parsed.mode.as_str() {
        "forever" => RetentionConfig::Forever,
        "thirtyDays" => RetentionConfig::Days(30),
        "sevenDays" => RetentionConfig::Days(7),
        "custom" => match parsed.days {
            Some(d) if d > 0 => RetentionConfig::Days(d),
            _ => RetentionConfig::Forever,
        },
        _ => RetentionConfig::Forever,
    }
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

/// Run the retention-purger daily loop.
///
/// On each cycle: reads `retention.json`, calls `purge_once`, sleeps
/// `check_interval`. Non-fatal purge errors are counted but do not
/// stop the loop. Exits cleanly on shutdown signal.
pub async fn run_retention_worker(
    store: Arc<SqlCipherBrainStore>,
    retention_json_path: PathBuf,
    check_interval: std::time::Duration,
    mut shutdown: watch::Receiver<bool>,
) -> Result<RetentionWorkerStats, RetentionWorkerError> {
    let mut stats = RetentionWorkerStats {
        cycles_run: 0,
        total_events_deleted: 0,
        total_vectors_deleted: 0,
        total_episodes_deleted: 0,
        cycle_errors: 0,
    };

    loop {
        if *shutdown.borrow() {
            break;
        }

        let config_path = retention_json_path.clone();
        let store_c = Arc::clone(&store);

        let result: Result<PurgeStats, _> = tokio::task::spawn_blocking(move || {
            let config = load_retention_config(&config_path);
            retention_purger::purge_once(&store_c, &config, now_us())
        })
        .await
        .map_err(|e| RetentionWorkerError::Fatal(e.to_string()))?;

        match result {
            Ok(ps) => {
                stats.cycles_run += 1;
                stats.total_events_deleted += ps.events_deleted;
                stats.total_vectors_deleted += ps.vectors_deleted;
                stats.total_episodes_deleted += ps.episodes_deleted;
                if ps.events_deleted > 0 {
                    eprintln!(
                        "mci-agent: retention purge: deleted {} events, {} vectors, {} episodes",
                        ps.events_deleted, ps.vectors_deleted, ps.episodes_deleted,
                    );
                }
            }
            Err(e) => {
                stats.cycle_errors += 1;
                eprintln!("mci-agent: retention purge error: {e}");
            }
        }

        tokio::select! {
            () = tokio::time::sleep(check_interval) => continue,
            _ = shutdown.changed() => break,
        }
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_forever_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"forever","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Forever);
    }

    #[test]
    fn load_thirty_days_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"thirtyDays","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Days(30));
    }

    #[test]
    fn load_seven_days_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"sevenDays","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Days(7));
    }

    #[test]
    fn load_custom_days_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"custom","days":14,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Days(14));
    }

    #[test]
    fn load_custom_no_days_defaults_forever() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"custom","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Forever);
    }

    #[test]
    fn missing_file_defaults_forever() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        assert_eq!(load_retention_config(&path), RetentionConfig::Forever);
    }

    #[test]
    fn malformed_json_defaults_forever() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Forever);
    }

    #[test]
    fn unknown_mode_defaults_forever() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"unknownMode","days":5,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(load_retention_config(&path), RetentionConfig::Forever);
    }

    #[test]
    fn worker_stats_default_values() {
        let s = RetentionWorkerStats {
            cycles_run: 0,
            total_events_deleted: 0,
            total_vectors_deleted: 0,
            total_episodes_deleted: 0,
            cycle_errors: 0,
        };
        assert_eq!(s.cycles_run, 0);
    }
}
