//! MCI Workspace Server — Tier-2 encrypted brief store.
//!
//! **PROTECTED-SET per `AGENT_PROTOCOL` §5.** ADR-0019: the workspace server
//! holds ONLY ciphertext + opaque key-wraps. It never decrypts brief content.
//!
//! This crate provides:
//! - [`crypto`] — AES-256-GCM AEAD + X25519/HKDF per-member key wrapping.
//! - [`model`] — domain types (`WorkspaceId`, `MemberId`, `BriefEnvelope`, enrollment types).
//! - [`store`] — `WorkspaceStore` trait + in-memory impl for tests/dev.
//! - [`handlers`] — axum HTTP routes (ferry opaque bytes only).
//! - [`enrollment`] — existing-member-vouches state machine (skeleton).
//!
//! **Layering invariant:** this crate does NOT depend on `mci-brain`. The server
//! holds ciphertext, not events. `BriefEnvelope` has NO plaintext fields.
//!
//! **NO BACKDOOR KEY (ADR-0019 §4.10):** the server binary (`main.rs`) and HTTP
//! handlers never call `crypto::aead::decrypt` or `crypto::key_wrap::unwrap`.
//! Those primitives exist for client-side use. Integration tests pin this.

pub mod crash_report;
pub mod crypto;
pub mod enrollment;
pub mod handlers;
pub mod model;
pub mod store;
