//! Reminder wire format + read stub (scaffold).
//!
//! Shape derived from EventKit's `EKReminder` surface (`EKReminder`
//! extends `EKCalendarItem`; same store as Calendar events, distinct
//! entity type + distinct auth status).
//!
//! Fields projected for the FORK 8 = A Tier2 pipeline:
//!
//! - **`reminder_id`** — `EKReminder.calendarItemIdentifier`. Stable
//!   across launches; dedup key.
//! - **`list_id` / `list_name`** — the containing `EKCalendar`
//!   (Reminders lists are Calendars in EventKit). Per-list allow/deny.
//! - **`title` / `notes`** — the two free-text surfaces. `notes` is the
//!   Tier2 target (users paste links, contact info, agenda there).
//! - **`due_unix`** — unix-seconds of `dueDateComponents` if present.
//! - **`completion_unix`** — unix-seconds of `completionDate` if done.
//! - **`is_completed`** — snapshot of `EKReminder.isCompleted`.

/// Unix-seconds timestamp.
pub type Timestamp = i64;

/// Containing-list projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReminderList {
    /// `EKCalendar.calendarIdentifier` of the containing Reminders list.
    pub list_id: String,
    /// User-visible list name (e.g. "Reminders", "Groceries").
    pub list_name: String,
}

/// One reminder, projected to the fields Phase D brain-ingest needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reminder {
    /// `EKReminder.calendarItemIdentifier`. Dedup key.
    pub reminder_id: String,
    /// Containing list.
    pub list: ReminderList,
    /// `EKReminder.title`. `None` for untitled reminders (rare).
    pub title: Option<String>,
    /// `EKReminder.notes`. The load-bearing free-text surface for
    /// FORK 8 = A.
    pub notes: Option<String>,
    /// `EKReminder.dueDateComponents` resolved to unix-seconds. `None`
    /// for reminders without a due date.
    pub due_unix: Option<Timestamp>,
    /// `EKReminder.completionDate` as unix-seconds. `None` while
    /// `!is_completed`.
    pub completion_unix: Option<Timestamp>,
    /// `EKReminder.isCompleted`.
    pub is_completed: bool,
}

/// Return every reminder whose most-recent change timestamp is at or
/// after `since_unix`. EventKit does not expose a per-item change token;
/// the wire-up PR uses `dueDateComponents` + `completionDate` +
/// `lastModifiedDate` (private API on macOS — wire-up will validate).
///
/// **Scaffold behaviour:** returns `Ok(Vec::new())` unconditionally.
///
/// # Errors
///
/// The scaffold never errors.
pub fn read_reminders_since(
    since_unix: Timestamp,
) -> Result<Vec<Reminder>, crate::error::RemindersReaderError> {
    let _ = since_unix;
    Ok(Vec::new())
}

/// Uniform-signature alias matching the Calendar/Notes readers.
///
/// # Errors
///
/// Same as [`read_reminders_since`].
pub fn read_events_since(
    since_unix: Timestamp,
) -> Result<Vec<Reminder>, crate::error::RemindersReaderError> {
    read_reminders_since(since_unix)
}
