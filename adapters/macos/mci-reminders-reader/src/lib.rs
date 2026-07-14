// Phase D — Reminders.app deep-hook read path (SCAFFOLD ONLY).
#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

//! `mci-reminders-reader` — Phase D Reminders.app deep-hook read path.
//!
//! **SCAFFOLD ONLY.** Publishes the type shape and public API signatures
//! the Phase D Tier2 entity-extraction pipeline (FORK 8 = A) will consume
//! for Reminders.app. Does NOT read EventKit today.
//!
//! ## TCC requirement (documented; not yet exercised)
//!
//! Reminders shares EventKit with Calendar but requires a **separate**
//! Automation TCC per-target grant (Reminders is distinct from Calendars
//! since macOS 13). The wire-up PR (cycle 8.60+) must add:
//!
//! - `NSRemindersFullAccessUsageDescription` in the agent + Hippocampus.app
//!   bundles.
//! - A permission-status probe that surfaces
//!   [`RemindersReaderError::AccessDenied`] on `EKAuthorizationStatus.denied`
//!   / `.restricted`.
//! - The onboarding UI card that deep-links into System Settings →
//!   Privacy & Security → Reminders.
//!
//! ## What this crate does NOT do
//!
//! - Does not read EventKit. Does not write the brain.
//! - Does not implement a cascade-equivalent (deferred to the wire-up PR).
//!
//! ## ADR pointers
//!
//! - `docs/decisions/0032-deep-hook-plugin-contract.md`
//! - `docs/decisions/0037-deep-hook-plugins-calendar-notes-reminders-scaffold.md`

pub mod error;
pub mod reminders;
pub mod watch;

pub use error::RemindersReaderError;
pub use reminders::{read_events_since, read_reminders_since, Reminder, ReminderList, Timestamp};
pub use watch::{watch_reminders, InboxWatcher, ReminderChangeEvent};
