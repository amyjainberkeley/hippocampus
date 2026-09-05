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
        }
    }

    /// Refresh from retained rows on startup, helper health and retention.
    pub fn refresh(&self, clock: &dyn WallClock) {
        self.publish(clock, |_| {});
    }

    /// Call only after a screen event transaction has committed.
    pub fn stored_frame(&self, clock: &dyn WallClock) {
        self.publish(clock, |state| {
            state.suppression_reason = None;
            state.blocked_reason = None;
        });
    }

    /// A privacy tombstone carries a closed, content-free reason enum.
    pub fn suppressed(&self, reason: mci_core::ipc::RedactionReason, clock: &dyn WallClock) {
        self.publish(clock, |state| {
            state.suppression_reason = Some(reason.as_db_str().into())
        });
    }

    /// Report a known process/storage blocker using a fixed code.
    pub fn blocked(&self, reason: &'static str, clock: &dyn WallClock) {
        self.publish(clock, |state| state.blocked_reason = Some(reason.into()));
    }

    fn publish(&self, clock: &dyn WallClock, update: impl FnOnce(&mut CaptureStatus)) {
        let mut state = self.state.lock().expect("capture status mutex poisoned");
        update(&mut state);
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
        state.updated_at = clock.now_rfc3339();
        if self.write_atomic(&state).is_err() {
            eprintln!("mci-agent: capture status write failed");
        }
    }

    fn write_atomic(&self, state: &CaptureStatus) -> std::io::Result<()> {
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
