//! Production cryptographic primitives for the workspace server.
//!
//! PROTECTED-SET (`AGENT_PROTOCOL` §5). ADR-0019 §4.
//!
//! - [`aead`]: AES-256-GCM authenticated encryption via `ring 0.17`.
//! - [`key_wrap`]: X25519 ECDH + HKDF-SHA256 + AES-GCM per-member key wrapping.
//!
//! **NO BACKDOOR KEY (ADR-0019 §4.10):** the server binary never calls
//! `aead::decrypt` or `key_wrap::unwrap`. Those exist for client-side use only.
//! Integration tests pin this via source-level assertions.

pub mod aead;
pub mod key_wrap;

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("encryption failed")]
    EncryptionFailed,
    #[error("decryption failed: ciphertext may be tampered or key is wrong")]
    DecryptionFailed,
    #[error("invalid key length: expected {expected}, got {actual}")]
    InvalidKeyLength { expected: usize, actual: usize },
}
