// V2-P8a — Mail.app read path (read-only library).
//
// Gate the entire crate body on macOS — the deps are gated to the same
// target in `Cargo.toml`, so on Linux this crate compiles to an empty
// library. Same pattern as `mci-embed-coreml` / `mci-llama-coreml`.
#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

//! `mci-mail-reader` — V2-P8a Mail.app read path.
//!
//! READ-ONLY library exposing four entry points:
//!
//! - [`discover_accounts`] — locate `~/Library/Mail/V<N>/` (glob-discover, not
//!   hardcoded) and enumerate per-account UUID directories.
//! - [`list_recent_messages`] — open `MailData/Envelope Index` read-only
//!   (WAL-aware) and return [`EmlxMetadata`] rows since a watermark.
//! - [`read_message`] — split an `.emlx` file into its three segments and
//!   return [`ParsedMessage`] (headers + `body_text` + `body_html` + plist trailer).
//! - [`watch_inbox`] — FSEvents-backed stream of [`NewMessageEvent`]s.
//!
//! ## TCC requirement
//!
//! Reading `~/Library/Mail/V<N>/` requires **Full Disk Access** on macOS
//! (Sequoia onward; carries into macOS 26). Without it every read returns
//! `EPERM`. The errors returned by this crate surface that distinction —
//! see [`MailReaderError::AccessDenied`]. Onboarding UX (the user-curated
//! allowlist surface) ships in V2-P10; the V2-P8a CLI (`mail-reader`)
//! prints a one-line "grant Full Disk Access" hint on this error.
//!
//! ## What V2-P8a does NOT do
//!
//! - Does not ingest. Does not write the brain. Does not emit
//!   `CaptureEvent::MailEnvelope` on the wire.
//! - Does not touch ADR-0030 §3(c) (the OCR-path Mail header check). The
//!   parsed-header check (§3(c)(ii)) lands in V2-P8b along with the
//!   cascade-equivalent and the redaction corpus.
//! - Does not inspect real user mail. All tests use synthesized fixtures
//!   in `tests/fixtures/` with fake names and redacted bodies.
//!
//! ## Background
//!
//! Spike memo: `docs/research/mail-envelope-schema-2026-05-29.md`
//! (the §1 layout, §3 emlx 3-segment shape, §4 Envelope Index schema,
//! §6 read-API choice, §7 watch model, §8 TCC posture).

pub mod discover;
pub mod emlx;
pub mod envelope;
pub mod error;
pub mod parse;
pub mod watch;

pub use discover::{discover_accounts, MailAccount, MailDataRoot};
pub use emlx::{split_emlx, EmlxParts};
pub use envelope::{list_recent_messages, EmlxMetadata};
pub use error::MailReaderError;
pub use parse::{read_message, ParsedAddress, ParsedMessage};
pub use watch::{watch_inbox, NewMessageEvent};
