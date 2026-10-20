//! Retention-purger daily cron — ADR-0017 §4.
//!
//! Reads `retention.json` (written by Swift `DiskRetentionStore`) on each
//! cycle, converts to [`RetentionConfig`], calls [`purge_once`], and
//! reconciles encrypted keyframe blobs even when retention is `forever`. Runs
//! once per `check_interval` (default 24 h). Same shutdown-channel
//! pattern as [`idle_batch`](crate::idle_batch) and
//! [`episode_worker`](crate::episode_worker).
//!
//! # Pictures of side windows (SPEC 6.5)
//!
//! Beside the daily purge, the worker looks after the pictures the capture
//! helper keeps of the windows beside the one in front: every
//! [`SIDE_PICTURES_INTERVAL`], and whenever the settings file changes (it
//! looks every [`SETTINGS_POLL_INTERVAL`]), it carries out Forget Pictures
//! of Other Windows… if it was asked for, thins the pictures by age and to
//! their budget, and writes `pictures-usage.json` beside the capture
//! receipt for Preferences, Privacy and the helper. Pictures go; text never
//! does, and front-window screenshots are never touched
//! ([`mci_brain::side_pictures`]).
//!
//! # Privacy invariants
//!
//! - DELETE only — worker never inserts rows. Thinning clears a side
//!   moment's picture reference and deletes the blob, nothing else.
//! - `retention.json` is the SOLE source of truth (user's onboarding
//!   choice, reviewed per ADR-0017 §4).
//! - Safety floor: events younger than 1 hour are never purged
//!   (enforced in [`purge_once`]).
//! - The usage file is content-free: sizes, a count, the budget and
//!   whether side pictures are on.

use crate::errln;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mci_brain::retention_purger::{self, PurgeStats, RetentionConfig};
use mci_brain::side_pictures::{self, BlobSizes, PictureUsage, SidePictureSettings};
use mci_brain::{BlobReconciliationStats, SqlCipherBrainStore, StoreError};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

const ORPHAN_GRACE: Duration = Duration::from_secs(3_600);

/// How often pictures of side windows are thinned and their usage written.
pub const SIDE_PICTURES_INTERVAL: Duration = Duration::from_secs(15 * 60);

/// How often the settings file is checked for a change: a new budget, or
/// Forget Pictures of Other Windows… confirmed.
pub const SETTINGS_POLL_INTERVAL: Duration = Duration::from_secs(10);

/// The usage file's name, beside the capture receipt.
pub const PICTURES_USAGE_FILE: &str = "pictures-usage.json";

/// `pictures-usage.json`, version 1: what the screenshots use. Content-free.
/// Preferences shows "Using 640 MB.", Privacy the side pictures' share of
/// their budget, and the capture helper stops keeping side pictures once
/// they fill it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PicturesUsage {
    /// JSON contract version.
    pub schema_version: u32,
    /// When this was measured, RFC-3339 UTC.
    pub updated_at: String,
    /// Sealed screenshots of the window in front, in bytes.
    pub front_bytes: u64,
    /// Sealed pictures of the windows beside it, in bytes.
    pub side_bytes: u64,
    /// Side moments that keep a picture.
    pub side_count: u64,
    /// The side pictures' budget in bytes.
    pub side_budget_bytes: u64,
    /// Whether side pictures are on in Preferences.
    pub side_pictures_on: bool,
}

/// Content-free stats from one side-picture cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SidePictureCycleStats {
    /// Pictures cleared by Forget Pictures of Other Windows….
    pub forgotten: u64,
    /// Pictures cleared by thinning.
    pub thinned: u64,
    /// Blob files deleted.
    pub blobs_deleted: u64,
    /// What the screenshots use after the cycle.
    pub usage: PictureUsage,
    /// Whether the usage file was written.
    pub usage_written: bool,
}

/// The side-picture half of retention: where its settings and usage file
/// live, the blob sizes it has measured, and the delete request it last
/// carried out.
pub struct SidePictureMaintenance {
    settings_path: PathBuf,
    usage_path: PathBuf,
    sizes: BlobSizes,
    handled_request_us: Option<u64>,
    settings_stamp: Option<(SystemTime, u64)>,
}

impl SidePictureMaintenance {
    /// Settings from `settings_path` (`runtime.toml`), usage written to
    /// `usage_path`.
    #[must_use]
    pub fn new(settings_path: PathBuf, usage_path: PathBuf) -> Self {
        Self {
            settings_path,
            usage_path,
            sizes: BlobSizes::new(),
            handled_request_us: None,
            settings_stamp: None,
        }
    }

    /// The person's own settings and the usage file beside `retention_json`.
    #[must_use]
    pub fn for_home(home: &Path, retention_json: &Path) -> Self {
        Self::new(
            side_pictures::settings_path(home),
            retention_json.with_file_name(PICTURES_USAGE_FILE),
        )
    }

    /// Whether the settings file changed since the last cycle read it.
    #[must_use]
    pub fn settings_changed(&self) -> bool {
        file_stamp(&self.settings_path) != self.settings_stamp
    }

    /// One cycle: carry out a new delete request, thin to the budget and
    /// write the usage file. A usage file that cannot be written is
    /// reported in the stats, not as a failure: the pictures are thinned.
    ///
    /// # Errors
    /// A content-free store error when the pictures cannot be read or
    /// cleared.
    pub fn run_cycle(
        &mut self,
        store: &SqlCipherBrainStore,
        now_us: u64,
    ) -> Result<SidePictureCycleStats, StoreError> {
        self.settings_stamp = file_stamp(&self.settings_path);
        let settings = SidePictureSettings::load(&self.settings_path);
        let mut stats = SidePictureCycleStats::default();
        if let Some(through) = settings.delete_requested_at_us {
            if self.handled_request_us != Some(through) {
                let forgotten = side_pictures::forget_through(store, &mut self.sizes, through)?;
                stats.forgotten = forgotten.pictures_cleared;
                stats.blobs_deleted = forgotten.blobs_deleted;
                self.handled_request_us = Some(through);
            }
        }
        let budget = settings.budget_bytes(disk_total_bytes(&self.usage_path));
        let thinned = side_pictures::thin(store, &mut self.sizes, now_us, budget)?;
        stats.thinned = thinned.pictures_cleared;
        stats.blobs_deleted = stats.blobs_deleted.saturating_add(thinned.blobs_deleted);
        stats.usage = side_pictures::usage(store, &mut self.sizes)?;
        let record = PicturesUsage {
            schema_version: 1,
            updated_at: crate::wall_clock::format_unix_ms(u128::from(now_us / 1_000)),
            front_bytes: stats.usage.front_bytes,
            side_bytes: stats.usage.side_bytes,
            side_count: stats.usage.side_count,
            side_budget_bytes: budget,
            side_pictures_on: settings.enabled,
        };
        stats.usage_written = write_usage(&self.usage_path, &record).is_ok();
        Ok(stats)
    }
}

/// A file's last change and size, to notice a rewrite cheaply.
fn file_stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len()))
}

/// The size of the disk that holds `path`'s folder, in bytes.
fn disk_total_bytes(path: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        let folder = path.parent().unwrap_or(path);
        let stats = rustix::fs::statvfs(folder).ok()?;
        stats
            .f_blocks
            .checked_mul(stats.f_frsize)
            .filter(|total| *total > 0)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Write `record` to `path` atomically, readable only by this user.
fn write_usage(path: &Path, record: &PicturesUsage) -> std::io::Result<()> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
    let bytes = serde_json::to_vec(record)?;
    let temporary = path.with_extension(format!(
        "json.{}.{}.tmp",
        std::process::id(),
        NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
    ));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

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
    /// Side-picture cycles run.
    pub side_cycles_run: u64,
    /// Side pictures cleared by thinning across all cycles.
    pub total_side_pictures_thinned: u64,
    /// Side pictures cleared by Forget Pictures of Other Windows….
    pub total_side_pictures_forgotten: u64,
    /// Side-picture cycles that returned an error (logged, not fatal).
    pub side_cycle_errors: u64,
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
    /// Older finite policies did not record explicit review of auto-deletion.
    #[error("retention_review_required at {}: review and save retention in Settings before automatic deletion can resume", path.display())]
    ReviewRequired {
        /// Configuration requiring explicit user review.
        path: PathBuf,
    },
    /// Do not execute a future policy format using today's semantics.
    #[error("unsupported retention schema version {version} at {}", path.display())]
    UnsupportedVersion {
        /// Configuration using an unsupported version.
        path: PathBuf,
        /// Persisted version.
        version: u64,
    },
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
    schema_version: Option<u64>,
    mode: String,
    days: Option<u64>,
}

/// Parse `retention.json` into a [`RetentionConfig`].
///
/// A missing file is the deliberate fresh-install default of
/// 90 days. Finite persisted policies require version 2, written after explicit
/// review in Settings. Any existing but unreadable, malformed, or
/// unsupported file is an error: the worker must not silently reinterpret a
/// user's finite retention policy as `forever`.
pub fn load_retention_config(path: &Path) -> Result<RetentionConfig, RetentionConfigError> {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => {
            return Ok(RetentionConfig::Days(90));
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
    if let Some(version) = parsed.schema_version {
        if version != 1 && version != 2 {
            return Err(RetentionConfigError::UnsupportedVersion {
                path: path.to_path_buf(),
                version,
            });
        }
    }
    let config = match parsed.mode.as_str() {
        "forever" => Ok(RetentionConfig::Forever),
        "ninetyDays" => Ok(RetentionConfig::Days(90)),
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
    }?;
    if matches!(config, RetentionConfig::Days(_)) && parsed.schema_version != Some(2) {
        return Err(RetentionConfigError::ReviewRequired {
            path: path.to_path_buf(),
        });
    }
    Ok(config)
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
    shutdown: watch::Receiver<bool>,
) -> Result<RetentionWorkerStats, RetentionWorkerError> {
    run_retention_worker_with_status(store, retention_json_path, check_interval, shutdown, None)
        .await
}

/// Run retention maintenance and refresh the UI's retained storage counts.
/// Side pictures are looked after too, with the person's own settings
/// (`$HOME/.config/hippocampus/runtime.toml`) and the usage file beside
/// `retention_json_path`.
pub async fn run_retention_worker_with_status(
    store: Arc<SqlCipherBrainStore>,
    retention_json_path: PathBuf,
    check_interval: std::time::Duration,
    shutdown: watch::Receiver<bool>,
    capture_receipt: Option<Arc<crate::capture_status::CaptureStatusWriter>>,
) -> Result<RetentionWorkerStats, RetentionWorkerError> {
    let home = mci_core::home::user_home_or_unwritable();
    let side = SidePictureMaintenance::for_home(&home, &retention_json_path);
    run_retention_worker_with_side_pictures(
        store,
        retention_json_path,
        side,
        RetentionSchedule {
            purge: check_interval,
            side_pictures: SIDE_PICTURES_INTERVAL,
            settings_poll: SETTINGS_POLL_INTERVAL,
        },
        shutdown,
        capture_receipt,
    )
    .await
}

/// How often each part of retention runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetentionSchedule {
    /// The retention purge and blob reconciliation (a day in the app).
    pub purge: Duration,
    /// Side pictures: thinning and the usage file.
    pub side_pictures: Duration,
    /// How often the settings file is checked for a change.
    pub settings_poll: Duration,
}

/// The retention loop with its side-picture maintenance given: the purge
/// on `schedule.purge`, side pictures on `schedule.side_pictures` and as
/// soon as their settings change. Both run once at the start. Errors are
/// counted and logged without content; the loop goes on until shutdown.
pub async fn run_retention_worker_with_side_pictures(
    store: Arc<SqlCipherBrainStore>,
    retention_json_path: PathBuf,
    mut side: SidePictureMaintenance,
    schedule: RetentionSchedule,
    mut shutdown: watch::Receiver<bool>,
    capture_receipt: Option<Arc<crate::capture_status::CaptureStatusWriter>>,
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
        side_cycles_run: 0,
        total_side_pictures_thinned: 0,
        total_side_pictures_forgotten: 0,
        side_cycle_errors: 0,
    };
    let mut next_purge = tokio::time::Instant::now();
    let mut next_side = tokio::time::Instant::now();

    loop {
        if *shutdown.borrow() {
            break;
        }

        if tokio::time::Instant::now() >= next_purge {
            run_purge_cycle(
                &store,
                &retention_json_path,
                capture_receipt.as_ref(),
                &mut stats,
            )
            .await?;
            next_purge = tokio::time::Instant::now() + schedule.purge;
        }

        if tokio::time::Instant::now() >= next_side || side.settings_changed() {
            let store_c = Arc::clone(&store);
            let (back, result) = tokio::task::spawn_blocking(move || {
                let result = side.run_cycle(&store_c, now_us());
                (side, result)
            })
            .await
            .map_err(|e| RetentionWorkerError::Fatal(e.to_string()))?;
            side = back;
            match result {
                Ok(cycle) => {
                    stats.side_cycles_run += 1;
                    stats.total_side_pictures_thinned += cycle.thinned;
                    stats.total_side_pictures_forgotten += cycle.forgotten;
                    if cycle.thinned > 0 || cycle.forgotten > 0 || !cycle.usage_written {
                        errln!(
                            "mci-agent: side pictures: thinned={} forgotten={} blobs_deleted={} usage_written={}",
                            cycle.thinned,
                            cycle.forgotten,
                            cycle.blobs_deleted,
                            cycle.usage_written,
                        );
                    }
                }
                Err(e) => {
                    stats.side_cycle_errors += 1;
                    errln!("mci-agent: side picture cycle skipped: {e}");
                }
            }
            next_side = tokio::time::Instant::now() + schedule.side_pictures;
        }

        let wake = next_purge
            .min(next_side)
            .min(tokio::time::Instant::now() + schedule.settings_poll);
        tokio::select! {
            () = tokio::time::sleep_until(wake) => {}
            _ = shutdown.changed() => break,
        }
    }

    Ok(stats)
}

/// One retention purge and reconciliation, counted into `stats`.
async fn run_purge_cycle(
    store: &Arc<SqlCipherBrainStore>,
    retention_json_path: &Path,
    capture_receipt: Option<&Arc<crate::capture_status::CaptureStatusWriter>>,
    stats: &mut RetentionWorkerStats,
) -> Result<(), RetentionWorkerError> {
    let config_path = retention_json_path.to_path_buf();
    let store_c = Arc::clone(store);

    let result: Result<(PurgeStats, BlobReconciliationStats), _> =
        tokio::task::spawn_blocking(move || {
            run_retention_cycle(&store_c, &config_path, ORPHAN_GRACE, now_us())
        })
        .await
        .map_err(|e| RetentionWorkerError::Fatal(e.to_string()))?;

    if let Some(capture_receipt) = capture_receipt {
        capture_receipt.refresh(&crate::wall_clock::SystemWallClock);
    }
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
                errln!(
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
            errln!("mci-agent: retention cycle skipped: {e}");
        }
    }
    Ok(())
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
            r#"{"schema_version":2,"mode":"thirtyDays","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
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
            r#"{"schema_version":2,"mode":"sevenDays","days":null,"updated_at":"2026-05-21T00:00:00Z"}"#,
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
            r#"{"schema_version":2,"mode":"custom","days":14,"updated_at":"2026-05-21T00:00:00Z"}"#,
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
    fn missing_file_defaults_ninety_days() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        assert_eq!(
            load_retention_config(&path).expect("missing config uses fresh-install default"),
            RetentionConfig::Days(90)
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
            side_cycles_run: 0,
            total_side_pictures_thinned: 0,
            total_side_pictures_forgotten: 0,
            side_cycle_errors: 0,
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
