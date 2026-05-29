// V2-P7 — Messages.app read path (read-only library).
//
// Gate the entire crate body on macOS — the deps are gated to the same
// target in `Cargo.toml`, so on Linux this crate compiles to an empty
// library. Same pattern as `mci-mail-reader` / `mci-embed-coreml`.
#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

//! `mci-messages-reader` — V2-P7 Messages.app read path.
//!
//! READ-ONLY library exposing three entry points:
//!
//! - [`discover_chat_db`] — locate `~/Library/Messages/chat.db` (glob-discover
//!   `$HOME`, not hardcoded) and confirm readability.
//! - [`list_recent_messages`] — open `chat.db` read-only (WAL-aware) and
//!   return [`MessageRow`] rows whose Apple-absolute timestamp converts to
//!   a unix-seconds value ≥ a watermark.
//! - [`read_thread`] — return a [`Thread`] for one `chat.ROWID` with its
//!   `participants` (handles) and `messages` ordered ascending by date.
//! - [`watch_inbox`] — FSEvents-backed stream of [`NewMessageEvent`]s
//!   fired when Messages.app touches `chat.db` / `chat.db-wal`.
//!
//! ## TCC requirement
//!
//! Reading `~/Library/Messages/` requires **Full Disk Access** on macOS
//! (Sequoia onward; carries into macOS 26). Without it every read returns
//! `EPERM`. The errors returned by this crate surface that distinction —
//! see [`MessagesReaderError::AccessDenied`]. Onboarding UX (the user-curated
//! allowlist surface) ships in V2-P10; the V2-P7 CLI (`messages-reader`)
//! prints a one-line "grant Full Disk Access" hint on this error.
//!
//! ## What V2-P7 does NOT do
//!
//! - Does not ingest. Does not write the brain. Does not emit
//!   `CaptureEvent::MessagesThread` on the wire.
//! - Does not edit `known-safe-apps.toml` (`com.apple.MobileSMS` is already
//!   on the cascade allowlist per cycle 8.16 PR #228; the deep-hook plugin
//!   contract is an *additional* ingest path, not a relaxation).
//! - Does not inspect real user Messages content. All tests use synthesized
//!   fixtures in `tests/fixtures/` with fake handles and synthetic bodies.
//!
//! ## ADR pointers
//!
//! - `docs/decisions/0030-messages-mail-redaction-threat-model.md` §3(f)
//!   — the per-plugin redaction extension this read path feeds.
//! - `docs/decisions/0032-deep-hook-plugin-contract.md` — the deep-hook
//!   plugin contract: cascade-equivalent gate, no OCR, brain ingest via
//!   the existing trait, FDA onboarding, per-plugin redaction extension
//!   pattern.
//! - `docs/research/brain-architecture-v2-vision-2026-05-29.md` §5.5
//!   + §7.3 V2-P7 — the architectural source of this crate.

pub mod discover;
pub mod error;
pub mod messages;
pub mod watch;

pub use discover::{discover_chat_db, ChatDbLocation};
pub use error::MessagesReaderError;
pub use messages::{
    list_recent_messages, read_thread, ChatService, MessageRow, ParticipantHandle, Thread,
    APPLE_EPOCH_OFFSET_SECS,
};
pub use watch::{watch_inbox, watch_path, InboxWatcher, NewMessageEvent};
