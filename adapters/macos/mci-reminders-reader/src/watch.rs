//! Watch-surface stub for the Reminders deep-hook (scaffold).
//!
//! Wire-up will subscribe to `EKEventStoreChanged` (same notification as
//! Calendar). Today the stream is empty.

use crate::error::RemindersReaderError;
use crate::reminders::Reminder;

/// Emitted when a reminder is created/edited/completed/deleted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReminderChangeEvent {
    /// The reminder post-change. `None` on delete.
    pub reminder: Option<Reminder>,
    /// Stable per-reminder id.
    pub reminder_id: String,
}

/// Handle returned by [`watch_reminders`]. Zero-sized in the scaffold.
#[derive(Debug, Default)]
pub struct InboxWatcher;

impl InboxWatcher {
    /// Stop watching. No-op in the scaffold.
    pub fn stop(self) {}
}

/// Start watching Reminders.app for changes.
///
/// **Scaffold behaviour:** returns an [`InboxWatcher`] that never emits.
///
/// # Errors
///
/// The scaffold never errors.
pub fn watch_reminders() -> Result<InboxWatcher, RemindersReaderError> {
    Ok(InboxWatcher)
}
