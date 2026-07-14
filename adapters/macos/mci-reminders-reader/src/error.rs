//! Error surface for the Reminders.app deep-hook read path (scaffold).

use thiserror::Error;

/// Errors returned by the Phase D Reminders scaffold API.
#[derive(Debug, Error)]
pub enum RemindersReaderError {
    /// macOS Automation TCC (per-target: Reminders) has not been granted.
    #[error(
        "Reminders access denied: macOS Automation permission for Reminders not granted. \
         Grant it in System Settings → Privacy & Security → Reminders."
    )]
    AccessDenied,

    /// The Phase D wire-up has not landed yet.
    #[error("Reminders reader is scaffold-only (Phase D). Wire-up deferred to cycle 8.60+ per ADR-0037.")]
    NotYetWired,
}
