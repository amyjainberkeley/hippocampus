//! Error surface for the Notes.app deep-hook read path (scaffold).

use thiserror::Error;

/// Errors returned by the Phase D Notes scaffold API.
///
/// [`NotesReaderError::AccessDenied`] is the load-bearing variant for
/// the onboarding UX — the wire-up PR maps `errAEEventNotPermitted` (the
/// `AEDeterminePermissionToAutomateTarget` refusal code) to it.
#[derive(Debug, Error)]
pub enum NotesReaderError {
    /// macOS Automation TCC (per-target: Notes) has not been granted to
    /// the calling process, so every AppleScript `tell application
    /// "Notes"` returns permission-denied. Wire-up-only variant.
    #[error(
        "Notes access denied: macOS Automation permission for Notes not granted. \
         Grant it in System Settings → Privacy & Security → Automation."
    )]
    AccessDenied,

    /// The Phase D wire-up has not landed yet.
    #[error(
        "Notes reader is scaffold-only (Phase D). Wire-up deferred to cycle 8.60+ per ADR-0037."
    )]
    NotYetWired,
}
