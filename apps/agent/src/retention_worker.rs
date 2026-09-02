//! Retention-purger daily cron — ADR-0017 §4.
//!
//! Reads `retention.json` (written by Swift `DiskRetentionStore`) on each
//! cycle, converts to [`RetentionConfig`], calls [`purge_once`], and
//! reconciles encrypted keyframe blobs even when retention is `forever`. Runs
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
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mci_brain::retention_purger::{self, PurgeStats, RetentionConfig};
use mci_brain::{BlobReconciliationStats, SqlCipherBrainStore, StoreError};
use serde::Deserialize;
use tokio::sync::watch;

const ORPHAN_GRACE: Duration = Duration::from_secs(3_600);

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
    /// Referenced expired keyframe blobs removed across all cycles.
    pub total_blobs_deleted: u64,
    /// Crash-orphaned canonical blobs removed across all cycles.
    pub total_orphaned_blobs_deleted: u64,
    /// Crash-left temporary blob files removed across all cycles.
    pub total_stale_temporary_files_deleted: u64,
    /// Live database references whose expected blob was absent in the latest cycle.
    pub referenced_blobs_missing_last: u64,
    /// Per-entry blob cleanup errors observed across all cycles.
    pub total_blob_cleanup_errors: u64,
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

/// Errors while reading the user-owned retention policy.
#[derive(Debug, thiserror::Error)]
pub enum RetentionConfigError {
    /// The policy file exists but could not be read.
    #[error("could not read retention configuration at {}: {source}", path.display())]
    Read {
        /// Location of the unreadable configuration file.
        path: PathBuf,
        /// Filesystem error returned while reading the file.
        #[source]
        source: std::io::Error,
    },
    /// The policy file exists but is not valid JSON.
    #[error("malformed retention configuration at {}: {source}", path.display())]
    Malformed {
        /// Location of the malformed configuration file.
        path: PathBuf,
        /// JSON parsing error returned for the file contents.
        #[source]
        source: serde_json::Error,
    },
    /// The persisted policy uses a mode this agent does not understand.
    #[error("unknown retention mode {mode:?} at {}", path.display())]
    UnknownMode {
        /// Location of the unsupported configuration file.
        path: PathBuf,
        /// Persisted mode value that this agent does not recognize.
        mode: String,
    },
    /// A custom policy is missing a valid finite duration.
    #[error("invalid custom retention duration {days:?} at {}", path.display())]
    InvalidCustomDays {
        /// Location of the invalid configuration file.
        path: PathBuf,
        /// Missing or out-of-range persisted duration.
        days: Option<u64>,
    },
}

/// Errors that prevent a retention cycle from running.
#[derive(Debug, thiserror::Error)]
pub enum RetentionCycleError {
    /// The user-owned retention configuration could not be trusted.
    #[error("retention configuration unavailable: {0}")]
    Configuration(#[from] RetentionConfigError),
    /// The encrypted store could not complete the cycle.
    #[error("retention store failure: {0}")]
    Store(#[from] StoreError),
}

#[derive(Deserialize)]
struct PersistedRetention {
    mode: String,
    days: Option<u64>,
}

/// Parse `retention.json` into a [`RetentionConfig`].
///
/// A missing file is the deliberate fresh-install default of
/// [`RetentionConfig::Forever`]. Any existing but unreadable, malformed, or
/// unsupported file is an error: the worker must not silently reinterpret a
/// user's finite retention policy as `forever`.
pub fn load_retention_config(path: &Path) -> Result<RetentionConfig, RetentionConfigError> {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => {
            return Ok(RetentionConfig::Forever);
        }
        Err(source) => {
            return Err(RetentionConfigError::Read {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    let parsed: PersistedRetention =
        serde_json::from_slice(&data).map_err(|source| RetentionConfigError::Malformed {
            path: path.to_path_buf(),
            source,
        })?;
    match parsed.mode.as_str() {
        "forever" => Ok(RetentionConfig::Forever),
        "thirtyDays" => Ok(RetentionConfig::Days(30)),
        "sevenDays" => Ok(RetentionConfig::Days(7)),
        "custom" => match parsed.days {
            Some(days) if (1..=365).contains(&days) => Ok(RetentionConfig::Days(days)),
            days => Err(RetentionConfigError::InvalidCustomDays {
                path: path.to_path_buf(),
                days,
            }),
        },
        _ => Err(RetentionConfigError::UnknownMode {
            path: path.to_path_buf(),
            mode: parsed.mode,
        }),
    }
}

fn now_us() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros(),
    )
    .unwrap_or(u64::MAX)
}

/// Apply the current event-retention policy and independently reconcile the
/// encrypted keyframe directory. Reconciliation runs even in `forever` mode.
pub fn run_retention_cycle(
    store: &SqlCipherBrainStore,
    retention_json_path: &Path,
    orphan_grace: Duration,
    current_time_us: u64,
) -> Result<(PurgeStats, BlobReconciliationStats), RetentionCycleError> {
    let config = load_retention_config(retention_json_path)?;
    let purge = retention_purger::purge_once(store, &config, current_time_us)?;
    let blobs = store.reconcile_keyframe_blobs(orphan_grace)?;
    Ok((purge, blobs))
}

/// Run the retention-purger daily loop.
///
/// On each cycle: reads `retention.json`, purges expired rows and referenced
/// blobs, reconciles crash orphans after a one-hour grace period, then sleeps
/// `check_interval`. Non-fatal errors are counted but do not stop the loop.
/// Exits cleanly on shutdown signal.
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
        total_blobs_deleted: 0,
        total_orphaned_blobs_deleted: 0,
        total_stale_temporary_files_deleted: 0,
        referenced_blobs_missing_last: 0,
        total_blob_cleanup_errors: 0,
        cycle_errors: 0,
    };

    loop {
        if *shutdown.borrow() {
            break;
        }

        let config_path = retention_json_path.clone();
        let store_c = Arc::clone(&store);

        let result: Result<(PurgeStats, BlobReconciliationStats), _> =
            tokio::task::spawn_blocking(move || {
                run_retention_cycle(&store_c, &config_path, ORPHAN_GRACE, now_us())
            })
            .await
            .map_err(|e| RetentionWorkerError::Fatal(e.to_string()))?;

        match result {
            Ok((ps, blobs)) => {
                stats.cycles_run += 1;
                stats.total_events_deleted += ps.events_deleted;
                stats.total_vectors_deleted += ps.vectors_deleted;
                stats.total_episodes_deleted += ps.episodes_deleted;
                stats.total_blobs_deleted += ps.blobs_deleted;
                stats.total_orphaned_blobs_deleted += blobs.orphaned_blobs_deleted;
                stats.total_stale_temporary_files_deleted += blobs.stale_temporary_files_deleted;
                stats.referenced_blobs_missing_last = blobs.referenced_blobs_missing;
                stats.total_blob_cleanup_errors += blobs.cleanup_errors;
                if ps.events_deleted > 0
                    || ps.blobs_deleted > 0
                    || blobs.orphaned_blobs_deleted > 0
                    || blobs.stale_temporary_files_deleted > 0
                    || blobs.referenced_blobs_missing > 0
                    || blobs.cleanup_errors > 0
                {
                    eprintln!(
                        "mci-agent: retention purge: events={} vectors={} episodes={} referenced_blobs_deleted={} orphaned_blobs_deleted={} stale_temps_deleted={} referenced_blobs_missing={} blob_cleanup_errors={}",
                        ps.events_deleted,
                        ps.vectors_deleted,
                        ps.episodes_deleted,
                        ps.blobs_deleted,
                        blobs.orphaned_blobs_deleted,
                        blobs.stale_temporary_files_deleted,
                        blobs.referenced_blobs_missing,
                        blobs.cleanup_errors,
                    );
                }
            }
            Err(e) => {
                stats.cycle_errors += 1;
                eprintln!("mci-agent: retention cycle skipped: {e}");
            }
        }

        tokio::select! {
            () = tokio::time::sleep(check_interval) => {}
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
        assert_eq!(
            load_retention_config(&path).expect("valid forever config"),
            RetentionConfig::Forever
        );
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
        assert_eq!(
            load_retention_config(&path).expect("valid 30-day config"),
            RetentionConfig::Days(30)
        );
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
        assert_eq!(
            load_retention_config(&path).expect("valid seven-day config"),
            RetentionConfig::Days(7)
        );
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
        assert_eq!(
            load_retention_config(&path).expect("valid custom config"),
            RetentionConfig::Days(14)
        );
    }

    #[test]
    fn load_custom_no_days_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"custom","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert!(matches!(
            load_retention_config(&path),
            Err(RetentionConfigError::InvalidCustomDays { .. })
        ));
    }

    #[test]
    fn custom_days_outside_closed_schema_are_errors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        for invalid in [
            r#"{"mode":"custom","days":0}"#,
            r#"{"mode":"custom","days":366}"#,
            r#"{"mode":"custom"}"#,
            r#"{"mode":"custom","days":18446744073709551616}"#,
        ] {
            std::fs::write(&path, invalid).unwrap();
            assert!(
                load_retention_config(&path).is_err(),
                "invalid payload {invalid}"
            );
        }
    }

    #[test]
    fn missing_file_defaults_forever() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        assert_eq!(
            load_retention_config(&path).expect("missing config uses fresh-install default"),
            RetentionConfig::Forever
        );
    }

    #[test]
    fn malformed_json_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(&path, "not json").unwrap();
        assert!(matches!(
            load_retention_config(&path),
            Err(RetentionConfigError::Malformed { .. })
        ));
    }

    #[test]
    fn unknown_mode_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::write(
            &path,
            r#"{"mode":"unknownMode","days":5,"updated_at":"2026-05-21T00:00:00Z"}"#,
        )
        .unwrap();
        assert!(matches!(
            load_retention_config(&path),
            Err(RetentionConfigError::UnknownMode { .. })
        ));
    }

    #[test]
    fn unreadable_existing_path_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retention.json");
        std::fs::create_dir(&path).unwrap();

        assert!(matches!(
            load_retention_config(&path),
            Err(RetentionConfigError::Read { .. })
        ));
    }

    #[test]
    fn malformed_configuration_skips_retention_deletion() {
        use mci_brain::{BrainStore, Event, EventId};
        use mci_core::crypto::DbKey;

        let dir = tempfile::tempdir().expect("tempdir");
        let brain_path = dir.path().join("mci.sqlite");
        let store = SqlCipherBrainStore::new(&brain_path, &DbKey::from_bytes([0x62; 32]))
            .expect("open store");
        let event_id = EventId(1);
        store
            .put_event(&Event {
                id: EventId(0),
                ts_us: 100,
                app_bundle_id: None,
                window_title: None,
                url: None,
                text: "must survive an invalid retention policy".into(),
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
                embedding: None,
            })
            .expect("put event");
        let config = dir.path().join("retention.json");
        std::fs::write(&config, "not json").expect("write malformed config");

        assert!(matches!(
            run_retention_cycle(&store, &config, std::time::Duration::ZERO, 7_200_000_000),
            Err(RetentionCycleError::Configuration(
                RetentionConfigError::Malformed { .. }
            ))
        ));
        assert!(
            store.get_event(event_id).expect("read event").is_some(),
            "an invalid policy must skip deletion rather than imply forever"
        );
    }

    #[test]
    fn worker_stats_default_values() {
        let s = RetentionWorkerStats {
            cycles_run: 0,
            total_events_deleted: 0,
            total_vectors_deleted: 0,
            total_episodes_deleted: 0,
            total_blobs_deleted: 0,
            total_orphaned_blobs_deleted: 0,
            total_stale_temporary_files_deleted: 0,
            referenced_blobs_missing_last: 0,
            total_blob_cleanup_errors: 0,
            cycle_errors: 0,
        };
        assert_eq!(s.cycles_run, 0);
    }

    #[test]
    fn forever_cycle_still_reconciles_crash_orphaned_keyframe_blobs() {
        use mci_brain::{BrainStore, Event, EventId};
        use mci_core::crypto::DbKey;

        let dir = tempfile::tempdir().expect("tempdir");
        let brain_path = dir.path().join("mci.sqlite");
        let store = SqlCipherBrainStore::new(&brain_path, &DbKey::from_bytes([0x61; 32]))
            .expect("open store");
        store
            .put_event(&Event {
                id: EventId(0),
                ts_us: 100,
                app_bundle_id: None,
                window_title: None,
                url: None,
                text: "live text-only event".into(),
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
                embedding: None,
            })
            .expect("put event");
        let blob_dir = dir.path().join("blobs");
        std::fs::create_dir(&blob_dir).expect("create blobs");
        let orphan = blob_dir.join(format!("{}.bin", "6".repeat(64)));
        std::fs::write(&orphan, b"crash orphan").expect("write orphan");
        let config = dir.path().join("retention.json");
        std::fs::write(&config, r#"{"mode":"forever","days":null}"#).expect("write config");

        let (purge, blobs) =
            run_retention_cycle(&store, &config, std::time::Duration::ZERO, 1_000_000)
                .expect("retention cycle");

        assert_eq!(purge.events_deleted, 0);
        assert_eq!(blobs.orphaned_blobs_deleted, 1);
        assert!(
            !orphan.exists(),
            "forever mode must still repair crash orphans"
        );
    }
}
