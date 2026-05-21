//! AES-256-GCM authenticated encryption with associated data.
//!
//! Uses `ring 0.17` (audited, same lib as rustls). 96-bit random nonce per
//! encrypt call. AAD binds ciphertext to context (`workspace_id` + `ts_us`).
//!
//! Fail-closed: tampered ciphertext or wrong key/AAD/nonce always returns
//! `CryptoError::DecryptionFailed`, never degrades to plaintext pass-through.

use ring::aead::{Aad, LessSafeKey, Nonce as RingNonce, UnboundKey, AES_256_GCM};
use ring::rand::{SecureRandom, SystemRandom};

use super::CryptoError;

/// 256-bit AES key.
pub struct AeadKey([u8; 32]);

impl AeadKey {
    #[must_use]
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn generate() -> Result<Self, CryptoError> {
        let rng = SystemRandom::new();
        let mut key = [0u8; 32];
        rng.fill(&mut key)
            .map_err(|_| CryptoError::EncryptionFailed)?;
        Ok(Self(key))
    }

    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// 96-bit nonce for AES-GCM.
pub struct AeadNonce(pub [u8; 12]);

/// Encrypt plaintext with AES-256-GCM.
///
/// Returns `(ciphertext || tag, nonce)`. Nonce is 96-bit random per call.
/// AAD is authenticated but not encrypted.
pub fn encrypt(
    plaintext: &[u8],
    key: &AeadKey,
    aad: &[u8],
) -> Result<(Vec<u8>, AeadNonce), CryptoError> {
    let rng = SystemRandom::new();
    let mut nonce_bytes = [0u8; 12];
    rng.fill(&mut nonce_bytes)
        .map_err(|_| CryptoError::EncryptionFailed)?;

    let unbound =
        UnboundKey::new(&AES_256_GCM, &key.0).map_err(|_| CryptoError::EncryptionFailed)?;
    let sealing_key = LessSafeKey::new(unbound);
    let nonce = RingNonce::try_assume_unique_for_key(&nonce_bytes)
        .map_err(|_| CryptoError::EncryptionFailed)?;

    let mut in_out = plaintext.to_vec();
    sealing_key
        .seal_in_place_append_tag(nonce, Aad::from(aad), &mut in_out)
        .map_err(|_| CryptoError::EncryptionFailed)?;

    Ok((in_out, AeadNonce(nonce_bytes)))
}

/// Decrypt `ciphertext || tag` with AES-256-GCM.
///
/// Returns plaintext. Fails closed on tamper (tag mismatch or wrong key/AAD).
pub fn decrypt(
    ciphertext_with_tag: &[u8],
    nonce: &AeadNonce,
    key: &AeadKey,
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let unbound =
        UnboundKey::new(&AES_256_GCM, &key.0).map_err(|_| CryptoError::DecryptionFailed)?;
    let opening_key = LessSafeKey::new(unbound);
    let ring_nonce = RingNonce::try_assume_unique_for_key(&nonce.0)
        .map_err(|_| CryptoError::DecryptionFailed)?;

    let mut in_out = ciphertext_with_tag.to_vec();
    let plaintext = opening_key
        .open_in_place(ring_nonce, Aad::from(aad), &mut in_out)
        .map_err(|_| CryptoError::DecryptionFailed)?;

    Ok(plaintext.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn round_trip() {
        let key = AeadKey::generate().unwrap();
        let plaintext = b"approved brief content from Phase 4";
        let aad = b"workspace_id:abc123,ts_us:1234567890";

        let (ciphertext, nonce) = encrypt(plaintext, &key, aad).unwrap();
        assert_ne!(&ciphertext[..plaintext.len()], &plaintext[..]);

        let decrypted = decrypt(&ciphertext, &nonce, &key, aad).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn tamper_detection_flipped_byte() {
        let key = AeadKey::generate().unwrap();
        let (mut ct, nonce) = encrypt(b"sensitive brief data", &key, b"ws:test").unwrap();

        ct[0] ^= 0xFF;

        assert!(
            decrypt(&ct, &nonce, &key, b"ws:test").is_err(),
            "tampered ciphertext must be rejected"
        );
    }

    #[test]
    fn tamper_detection_truncated() {
        let key = AeadKey::generate().unwrap();
        let (ct, nonce) = encrypt(b"data", &key, b"").unwrap();

        assert!(
            decrypt(&ct[..ct.len() - 1], &nonce, &key, b"").is_err(),
            "truncated ciphertext must be rejected"
        );
    }

    #[test]
    fn wrong_aad_rejected() {
        let key = AeadKey::generate().unwrap();
        let (ct, nonce) = encrypt(b"brief", &key, b"correct aad").unwrap();

        assert!(
            decrypt(&ct, &nonce, &key, b"wrong aad").is_err(),
            "wrong AAD must be rejected"
        );
    }

    #[test]
    fn wrong_key_rejected() {
        let key1 = AeadKey::generate().unwrap();
        let key2 = AeadKey::generate().unwrap();
        let (ct, nonce) = encrypt(b"brief", &key1, b"aad").unwrap();

        assert!(
            decrypt(&ct, &nonce, &key2, b"aad").is_err(),
            "wrong key must be rejected"
        );
    }

    #[test]
    fn wrong_nonce_rejected() {
        let key = AeadKey::generate().unwrap();
        let (ct, _nonce) = encrypt(b"brief", &key, b"aad").unwrap();
        let wrong_nonce = AeadNonce([0xFF; 12]);

        assert!(
            decrypt(&ct, &wrong_nonce, &key, b"aad").is_err(),
            "wrong nonce must be rejected"
        );
    }

    #[test]
    fn nonce_uniqueness_10k() {
        let key = AeadKey::generate().unwrap();
        let mut nonces = HashSet::new();
        for _ in 0..10_000 {
            let (_, nonce) = encrypt(b"x", &key, b"").unwrap();
            assert!(nonces.insert(nonce.0), "nonce collision detected");
        }
        assert_eq!(nonces.len(), 10_000);
    }

    #[test]
    fn ciphertext_differs_same_plaintext() {
        let key = AeadKey::generate().unwrap();
        let (ct1, _) = encrypt(b"same", &key, b"aad").unwrap();
        let (ct2, _) = encrypt(b"same", &key, b"aad").unwrap();

        assert_ne!(ct1, ct2, "random nonce must produce different ciphertext");
    }

    #[test]
    fn empty_plaintext_round_trip() {
        let key = AeadKey::generate().unwrap();
        let (ct, nonce) = encrypt(b"", &key, b"aad").unwrap();
        assert!(!ct.is_empty(), "ciphertext includes tag even for empty plaintext");

        let decrypted = decrypt(&ct, &nonce, &key, b"aad").unwrap();
        assert!(decrypted.is_empty());
    }

    #[test]
    fn empty_aad_round_trip() {
        let key = AeadKey::generate().unwrap();
        let (ct, nonce) = encrypt(b"data", &key, b"").unwrap();
        let decrypted = decrypt(&ct, &nonce, &key, b"").unwrap();
        assert_eq!(decrypted, b"data");
    }
}
