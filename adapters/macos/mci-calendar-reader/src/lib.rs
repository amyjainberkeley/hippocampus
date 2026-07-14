// Phase D — Calendar.app deep-hook read path (SCAFFOLD ONLY).
//
// Gate the entire crate body on macOS — even though the scaffold has no
// macOS-specific deps yet, we keep the same target-gate shape as the
// wired adapters (mci-messages-reader / mci-mail-reader) so the wire-up
// PR is a strict superset. On Linux this crate compiles to an empty
// library.
#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

//! `mci-calendar-reader` — Phase D Calendar.app deep-hook read path.
//!
//! **SCAFFOLD ONLY.** This crate publishes the type shape and public API
//! signatures the Phase D deep-hook Tier2 entity-extraction pipeline
//! (FORK 8 = A: V2-P4 regex + V2-P5 Qwen NER + V2-P6 AliasResolver +
//! `episode_edges`) will consume. It does NOT read EventKit today.
//!
//! Wire-up sequencing:
//!
//! 1. **This PR (Phase D scaffold, cycle 8.5x).** Types + stubs + ADR-0037.
//!    All reads return empty vecs. Onboarding UI shows a "Coming soon"
//!    row with the deep-hook toggle disabled.
//! 2. **CSO-gated wire-up PR (cycle 8.60+).** Real EventKit calls, the
//!    per-plugin cascade-equivalent per ADR-0032 §3(f) analogue, the
//!    Automation TCC per-target grant flow (Calendar), and the brain-ingest
//!    plumbing. That PR ships behind a `plugin_enabled = false` master
//!    switch — same discipline as V2-P7/V2-P8b — and the onboarding toggle
//!    is what flips it on.
//!
//! ## TCC requirement (documented; not yet exercised)
//!
//! Calendar.app deep-read requires **Automation TCC per-target for
//! Calendar** on macOS (Sequoia onward; carries into macOS 26). This is
//! separate from Full Disk Access — Automation TCC prompts per target the
//! first time the process sends Apple Events (or, for EventKit, calls
//! `EKEventStore.requestFullAccessToEvents`). The wire-up PR must add:
//!
//! - The `NSCalendarsFullAccessUsageDescription` Info.plist string in the
//!   agent + Hippocampus.app bundles.
//! - A permission-status probe that surfaces
//!   [`CalendarReaderError::AccessDenied`] on `EKAuthorizationStatus.denied`
//!   / `.restricted` (mirroring `MessagesReaderError::AccessDenied` shape).
//! - The onboarding UI card that deep-links into System Settings →
//!   Privacy & Security → Calendars.
//!
//! ## What this crate does NOT do
//!
//! - Does not read EventKit. Does not touch `Calendar.sqlitedb` under
//!   `~/Library/Calendars/`. Does not write the brain. Does not emit
//!   `CaptureEvent::CalendarEvent` on the wire.
//! - Does not implement a cascade-equivalent (ADR-0037 §5 — deferred to
//!   the wire-up PR).
//! - Does not inspect real user calendars. All tests exercise the empty
//!   stub only.
//!
//! ## ADR pointers
//!
//! - `docs/decisions/0032-deep-hook-plugin-contract.md` — the deep-hook
//!   plugin contract this scaffold implements the shape of.
//! - `docs/decisions/0037-deep-hook-plugins-calendar-notes-reminders-scaffold.md`
//!   — this scaffold's ADR (Proposed).

pub mod error;
pub mod events;
pub mod watch;

pub use error::CalendarReaderError;
pub use events::{
    read_events_since, CalendarEvent, EventKitBackend, EventSource, ParticipantHandle, Timestamp,
};
pub use watch::{watch_calendar, InboxWatcher, NewCalendarEvent};
