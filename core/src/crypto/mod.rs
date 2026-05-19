//! At-rest cryptography for the MCI store.
//!
//! **PROTECTED-SET per `AGENT_PROTOCOL` §5** (at-rest crypto + key
//! custody). Binding ADR:
//! `docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md`.
//!
//! This module owns the **portable** half of the key model:
//!
//! - [`DbKey`] — a random 256-bit `SQLCipher` master key that zeroizes
//!   on drop and never `Debug`-prints, never serializes, never logs
//!   its bytes.
//! - [`KeyWrap`] — the trait the store uses to obtain the unwrapped
//!   master key. The **production** implementation is the macOS
//!   Secure-Enclave / Keychain wrap described in ADR-0008 §"Key
//!   custody". That implementation is **OS-specific and therefore
//!   lives in `adapters/macos/`, not here** — the cross-platform-seam
//!   invariant (`AGENT_PROTOCOL` §4) forbids `Security.framework` /
//!   `objc2` in `core/`. Core ships the trait + an in-memory test
//!   wrap ([`InMemoryKeyWrap`]) only.
//!
//! What core does **not** do (ADR-0008 forces, binding):
//! - never accept a DB key from argv / env / a config file;
//! - never enable `SQLite` extension loading from arbitrary paths;
//! - never put the unwrapped key in a third place beyond (a) the
//!   OS keystore wrap and (b) the locked in-memory buffer.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! The portable key type + wrap trait below were authored under the
//! CSO role-mask against ADR-0008. The Keychain/Secure-Enclave
//! production wrap is explicitly deferred to the macOS adapter (it is
//! OS-specific by construction); `InMemoryKeyWrap` is a **test-only**
//! wrap and is documented as such — it provides NO at-rest
//! confidentiality and must never be used in a shipped build. Any
//! change to `DbKey`'s zeroization, the `KeyWrap` contract, or the
//! raw-key PRAGMA derivation is a fresh CSO review.
//!
//! — CSO role-mask, 2026-05-19

pub mod db_key;
pub mod key_wrap;

pub use db_key::{DbKey, KeyGenError};
pub use key_wrap::{InMemoryKeyWrap, KeyWrap, KeyWrapError, WrappedKey};
