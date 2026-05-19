//! The 256-bit `SQLCipher` master key.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. ADR-0008 §"Key custody" #1:
//! *"DB master key = a random 256-bit key, generated at first run
//! inside the Rust core's CSPRNG (the OS RNG via `getrandom`)."*
//!
//! Discipline enforced here:
//! - bytes are generated from the OS CSPRNG ([`getrandom`]), never a
//!   userspace PRNG;
//! - the buffer zeroizes on drop ([`zeroize`]);
//! - no `Debug` / `Display` / `serde` ever renders the bytes — the
//!   derived `Debug` is hand-replaced with a redacted form;
//! - the only escape hatch is [`DbKey::expose_sqlcipher_pragma_value`],
//!   which yields the `x'…'` raw-key literal `SQLCipher`'s `PRAGMA key`
//!   expects. ADR-0008: the master key is a *raw* 256-bit key, so the
//!   `x'<64-hex>'` form is used (`SQLCipher` then skips PBKDF2 and uses
//!   the bytes directly — correct for a already-random key).

use zeroize::{Zeroize, ZeroizeOnDrop};

/// Length of the `SQLCipher` master key in bytes (256 bits).
pub const DB_KEY_LEN: usize = 32;

/// Errors generating a fresh key.
#[derive(Debug, thiserror::Error)]
pub enum KeyGenError {
    /// The OS CSPRNG failed. Treated as fatal by callers — there is no
    /// safe fallback RNG for a master key.
    #[error("OS CSPRNG (getrandom) failed: {0}")]
    Csprng(String),
}

/// A 256-bit `SQLCipher` master key.
///
/// Zeroizes on drop. Never logs, never serializes, never `Debug`-
/// prints its bytes. Construct via [`DbKey::generate`] (production) or
/// [`DbKey::from_bytes`] (deterministic test / re-open path).
#[derive(Clone, Zeroize, ZeroizeOnDrop, PartialEq, Eq)]
pub struct DbKey {
    bytes: [u8; DB_KEY_LEN],
}

impl DbKey {
    /// Generate a fresh random key from the OS CSPRNG.
    ///
    /// # Errors
    /// [`KeyGenError::Csprng`] if `getrandom` fails (no fallback — a
    /// master key from a weak RNG is worse than a hard failure).
    pub fn generate() -> Result<Self, KeyGenError> {
        let mut bytes = [0u8; DB_KEY_LEN];
        getrandom::fill(&mut bytes).map_err(|e| KeyGenError::Csprng(e.to_string()))?;
        Ok(Self { bytes })
    }

    /// Construct from explicit bytes. The re-open path (the unwrapped
    /// key coming back from a [`super::KeyWrap`]) and deterministic
    /// tests use this. Production first-run uses [`Self::generate`].
    #[must_use]
    pub const fn from_bytes(bytes: [u8; DB_KEY_LEN]) -> Self {
        Self { bytes }
    }

    /// Borrow the raw bytes. Restricted to the crate so only the
    /// store-open path + the key-wrap impls can reach them; callers
    /// outside `core` cannot exfiltrate the key buffer.
    #[must_use]
    pub(crate) fn expose_bytes(&self) -> &[u8; DB_KEY_LEN] {
        &self.bytes
    }

    /// Render the `PRAGMA key` literal `SQLCipher` expects for a *raw*
    /// 256-bit key: `x'<64 lowercase hex chars>'`.
    ///
    /// `SQLCipher`, given a key of the `x'…'` form whose hex decodes to
    /// exactly the cipher key length, uses the bytes directly and
    /// skips PBKDF2 key-derivation. Correct here because [`DbKey`] is
    /// already a uniformly-random 256-bit key (ADR-0008 §"Key custody"
    /// #1) — running PBKDF2 over an already-random key adds nothing.
    ///
    /// The returned `String` contains key material. Callers MUST pass
    /// it straight into the `PRAGMA key = …` statement and drop it;
    /// it must never be logged, stored, or returned upward. The store
    /// module is the only caller.
    #[must_use]
    pub(crate) fn expose_sqlcipher_pragma_value(&self) -> SqlcipherPragmaValue {
        let mut s = String::with_capacity(DB_KEY_LEN * 2 + 3);
        s.push_str("x'");
        for b in &self.bytes {
            // Lowercase hex, two chars per byte.
            s.push(char::from_digit(u32::from(b >> 4), 16).expect("nibble<16"));
            s.push(char::from_digit(u32::from(b & 0x0f), 16).expect("nibble<16"));
        }
        s.push('\'');
        SqlcipherPragmaValue(s)
    }
}

/// A wrapper around the `x'…'` `SQLCipher` key literal whose `Drop`
/// zeroizes the backing string. Keeps the key material from lingering
/// in a `String` on the heap after the `PRAGMA key` call.
pub(crate) struct SqlcipherPragmaValue(String);

impl SqlcipherPragmaValue {
    /// Borrow the literal for the single `PRAGMA key = …` execution.
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl Drop for SqlcipherPragmaValue {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Redacted `Debug` — never the bytes. A leaked log line that prints a
/// `DbKey` must reveal nothing.
impl core::fmt::Debug for DbKey {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("DbKey(<redacted 256-bit>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_produces_distinct_keys() {
        let a = DbKey::generate().expect("csprng");
        let b = DbKey::generate().expect("csprng");
        // 256-bit random collision is cryptographically impossible;
        // a failure here means the RNG is broken / stubbed.
        assert_ne!(
            a.expose_bytes(),
            b.expose_bytes(),
            "two generated keys must differ"
        );
    }

    #[test]
    fn generate_is_not_all_zero() {
        let k = DbKey::generate().expect("csprng");
        assert_ne!(k.expose_bytes(), &[0u8; DB_KEY_LEN], "key must not be zero");
    }

    #[test]
    fn from_bytes_round_trips() {
        let raw = [7u8; DB_KEY_LEN];
        let k = DbKey::from_bytes(raw);
        assert_eq!(k.expose_bytes(), &raw);
    }

    #[test]
    fn debug_is_redacted() {
        let k = DbKey::from_bytes([0xABu8; DB_KEY_LEN]);
        let s = format!("{k:?}");
        assert_eq!(s, "DbKey(<redacted 256-bit>)");
        assert!(!s.contains("ab"), "Debug must not leak key bytes");
    }

    #[test]
    fn pragma_value_is_lowercase_hex_x_literal() {
        let k = DbKey::from_bytes([0x0fu8; DB_KEY_LEN]);
        let p = k.expose_sqlcipher_pragma_value();
        let s = p.as_str();
        assert!(s.starts_with("x'"));
        assert!(s.ends_with('\''));
        // 0x0f → "0f", 32 times.
        assert_eq!(s, format!("x'{}'", "0f".repeat(DB_KEY_LEN)));
    }

    #[test]
    fn pragma_value_round_trips_known_bytes() {
        let mut raw = [0u8; DB_KEY_LEN];
        for (i, b) in raw.iter_mut().enumerate() {
            *b = u8::try_from(i).expect("0..32 fits u8");
        }
        let k = DbKey::from_bytes(raw);
        let p = k.expose_sqlcipher_pragma_value();
        // First bytes 00 01 02 03 …
        assert!(p.as_str().starts_with("x'000102030405"));
        assert_eq!(p.as_str().len(), DB_KEY_LEN * 2 + 3); // x' + 64 + '
    }

    #[test]
    fn equality_is_value_based() {
        let a = DbKey::from_bytes([1u8; DB_KEY_LEN]);
        let b = DbKey::from_bytes([1u8; DB_KEY_LEN]);
        let c = DbKey::from_bytes([2u8; DB_KEY_LEN]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }
}
