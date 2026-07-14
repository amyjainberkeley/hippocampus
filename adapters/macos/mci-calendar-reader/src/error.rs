//! Error surface for the Calendar.app deep-hook read path (scaffold).
//!
//! Mirrors [`mci_messages_reader::MessagesReaderError`] and
//! [`mci_mail_reader::MailReaderError`] so the wire-up PR is a strict
//! superset: same variant names, same load-bearing `AccessDenied` role
//! for the onboarding UX.

use thiserror::Error;

/// Errors returned by the Phase D scaffold API.
///
/// Today the stub never returns an error (empty vecs only), but the enum
/// is public and stable so the wire-up PR does not have to re-plumb the
/// error surface downstream. [`CalendarReaderError::AccessDenied`] is the
/// load-bearing variant for the onboarding UX — the wire-up PR maps
/// `EKAuthorizationStatus.denied` / `.restricted` to it.
#[derive(Debug, Error)]
pub enum CalendarReaderError {
    /// macOS Automation TCC (per-target: Calendar) has not been granted
    /// to the calling process, so every EventKit read returns denied.
    /// This is the wire-up-only variant; the scaffold never returns it.
    #[error(
        "Calendar access denied: macOS Automation permission for Calendar not granted. \
         Grant it in System Settings → Privacy & Security → Calendars."
    )]
    AccessDenied,

    /// The Phase D wire-up has not landed yet. Every call today returns
    /// an empty vec, so this variant is a placeholder for the wire-up
    /// PR — it lets consumers pattern-match on "reader is not wired"
    /// without depending on the vec-being-empty tell.
    #[error("Calendar reader is scaffold-only (Phase D). Wire-up deferred to cycle 8.60+ per ADR-0037.")]
    NotYetWired,
}
