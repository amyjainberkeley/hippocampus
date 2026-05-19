//! The key-wrap seam.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. ADR-0008 §"Key custody" #2:
//! the DB master key is **wrapped by a Keychain-stored wrapping key**
//! (macOS Secure Enclave; biometry-current-set; non-exportable;
//! `…ThisDeviceOnly`).
//!
//! That production wrap touches `Security.framework` and is therefore
//! **OS-specific** — by the cross-platform-seam invariant
//! (`AGENT_PROTOCOL` §4) it MUST live in `adapters/macos/`, never in
//! `core/`. So this module ships:
//!
//! - [`KeyWrap`] — the portable trait the store-open path depends on.
//!   The macOS adapter implements it over the Secure-Enclave item;
//!   a future Windows adapter implements it over DPAPI-NG/TPM.
//! - `InMemoryKeyWrap` — a **test-only** wrap. It holds the wrapped
//!   bytes in process memory and provides **no at-rest
//!   confidentiality whatsoever**. It exists so the encrypted-store
//!   round-trip can be proven headlessly on a non-macOS CI runner.
//!   Shipping it in a release build is a CSO-blocking defect, so it
//!   is **physically uncompilable in a shipped build**:
//!     - the type, its `KeyWrap` impl, and its tests are behind
//!       `#[cfg(any(test, feature = "insecure-test-keywrap"))]`;
//!     - `insecure-test-keywrap` is **not** in any default feature
//!       set and is **not** enabled by `apps/agent` (the shipped
//!       binary), so a release build of the agent never even names
//!       the type;
//!     - a **compile-time tripwire** (`compile_error!` below) fails
//!       the build outright if the feature is ever enabled in an
//!       optimized, non-`cfg(test)` build — defence in depth so a
//!       future `Cargo.toml` edit cannot smuggle it into a release.
//!
//! The trait is deliberately tiny: `wrap` + `unwrap`. Key custody
//! policy (biometric gate, SE residency, rotation) lives entirely in
//! the adapter impl; core only needs "give me the unwrapped
//! [`DbKey`]" at store-open time.

use zeroize::Zeroize;

use super::db_key::DbKey;

/// Opaque wrapped-key blob. The bytes are whatever the concrete
/// [`KeyWrap`] produced — for the macOS adapter, the Secure-Enclave
/// ciphertext; for [`InMemoryKeyWrap`], the plaintext (test only).
///
/// Persisted by the agent **outside** this crate (ADR-0008: the
/// public wrap descriptor goes in `meta`/Keychain; never the
/// unwrapped key). Zeroizes on drop defensively.
#[derive(Clone, PartialEq, Eq)]
pub struct WrappedKey(Vec<u8>);

impl WrappedKey {
    /// Wrap raw blob bytes produced by a [`KeyWrap`] implementation.
    #[must_use]
    pub fn from_vec(v: Vec<u8>) -> Self {
        Self(v)
    }

    /// Borrow the opaque bytes for persistence by the agent layer.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for WrappedKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl core::fmt::Debug for WrappedKey {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // Length is non-sensitive; bytes are not printed.
        write!(f, "WrappedKey(<{} opaque bytes>)", self.0.len())
    }
}

/// Errors a wrap / unwrap may surface. Concrete adapters map their
/// platform errors (Keychain `OSStatus`, biometric cancel, etc) into
/// these.
#[derive(Debug, thiserror::Error)]
pub enum KeyWrapError {
    /// The wrapping operation failed (e.g. Secure-Enclave key
    /// generation refused, user cancelled the biometric prompt).
    #[error("key wrap failed: {0}")]
    Wrap(String),
    /// The unwrapping operation failed (e.g. wrong device, biometric
    /// gate denied, corrupt wrap blob, wrap produced the wrong length).
    #[error("key unwrap failed: {0}")]
    Unwrap(String),
}

/// The portable key-wrap contract the store-open path depends on.
///
/// Implementations MUST guarantee `unwrap(wrap(k)) == k` for a key
/// they wrapped on the same device, and MUST fail (`Err`) rather than
/// return a wrong key when the wrap is not unwrappable here (wrong
/// device, denied biometric, tampered blob).
pub trait KeyWrap {
    /// Wrap a freshly-generated master key for at-rest storage.
    ///
    /// # Errors
    /// [`KeyWrapError::Wrap`] on platform failure.
    fn wrap(&self, key: &DbKey) -> Result<WrappedKey, KeyWrapError>;

    /// Recover the master key from its wrap at store-open time.
    ///
    /// # Errors
    /// [`KeyWrapError::Unwrap`] if the wrap cannot be opened here.
    fn unwrap_key(&self, wrapped: &WrappedKey) -> Result<DbKey, KeyWrapError>;
}

// ── Release tripwire (CSO, AGENT_PROTOCOL §5 / ADR-0008) ────────────
// The insecure in-memory wrap is gated to `cfg(test)` OR the explicit
// opt-in `insecure-test-keywrap` feature (for downstream integration
// test crates that cannot see this crate's `cfg(test)`). It must NEVER
// reach a shipped binary. `cargo test` sets `cfg(test)`; a normal
// `cargo build`/`--release` of the agent enables neither and so never
// compiles the type at all. As defence in depth, if the feature is
// somehow enabled in an optimized build OUTSIDE `cfg(test)`
// (`debug_assertions` off ⇒ release profile), refuse to compile —
// a future Cargo.toml edit cannot silently smuggle it into a release.
#[cfg(all(feature = "insecure-test-keywrap", not(test), not(debug_assertions)))]
compile_error!(
    "InMemoryKeyWrap is TEST-ONLY and provides no at-rest confidentiality. \
     The `insecure-test-keywrap` feature must never be enabled in a release \
     build. This is a CSO-blocking misconfiguration (ADR-0008, AGENT_PROTOCOL §5)."
);

/// **TEST-ONLY** in-memory wrap. Stores the key bytes verbatim.
///
/// Provides NO confidentiality. Its only purpose is to let the
/// encrypted-store round-trip be proven on a headless / non-macOS
/// runner where the Secure-Enclave adapter is unavailable. A release
/// build that constructs this is a CSO-blocking defect; the agent
/// shell wires the macOS adapter's `KeyWrap`, never this.
///
/// Compiled only under `#[cfg(any(test, feature =
/// "insecure-test-keywrap"))]` — absent entirely from the shipped
/// agent binary (see the release tripwire above).
#[cfg(any(test, feature = "insecure-test-keywrap"))]
#[derive(Debug, Default)]
pub struct InMemoryKeyWrap;

#[cfg(any(test, feature = "insecure-test-keywrap"))]
impl KeyWrap for InMemoryKeyWrap {
    fn wrap(&self, key: &DbKey) -> Result<WrappedKey, KeyWrapError> {
        Ok(WrappedKey::from_vec(key.expose_bytes().to_vec()))
    }

    fn unwrap_key(&self, wrapped: &WrappedKey) -> Result<DbKey, KeyWrapError> {
        let bytes: [u8; super::db_key::DB_KEY_LEN] = wrapped
            .as_bytes()
            .try_into()
            .map_err(|_| KeyWrapError::Unwrap("wrap blob is not 32 bytes".into()))?;
        Ok(DbKey::from_bytes(bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_wrap_round_trips() {
        let w = InMemoryKeyWrap;
        let k = DbKey::from_bytes([0x5Au8; super::super::db_key::DB_KEY_LEN]);
        let wrapped = w.wrap(&k).expect("wrap");
        let back = w.unwrap_key(&wrapped).expect("unwrap");
        assert_eq!(k, back, "unwrap(wrap(k)) must equal k");
    }

    #[test]
    fn in_memory_unwrap_rejects_wrong_length() {
        let w = InMemoryKeyWrap;
        let bad = WrappedKey::from_vec(vec![0u8; 16]);
        let err = w.unwrap_key(&bad).unwrap_err();
        assert!(matches!(err, KeyWrapError::Unwrap(_)));
    }

    #[test]
    fn wrapped_key_debug_does_not_leak_bytes() {
        let wk = WrappedKey::from_vec(vec![0xDEu8; 32]);
        let s = format!("{wk:?}");
        assert_eq!(s, "WrappedKey(<32 opaque bytes>)");
        assert!(!s.contains("de"), "Debug must not print wrap bytes");
    }

    #[test]
    fn distinct_keys_wrap_distinctly_in_memory() {
        let w = InMemoryKeyWrap;
        let a = w
            .wrap(&DbKey::from_bytes([1u8; super::super::db_key::DB_KEY_LEN]))
            .unwrap();
        let b = w
            .wrap(&DbKey::from_bytes([2u8; super::super::db_key::DB_KEY_LEN]))
            .unwrap();
        assert_ne!(a, b);
    }
}
