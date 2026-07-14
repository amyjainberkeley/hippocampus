//! Calendar event wire format + read stub (scaffold).
//!
//! Shape derived from EventKit's `EKEvent` surface (Apple's public
//! framework), projected to the fields the FORK 8 = A Tier2
//! entity-extraction pipeline consumes:
//!
//! - **`event_id`** — `EKEvent.eventIdentifier` (stable across launches;
//!   the natural dedup key when V2-P11 sync arrives, analogous to
//!   `message.guid`).
//! - **`calendar_id`** — `EKEvent.calendar.calendarIdentifier`. Lets the
//!   cascade-equivalent (wire-up PR) apply per-calendar allow/deny.
//! - **`title` / `notes` / `location`** — the three free-text surfaces
//!   the Tier2 NER + AliasResolver reads. `notes` is the load-bearing one
//!   for cross-app dot-connection (users paste zoom links, agenda,
//!   contact info there).
//! - **`start_unix` / `end_unix`** — unix-seconds. EventKit exposes
//!   `NSDate`; the wire-up bridge converts to unix.
//! - **`participants`** — resolved `EKParticipant.URL` set (email or
//!   phone). Feeds the AliasResolver on the same surface as Messages
//!   handles.
//!
//! The stub returns an empty `Vec<CalendarEvent>` unconditionally. The
//! Timestamp type-alias mirrors the messages-reader watermark shape so
//! Phase D consumers write one polling loop that pans across sources.

/// Unix-seconds timestamp. Aliased so consumers can write generic Phase D
/// polling code that treats Messages/Mail/Calendar/Notes/Reminders
/// watermarks uniformly.
pub type Timestamp = i64;

/// EventKit auth-status source. `AppleScript` is retained as a variant so
/// the same enum can classify the Notes.app scaffold (Notes has no public
/// framework — see `mci-notes-reader`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventSource {
    /// EventKit (`EKEventStore`, `EKEvent`). Calendar + Reminders.
    EventKit,
    /// AppleScript automation (Notes.app fallback).
    AppleScript,
}

/// Which EventKit backend this crate targets. Type-level marker so the
/// notes-reader / reminders-reader can share the wire-format struct via
/// a trait if we choose to refactor before wire-up (deferred decision;
/// see ADR-0037 §3 alternatives).
pub struct EventKitBackend;

/// One EventKit participant's resolvable handle (email or phone).
///
/// The wire-up PR fills this from `EKParticipant.URL` (`mailto:` /
/// `tel:` URIs). The AliasResolver treats the string identically to a
/// Messages handle or a Mail address, which is the whole point of
/// FORK 8 = A: one identity model across sources.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParticipantHandle {
    /// Raw handle (email address or phone number).
    pub handle: String,
    /// Display name if EventKit exposes one; `None` otherwise.
    pub display_name: Option<String>,
}

/// One calendar event, projected to the fields Phase D brain-ingest needs.
///
/// Field ordering matches [`mci_messages_reader::MessageRow`] as closely
/// as the two surfaces allow: stable id first, then temporal window,
/// then the free-text body, then participants. Consumers that already
/// handle `MessageRow` can generalize with minimal churn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarEvent {
    /// `EKEvent.eventIdentifier`. Cross-launch stable per-event id;
    /// the dedup key.
    pub event_id: String,
    /// `EKEvent.calendar.calendarIdentifier`. Per-calendar allow/deny key.
    pub calendar_id: String,
    /// `EKEvent.title`. `None` for events without a title (rare but
    /// permitted).
    pub title: Option<String>,
    /// `EKEvent.notes`. The load-bearing free-text surface for FORK 8 = A.
    pub notes: Option<String>,
    /// `EKEvent.location`. Free-text; may contain an address, a URL
    /// (Zoom / Meet link), or both.
    pub location: Option<String>,
    /// `EKEvent.startDate` as unix-seconds.
    pub start_unix: Timestamp,
    /// `EKEvent.endDate` as unix-seconds.
    pub end_unix: Timestamp,
    /// Resolved participant set. Empty for solo events; N entries for a
    /// group event. Deduped + sorted (byte-lexicographic ascending) by
    /// the reader so persisted who-labels are stable across reads —
    /// same discipline as `MessageRow::recipient_handles`.
    pub participants: Vec<ParticipantHandle>,
    /// Which framework the event came from. `EventKit` in the wire-up PR.
    pub source: EventSource,
}

/// Return every calendar event whose `end_unix` is at or after `since_unix`.
///
/// **Scaffold behaviour:** returns `Ok(Vec::new())` unconditionally. The
/// `since_unix` argument is accepted (and named) so the wire-up PR is a
/// signature-preserving lift.
///
/// # Errors
///
/// The scaffold never errors. The wire-up PR will return
/// [`CalendarReaderError::AccessDenied`] on EKAuth denied/restricted and
/// bubble EventKit failures via a new `EventKit` variant.
pub fn read_events_since(
    since_unix: Timestamp,
) -> Result<Vec<CalendarEvent>, crate::error::CalendarReaderError> {
    // Suppress unused-variable lint while keeping the signature stable.
    let _ = since_unix;
    Ok(Vec::new())
}
