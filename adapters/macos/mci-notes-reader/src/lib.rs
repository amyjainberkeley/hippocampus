// Phase D — Notes.app deep-hook read path (SCAFFOLD ONLY).
#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

//! `mci-notes-reader` — Phase D Notes.app deep-hook read path.
//!
//! **SCAFFOLD ONLY.** This crate publishes the type shape and public API
//! signatures the Phase D Tier2 entity-extraction pipeline (FORK 8 = A)
//! will consume for Notes.app. It does NOT read Notes today.
//!
//! ## Why AppleScript, not a framework
//!
//! Notes.app has no public framework surface. Its bundle-internal
//! database (`NoteStore.sqlite` under `~/Group Containers/
//! group.com.apple.notes/`) is undocumented, cross-encrypted with a
//! per-account key held in the user's Keychain, and Apple reserves the
//! right to break the schema at any macOS point release. The only
//! supported deep-hook path is AppleScript automation via the
//! `com.apple.Notes` scripting suite:
//!
//! ```applescript
//! tell application "Notes"
//!   set noteList to every note whose modification date > (my epochToDate:sinceUnix)
//!   ...
//! end tell
//! ```
//!
//! The wire-up PR (cycle 8.60+) will drive this via `osascript` (spawn
//! a short-lived subprocess) or the `objc2-osakit` crate, and parse the
//! rendered plain-text output — Notes returns HTML by default; the
//! wire-up asks for `plaintext` where possible.
//!
//! ## TCC requirement (documented; not yet exercised)
//!
//! AppleScript against Notes.app requires **Automation TCC per-target for
//! Notes**. First-time send prompts. The wire-up PR must add:
//!
//! - `NSAppleEventsUsageDescription` in the agent + Hippocampus.app
//!   bundles (already present for browser AppleScript).
//! - A permission-status probe (`AEDeterminePermissionToAutomateTarget`)
//!   that surfaces [`NotesReaderError::AccessDenied`] on `errAEEventNotPermitted`.
//! - The onboarding UI card that deep-links into System Settings →
//!   Privacy & Security → Automation → (agent binary) → Notes.
//!
//! ## What this crate does NOT do
//!
//! - Does not spawn `osascript`. Does not link `OSAKit`. Does not touch
//!   the undocumented `NoteStore.sqlite`.
//! - Does not implement a cascade-equivalent (deferred to the wire-up PR).
//! - Does not inspect real user notes. All tests exercise the empty stub.
//!
//! ## ADR pointers
//!
//! - `docs/decisions/0032-deep-hook-plugin-contract.md` — the deep-hook
//!   plugin contract this scaffold implements the shape of.
//! - `docs/decisions/0037-deep-hook-plugins-calendar-notes-reminders-scaffold.md`
//!   — this scaffold's ADR (Proposed).

pub mod error;
pub mod notes;
pub mod watch;

pub use error::NotesReaderError;
pub use notes::{read_events_since, read_notes_since, Note, NoteFolder, Timestamp};
pub use watch::{watch_notes, InboxWatcher, NoteChangeEvent};
