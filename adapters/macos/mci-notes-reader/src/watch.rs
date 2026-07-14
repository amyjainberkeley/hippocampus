//! Watch-surface stub for the Notes deep-hook (scaffold).
//!
//! Notes.app does not fire `NSDistributedNotificationCenter` events for
//! note edits and does not expose a Core Data change token via
//! AppleScript. The wire-up PR will fall back to polling (default 30s;
//! configurable per V2-P10 onboarding) — the same polling shape as the
//! Messages `FSEvents` fallback path when WAL watching is unavailable.
//! Today the stream is empty.

use crate::error::NotesReaderError;
use crate::notes::Note;

/// Emitted when a note is created/edited/deleted (wire-up PR).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteChangeEvent {
    /// The note post-change. `None` on delete (only `note_id` known).
    pub note: Option<Note>,
    /// Stable per-note id — always present, even on delete.
    pub note_id: String,
}

/// Handle returned by [`watch_notes`]. Zero-sized in the scaffold; the
/// wire-up PR upgrades to hold the polling task + a cancellation token.
#[derive(Debug, Default)]
pub struct InboxWatcher;

impl InboxWatcher {
    /// Stop watching. No-op in the scaffold.
    pub fn stop(self) {}
}

/// Start watching Notes.app for new/changed notes.
///
/// **Scaffold behaviour:** returns an [`InboxWatcher`] that never emits.
///
/// # Errors
///
/// The scaffold never errors; wire-up returns
/// [`NotesReaderError::AccessDenied`] on missing Automation TCC.
pub fn watch_notes() -> Result<InboxWatcher, NotesReaderError> {
    Ok(InboxWatcher)
}
