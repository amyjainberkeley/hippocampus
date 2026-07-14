//! Watch-surface stub for the Calendar deep-hook (scaffold).
//!
//! The wire-up PR will subscribe to `EKEventStoreChanged` notifications
//! and emit a stream of `NewCalendarEvent`. Today the surface returns an
//! empty stream so downstream Phase D wiring (Tier2 pipeline) can be
//! typed against a real Stream type.

use crate::error::CalendarReaderError;
use crate::events::CalendarEvent;

/// Emitted when EventKit reports a new/changed event in a watched
/// calendar (wire-up PR). Today the stream is empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewCalendarEvent {
    /// The event that changed. `None` for delete notifications (the
    /// wire-up PR carries only the id in that shape).
    pub event: Option<CalendarEvent>,
    /// `EKEvent.eventIdentifier` — always present, even on delete.
    pub event_id: String,
}

/// Handle returned by [`watch_calendar`]. Today it is a zero-sized
/// placeholder; the wire-up PR upgrades it to hold the notification
/// observer + a cancellation token.
#[derive(Debug, Default)]
pub struct InboxWatcher;

impl InboxWatcher {
    /// Stop watching. No-op in the scaffold.
    pub fn stop(self) {}
}

/// Start watching the user's calendars for new/changed events.
///
/// **Scaffold behaviour:** returns an [`InboxWatcher`] that never emits.
///
/// # Errors
///
/// The scaffold never errors; the wire-up PR will return
/// [`CalendarReaderError::AccessDenied`] on missing Automation TCC.
pub fn watch_calendar() -> Result<InboxWatcher, CalendarReaderError> {
    Ok(InboxWatcher)
}
