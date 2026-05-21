//! MCI Workspace Server — Tier-2 encrypted brief store.
//!
//! **PROTECTED-SET per `AGENT_PROTOCOL` §5.** ADR-0019: the workspace server
//! holds ONLY ciphertext + opaque key-wraps. It never decrypts brief content.
//!
//! This crate provides:
//! - [`model`] — domain types (`WorkspaceId`, `MemberId`, `BriefEnvelope`, enrollment types).
//! - [`store`] — `WorkspaceStore` trait + in-memory impl for tests/dev.
//! - [`handlers`] — axum HTTP routes.
//! - [`enrollment`] — existing-member-vouches state machine (skeleton).
//!
//! **Layering invariant:** this crate does NOT depend on `mci-brain`. The server
//! holds ciphertext, not events. `BriefEnvelope` has NO plaintext fields.
//!
//! Real crypto (AEAD, key derivation) is stubbed — `NoopKeyWrap` identity-transforms
//! for the test surface. Real crypto lands in a follow-on PR with explicit CSO sign-off.

pub mod enrollment;
pub mod handlers;
pub mod model;
pub mod store;
