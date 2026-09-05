//! Atomic, content-free capture receipts for the desktop UI.

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use mci_brain::SqlCipherBrainStore;
use serde::{Deserialize, Serialize};

use crate::wall_clock::{format_unix_ms, WallClock};

/// Version one of capture-status.json. Counts describe retained database rows.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct CaptureStatus {
    /// JSON contract version.
    pub schema_version: u32,
    /// Status observation time, independent of the last saved frame.
    pub updated_at: String,
    /// Timestamp of the most recent retained screen event.
    pub last_stored_frame_at: Option<String>,
    /// Retained, explicitly attributed screen events; imports are excluded.
    pub stored_frame_count: u64,
    /// Retained keyframe references. This is not a filesystem blob count.
    pub stored_screenshot_count: u64,
    /// Last observed suppression code, cleared by a committed screen frame.
    pub suppression_reason: Option<String>,
    /// Known blocker, never inferred from a lack of incoming frames.
    pub blocked_reason: Option<String>,
}

/// Single agent writer, shared with retention maintenance.
pub struct CaptureStatusWriter {
    store: Arc<SqlCipherBrainStore>,
    path: PathBuf,
    capture_enabled: bool,
    has_counts: AtomicBool,
    state: Mutex<CaptureStatus>,
    #[cfg(test)]
    stats_reads: AtomicU64,
    #[cfg(test)]
    receipt_writes: AtomicU64,
}

impl CaptureStatusWriter {
    /// Construct a writer beside the database. Publishing is explicit.
    #[must_use]
    pub fn new(store: Arc<SqlCipherBrainStore>, path: PathBuf, capture_enabled: bool) -> Self {
        Self {
            store,
            path,
            capture_enabled,
            has_counts: AtomicBool::new(false),
            state: Mutex::new(CaptureStatus {
                schema_version: 1,
                blocked_reason: (!capture_enabled).then(|| "capture_disabled".into()),
                ..CaptureStatus::default()
            }),
            #[cfg(test)]
            stats_reads: AtomicU64::new(0),
            #[cfg(test)]
            receipt_writes: AtomicU64::new(0),
        }
    }

    /// Refresh from retained rows on startup, helper health and retention.
    pub fn refresh(&self, clock: &dyn WallClock) {
        self.publish(clock, true, |_| true);
    }

    /// Call only after a screen event transaction has committed.
    pub fn stored_frame(&self, clock: &dyn WallClock) {
        self.publish(clock, true, |state| {
            state.suppression_reason = None;
            state.blocked_reason = None;
            true
        });
    }

    /// A privacy tombstone carries a closed, content-free reason enum.
    /// Identical reasons wait for the helper heartbeat; changes reuse known counts.
    pub fn suppressed(&self, reason: mci_core::ipc::RedactionReason, clock: &dyn WallClock) {
        self.publish(clock, false, |state| {
            let reason = reason.as_db_str();
            if state.suppression_reason.as_deref() == Some(reason) {
                return false;
            }
            state.suppression_reason = Some(reason.into());
            true
        });
    }

    /// Report a known process/storage blocker using a fixed code.
    pub fn blocked(&self, reason: &'static str, clock: &dyn WallClock) {
        self.publish(clock, true, |state| {
            state.blocked_reason = Some(reason.into());
            true
        });
    }

    fn publish(
        &self,
        clock: &dyn WallClock,
        refresh_counts: bool,
        update: impl FnOnce(&mut CaptureStatus) -> bool,
    ) {
        let mut state = self.state.lock().expect("capture status mutex poisoned");
        if !update(&mut state) {
            return;
        }
        if refresh_counts || !self.has_counts.load(Ordering::Relaxed) {
            #[cfg(test)]
            self.stats_reads.fetch_add(1, Ordering::Relaxed);
            match self.store.capture_storage_stats() {
                Ok(counts) => {
                    self.has_counts.store(true, Ordering::Relaxed);
                    if state.blocked_reason.as_deref() == Some("store_unavailable") {
                        state.blocked_reason =
                            (!self.capture_enabled).then(|| "capture_disabled".into());
                    }
                    state.stored_frame_count = counts.stored_frame_count;
                    state.stored_screenshot_count = counts.stored_screenshot_count;
                    state.last_stored_frame_at = counts
                        .last_stored_frame_ts_us
                        // RFC3339 permits four-digit years, through 9999.
                        .filter(|ts| *ts / 1_000 <= 253_402_300_799_999)
                        .map(|ts| format_unix_ms(u128::from(ts) / 1_000));
                }
                Err(_) => {
                    if !self.has_counts.load(Ordering::Relaxed) {
                        eprintln!(
                        "mci-agent: capture status unavailable; retained counts could not be read"
                    );
                        return;
                    }
                    state.blocked_reason = Some("store_unavailable".into());
                }
            }
        }
        state.updated_at = clock.now_rfc3339();
        if self.write_atomic(&state).is_err() {
            eprintln!("mci-agent: capture status write failed");
        }
    }

    fn write_atomic(&self, state: &CaptureStatus) -> std::io::Result<()> {
        #[cfg(test)]
        self.receipt_writes.fetch_add(1, Ordering::Relaxed);
        static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
        let bytes = serde_json::to_vec(state)?;
        let temporary = self.path.with_extension(format!(
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
        let mut file = options.open(&temporary)?;
        let result = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&temporary, &self.path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wall_clock::test_support::FixedClock;
    use mci_core::crypto::DbKey;
    use mci_core::ipc::RedactionReason;

    fn writer(dir: &tempfile::TempDir) -> CaptureStatusWriter {
        let store = Arc::new(
            SqlCipherBrainStore::new(
                &dir.path().join("brain.sqlite"),
                &DbKey::from_bytes([54; 32]),
            )
            .unwrap(),
        );
        CaptureStatusWriter::new(store, dir.path().join("capture-status.json"), true)
    }

    fn io_counts(writer: &CaptureStatusWriter) -> (u64, u64) {
        (
            writer.stats_reads.load(Ordering::Relaxed),
            writer.receipt_writes.load(Ordering::Relaxed),
        )
    }

    fn read(writer: &CaptureStatusWriter) -> CaptureStatus {
        serde_json::from_slice(&std::fs::read(&writer.path).unwrap()).unwrap()
    }

    #[test]
    fn suppression_burst_waits_for_heartbeat_without_database_or_file_io() {
        let dir = tempfile::tempdir().unwrap();
        let writer = writer(&dir);
        let initial = FixedClock::at_unix_ms(0);
        let later = FixedClock::at_unix_ms(29_000);
        let heartbeat = FixedClock::at_unix_ms(30_000);
        // The first publication must obtain real counts, even without startup refresh.
        writer.suppressed(RedactionReason::FailsafeUnknown, &initial);
        assert_eq!(io_counts(&writer), (1, 1));
        let original = std::fs::read(&writer.path).unwrap();
        for _ in 0..60 {
            writer.suppressed(RedactionReason::FailsafeUnknown, &later);
        }
        assert_eq!(io_counts(&writer), (1, 1));
        assert_eq!(std::fs::read(&writer.path).unwrap(), original);
        writer.refresh(&heartbeat);
        assert_eq!(io_counts(&writer), (2, 2));
        let receipt = read(&writer);
        assert_eq!(receipt.updated_at, "1970-01-01T00:00:30.000Z");
        assert_eq!(receipt.last_stored_frame_at, None);
        assert_eq!(
            receipt.suppression_reason.as_deref(),
            Some("failsafe-unknown")
        );
        for _ in 0..60 {
            writer.suppressed(RedactionReason::FailsafeUnknown, &heartbeat);
        }
        assert_eq!(io_counts(&writer), (2, 2));
    }

    #[test]
    fn changed_suppression_uses_cached_counts_but_other_updates_refresh_immediately() {
        let dir = tempfile::tempdir().unwrap();
        let writer = writer(&dir);
        let initial = FixedClock::at_unix_ms(0);
        let later = FixedClock::at_unix_ms(1_000);
        writer.refresh(&initial);
        writer.suppressed(RedactionReason::FailsafeUnknown, &initial);
        assert_eq!(io_counts(&writer), (1, 2));
        writer.suppressed(RedactionReason::FocusRaceDropped, &later);
        assert_eq!(io_counts(&writer), (1, 3));
        assert_eq!(
            read(&writer).suppression_reason.as_deref(),
            Some("focus-race-dropped")
        );
        assert_eq!(read(&writer).updated_at, "1970-01-01T00:00:01.000Z");

        writer.stored_frame(&later);
        assert_eq!(io_counts(&writer), (2, 4));
        assert_eq!(read(&writer).suppression_reason, None);
        writer.blocked("helper_disconnected", &later);
        assert_eq!(io_counts(&writer), (3, 5));
        assert_eq!(
            read(&writer).blocked_reason.as_deref(),
            Some("helper_disconnected")
        );
        // Retention shares the immediate refresh path with helper health.
        writer.refresh(&later);
        assert_eq!(io_counts(&writer), (4, 6));
    }
}
