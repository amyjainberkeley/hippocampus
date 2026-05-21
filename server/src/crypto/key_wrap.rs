//! X25519 ECDH + HKDF-SHA256 + AES-256-GCM per-member key wrapping.
//!
//! Wraps a 256-bit workspace key for a specific member's X25519 public key.
//! [`unwrap`] requires the member's private key — the server NEVER has one.
//!
//! Pattern: ECIES (Elliptic Curve Integrated Encryption Scheme). The wrapper
//! generates an ephemeral X25519 keypair, performs ECDH, derives an AES key
//! via HKDF-SHA256, and encrypts the workspace key under AES-256-GCM.

use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, StaticSecret};

use super::aead::{self, AeadKey, AeadNonce};
use super::CryptoError;

const HKDF_INFO: &[u8] = b"mci-workspace-key-wrap-v1";

/// A wrapped key: workspace key encrypted under an ECDH-derived AES key.
#[derive(Debug, Clone)]
pub struct WrappedKey {
    /// Ephemeral X25519 public key (32 bytes).
    pub ephemeral_pub: [u8; 32],
    /// AES-256-GCM ciphertext of the 32-byte workspace key (+ 16-byte tag).
    pub ciphertext: Vec<u8>,
    /// AES-GCM nonce (12 bytes).
    pub nonce: [u8; 12],
}

/// Wire format: `ephemeral_pub (32) || nonce (12) || ciphertext (var)`.
const HEADER_LEN: usize = 32 + 12;

impl WrappedKey {
    /// Serialize for storage in `MemberKeyWrap.wrapped_key`.
    #[must_use]
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.ciphertext.len());
        out.extend_from_slice(&self.ephemeral_pub);
        out.extend_from_slice(&self.nonce);
        out.extend_from_slice(&self.ciphertext);
        out
    }

    /// Deserialize from bytes.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CryptoError> {
        if bytes.len() < HEADER_LEN {
            return Err(CryptoError::InvalidKeyLength {
                expected: HEADER_LEN,
                actual: bytes.len(),
            });
        }
        let mut ephemeral_pub = [0u8; 32];
        ephemeral_pub.copy_from_slice(&bytes[..32]);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&bytes[32..HEADER_LEN]);
        let ciphertext = bytes[HEADER_LEN..].to_vec();
        Ok(Self {
            ephemeral_pub,
            ciphertext,
            nonce,
        })
    }
}

fn derive_wrap_key(shared_secret: &[u8]) -> Result<AeadKey, CryptoError> {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut okm = [0u8; 32];
    hk.expand(HKDF_INFO, &mut okm)
        .map_err(|_| CryptoError::EncryptionFailed)?;
    Ok(AeadKey::from_bytes(okm))
}

/// Wrap a 256-bit workspace key for a member's X25519 public key.
///
/// Generates an ephemeral keypair, ECDH → HKDF → AES-GCM encrypt.
pub fn wrap(
    workspace_key: &[u8; 32],
    member_pubkey: &PublicKey,
) -> Result<WrappedKey, CryptoError> {
    let ephemeral_secret = EphemeralSecret::random();
    let ephemeral_pub = PublicKey::from(&ephemeral_secret);

    let shared = ephemeral_secret.diffie_hellman(member_pubkey);
    let aes_key = derive_wrap_key(shared.as_bytes())?;

    let (ciphertext, nonce) = aead::encrypt(workspace_key, &aes_key, b"")?;

    Ok(WrappedKey {
        ephemeral_pub: ephemeral_pub.to_bytes(),
        ciphertext,
        nonce: nonce.0,
    })
}

/// Unwrap a workspace key using the member's X25519 private key.
///
/// **The server NEVER calls this.** Only the client holds private keys.
pub fn unwrap(
    wrapped: &WrappedKey,
    member_private: &StaticSecret,
) -> Result<[u8; 32], CryptoError> {
    let ephemeral_pub = PublicKey::from(wrapped.ephemeral_pub);
    let shared = member_private.diffie_hellman(&ephemeral_pub);
    let aes_key = derive_wrap_key(shared.as_bytes())?;

    let plaintext = aead::decrypt(&wrapped.ciphertext, &AeadNonce(wrapped.nonce), &aes_key, b"")?;

    if plaintext.len() != 32 {
        return Err(CryptoError::InvalidKeyLength {
            expected: 32,
            actual: plaintext.len(),
        });
    }

    let mut key = [0u8; 32];
    key.copy_from_slice(&plaintext);
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member_keypair() -> (StaticSecret, PublicKey) {
        let private = StaticSecret::random();
        let public = PublicKey::from(&private);
        (private, public)
    }

    #[test]
    fn round_trip() {
        let (priv_key, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let wrapped = wrap(&workspace_key, &pub_key).unwrap();
        let unwrapped = unwrap(&wrapped, &priv_key).unwrap();

        assert_eq!(unwrapped, workspace_key);
    }

    #[test]
    fn wrong_private_key_fails() {
        let (_, pub_key) = member_keypair();
        let (wrong_priv, _) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let wrapped = wrap(&workspace_key, &pub_key).unwrap();
        assert!(
            unwrap(&wrapped, &wrong_priv).is_err(),
            "wrong private key must fail"
        );
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let (priv_key, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let mut wrapped = wrap(&workspace_key, &pub_key).unwrap();
        wrapped.ciphertext[0] ^= 0xFF;

        assert!(
            unwrap(&wrapped, &priv_key).is_err(),
            "tampered ciphertext must fail"
        );
    }

    #[test]
    fn tampered_ephemeral_pub_fails() {
        let (priv_key, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let mut wrapped = wrap(&workspace_key, &pub_key).unwrap();
        wrapped.ephemeral_pub[0] ^= 0xFF;

        assert!(
            unwrap(&wrapped, &priv_key).is_err(),
            "tampered ephemeral pubkey must fail"
        );
    }

    #[test]
    fn serialization_round_trip() {
        let (priv_key, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0xAB; 32];

        let wrapped = wrap(&workspace_key, &pub_key).unwrap();
        let bytes = wrapped.to_bytes();
        let restored = WrappedKey::from_bytes(&bytes).unwrap();
        let unwrapped = unwrap(&restored, &priv_key).unwrap();

        assert_eq!(unwrapped, workspace_key);
    }

    #[test]
    fn workspace_key_not_visible_in_wrapped_bytes() {
        let (_, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let wrapped = wrap(&workspace_key, &pub_key).unwrap();
        let bytes = wrapped.to_bytes();

        for window in bytes.windows(32) {
            assert_ne!(
                window, &workspace_key[..],
                "workspace key must not appear in plaintext in wrapped output"
            );
        }
    }

    #[test]
    fn different_wraps_produce_different_ciphertext() {
        let (_, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];

        let w1 = wrap(&workspace_key, &pub_key).unwrap();
        let w2 = wrap(&workspace_key, &pub_key).unwrap();

        assert_ne!(
            w1.ephemeral_pub, w2.ephemeral_pub,
            "ephemeral keys must differ"
        );
        assert_ne!(w1.ciphertext, w2.ciphertext, "ciphertext must differ");
    }

    #[test]
    fn multi_member_wrap_each_unwraps_independently() {
        let (priv_a, pub_a) = member_keypair();
        let (priv_b, pub_b) = member_keypair();
        let workspace_key: [u8; 32] = [0xCC; 32];

        let wrap_a = wrap(&workspace_key, &pub_a).unwrap();
        let wrap_b = wrap(&workspace_key, &pub_b).unwrap();

        assert_eq!(unwrap(&wrap_a, &priv_a).unwrap(), workspace_key);
        assert_eq!(unwrap(&wrap_b, &priv_b).unwrap(), workspace_key);

        // Cross-unwrap must fail.
        assert!(unwrap(&wrap_a, &priv_b).is_err());
        assert!(unwrap(&wrap_b, &priv_a).is_err());
    }

    #[test]
    fn from_bytes_rejects_short_input() {
        assert!(WrappedKey::from_bytes(&[0u8; 10]).is_err());
        assert!(WrappedKey::from_bytes(&[0u8; 43]).is_err());
    }

    /// Type-level proof: `unwrap` requires `&StaticSecret`. The server has no
    /// `StaticSecret`; therefore it structurally cannot decrypt workspace keys.
    /// This test documents the invariant — if `unwrap`'s signature ever changes
    /// to not require a private key, this test must be updated and CSO notified.
    #[test]
    fn unwrap_requires_private_key_type_proof() {
        let (priv_key, pub_key) = member_keypair();
        let workspace_key: [u8; 32] = [0x42; 32];
        let wrapped = wrap(&workspace_key, &pub_key).unwrap();

        // The ONLY way to call unwrap is with a StaticSecret.
        // This line proves the type constraint exists.
        let _: [u8; 32] = unwrap(&wrapped, &priv_key).unwrap();
    }
}
