//! Note wire format + read stub (scaffold).
//!
//! Shape derived from Notes.app's AppleScript scripting suite (the only
//! supported deep-hook surface — see `lib.rs` for why). Projected to the
//! fields the FORK 8 = A Tier2 entity-extraction pipeline consumes:
//!
//! - **`note_id`** — the AppleScript `id` (a CoreData URI like
//!   `x-coredata://.../ICNote/pN`). Stable per-note across launches;
//!   dedup key.
//! - **`folder_id` / `folder_name`** — Notes surfaces the containing
//!   folder; the cascade-equivalent (wire-up PR) can apply per-folder
//!   allow/deny (users often keep a "Private" or "Passwords" folder).
//! - **`title` / `body_plain`** — the two free-text surfaces. Notes
//!   AppleScript returns `plaintext` on request; the wire-up strips the
//!   HTML the default `body` returns.
//! - **`modification_unix`** — unix-seconds; drives the incremental
//!   polling watermark.

/// Unix-seconds timestamp — same shape as calendar-reader / messages-reader.
pub type Timestamp = i64;

/// Containing-folder projection. Notes are always in a folder (default:
/// "Notes"); Notes.app folder ids are stable per-account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteFolder {
    /// AppleScript `id` of the folder (CoreData URI).
    pub folder_id: String,
    /// User-visible folder name (e.g. "Notes", "Personal", "Passwords").
    pub folder_name: String,
}

/// One note, projected to the fields Phase D brain-ingest needs.
///
/// Field ordering mirrors `CalendarEvent` and `MessageRow`: stable id
/// first, then container, then temporal, then free text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    /// AppleScript `id` of the note (CoreData URI). Dedup key.
    pub note_id: String,
    /// Containing folder.
    pub folder: NoteFolder,
    /// `name` from AppleScript. `None` for untitled notes.
    pub title: Option<String>,
    /// `plaintext` body from AppleScript. `None` if the note has no
    /// text (image-only / attachment-only notes). Empty string is a
    /// note whose text was cleared — distinct from `None`.
    pub body_plain: Option<String>,
    /// `modification date` as unix-seconds.
    pub modification_unix: Timestamp,
}

/// Return every note whose `modification_unix` is at or after
/// `since_unix`.
///
/// **Scaffold behaviour:** returns `Ok(Vec::new())` unconditionally.
///
/// # Errors
///
/// The scaffold never errors. Wire-up PR returns
/// [`NotesReaderError`](crate::error::NotesReaderError) variants for
/// permission-denied + osascript failures.
pub fn read_notes_since(
    since_unix: Timestamp,
) -> Result<Vec<Note>, crate::error::NotesReaderError> {
    let _ = since_unix;
    Ok(Vec::new())
}

/// Compatibility alias for consumers that walk the three Phase D readers
/// uniformly (`read_events_since` is the calendar/reminders spelling).
/// Points at the same stub.
///
/// # Errors
///
/// Same as [`read_notes_since`].
pub fn read_events_since(
    since_unix: Timestamp,
) -> Result<Vec<Note>, crate::error::NotesReaderError> {
    read_notes_since(since_unix)
}
