//! MCI portable core.
//!
//! The portable Rust core owns everything that is not OS-specific: the capture
//! pipeline, dedupe, OCR orchestration, the brain, encryption, sync. Native
//! capture/context adapters (Swift on macOS, Rust + `windows-rs` on Windows)
//! implement the [`capture::CaptureSource`] trait. See:
//!
//! - `docs/decisions/0002-stack-split-rust-core-native-adapters.md`
//! - `docs/decisions/0003-capturesource-trait-seam-macos-first.md`
//! - `docs/decisions/0005-cargo-workspace-edition-2021-msrv.md`
//! - `docs/decisions/0006-capturesource-trait-shape-async-push.md`
//!
//! Nothing in this crate may contain OS-specific code. `#[cfg(target_os = …)]`,
//! `objc2::…`, `windows::…`, and Swift type bindings live under
//! `adapters/<os>/` only. This is the cross-platform-seam invariant
//! (`AGENT_PROTOCOL` §4).

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod capture;
pub mod error;
pub mod ipc;
pub mod store;

pub use error::CoreError;
