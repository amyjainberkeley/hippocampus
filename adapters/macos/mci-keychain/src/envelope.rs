//! The sealed-screenshot envelope, in Rust, for re-sealing screenshots when
//! the memory's key changes.
//!
//! The capture helper seals every screenshot with `KeyframeBlobCodec`
//! (`adapters/macos/MCIKeyframeCodec`): `salt[16] || nonce[12] ||
//! ciphertext || tag[16]`, AES-256-GCM under a key derived from the memory's
//! key with HKDF-SHA256, the blob's own salt and the info `mci-blob-v2`. A
//! key change (storage-security review S4) must re-seal every screenshot
//! under the new key, so the agent needs the same envelope. This module is
//! that envelope, byte for byte: the Swift codec's fixed-vector test digest
//! is reproduced in this module's tests.
//!
//! AES-256-GCM runs in the OpenSSL that `SQLCipher` already links into every
//! binary that opens the memory (`libsqlite3-sys`'s vendored OpenSSL), so no
//! new crate or library is added. HMAC and HKDF are a few lines over the
//! `sha2` crate the workspace already uses, checked against RFC 4231 and
//! RFC 5869 vectors.

use std::ffi::c_int;

use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

/// Bytes of per-blob salt at the front of an envelope.
pub const SALT_LEN: usize = 16;
/// Bytes of AES-GCM nonce after the salt.
pub const NONCE_LEN: usize = 12;
/// Bytes of AES-GCM tag at the end.
pub const TAG_LEN: usize = 16;
/// HKDF info shared with `KeyframeBlobCodec.info`.
pub const INFO: &[u8] = b"mci-blob-v2";

/// Why an envelope could not be sealed or opened. Content-free.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EnvelopeError {
    /// Too short to hold a salt, a nonce and a tag.
    InvalidBlob,
    /// The tag did not verify: a wrong key, or changed bytes.
    AuthenticationFailed,
    /// The blob is larger than one AES-GCM call takes here.
    TooLarge,
    /// OpenSSL refused an operation that cannot fail on valid input.
    Crypto,
}

/// HMAC-SHA256 (RFC 2104).
#[must_use]
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut block_key = Zeroizing::new([0u8; BLOCK]);
    if key.len() > BLOCK {
        block_key[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block_key[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    let mut outer = Sha256::new();
    let mut ipad = Zeroizing::new([0u8; BLOCK]);
    let mut opad = Zeroizing::new([0u8; BLOCK]);
    for index in 0..BLOCK {
        ipad[index] = block_key[index] ^ 0x36;
        opad[index] = block_key[index] ^ 0x5c;
    }
    inner.update(&ipad[..]);
    inner.update(message);
    outer.update(&opad[..]);
    outer.update(inner.finalize());
    outer.finalize().into()
}

/// HKDF-SHA256 (RFC 5869) with a 32-byte output, the length the envelope
/// uses.
#[must_use]
pub fn hkdf_sha256_32(input_key: &[u8], salt: &[u8], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let prk = Zeroizing::new(hmac_sha256(salt, input_key));
    let mut block = Vec::with_capacity(info.len() + 1);
    block.extend_from_slice(info);
    block.push(1);
    Zeroizing::new(hmac_sha256(&prk[..], &block))
}

/// The per-blob AES key: HKDF-SHA256(master, salt, `mci-blob-v2`).
fn blob_key(master_key: &[u8; 32], salt: &[u8]) -> Zeroizing<[u8; 32]> {
    hkdf_sha256_32(master_key, salt, INFO)
}

/// Seal `plaintext` under `master_key` with the given salt and nonce.
///
/// The caller chooses salt and nonce. They must never repeat for different
/// plaintexts under one key: the key change derives both from the old
/// envelope's digest, which names exactly one plaintext.
///
/// # Errors
/// [`EnvelopeError::TooLarge`] or [`EnvelopeError::Crypto`].
pub fn seal(
    plaintext: &[u8],
    master_key: &[u8; 32],
    salt: &[u8; SALT_LEN],
    nonce: &[u8; NONCE_LEN],
) -> Result<Vec<u8>, EnvelopeError> {
    let key = blob_key(master_key, salt);
    let (ciphertext, tag) = ossl::encrypt(&key, nonce, plaintext)?;
    let mut out = Vec::with_capacity(SALT_LEN + NONCE_LEN + ciphertext.len() + TAG_LEN);
    out.extend_from_slice(salt);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ciphertext);
    out.extend_from_slice(&tag);
    Ok(out)
}

/// Open an envelope with `master_key`, returning the plaintext only when the
/// tag verifies.
///
/// # Errors
/// [`EnvelopeError::InvalidBlob`], [`EnvelopeError::AuthenticationFailed`],
/// [`EnvelopeError::TooLarge`] or [`EnvelopeError::Crypto`].
pub fn open(blob: &[u8], master_key: &[u8; 32]) -> Result<Zeroizing<Vec<u8>>, EnvelopeError> {
    // Same bound as the Swift codec: salt, nonce and tag, and at least one byte.
    if blob.len() <= SALT_LEN + NONCE_LEN + TAG_LEN {
        return Err(EnvelopeError::InvalidBlob);
    }
    let (salt, rest) = blob.split_at(SALT_LEN);
    let (nonce, rest) = rest.split_at(NONCE_LEN);
    let (ciphertext, tag) = rest.split_at(rest.len() - TAG_LEN);
    let key = blob_key(master_key, salt);
    let nonce: &[u8; NONCE_LEN] = nonce.try_into().map_err(|_| EnvelopeError::InvalidBlob)?;
    let tag: &[u8; TAG_LEN] = tag.try_into().map_err(|_| EnvelopeError::InvalidBlob)?;
    ossl::decrypt(&key, nonce, ciphertext, tag)
}

/// Lowercase hex SHA-256 of `bytes`: the name a sealed blob is stored under.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(target_os = "macos")]
mod ossl {
    //! The narrow OpenSSL boundary: one AES-256-GCM encrypt and one decrypt.

    use std::ffi::c_void;
    use std::ptr;

    use openssl_sys as ffi;
    use zeroize::Zeroizing;

    use super::{c_int, EnvelopeError, NONCE_LEN, TAG_LEN};

    /// `NONCE_LEN` and `TAG_LEN` as OpenSSL takes them.
    const IV_LEN_C: c_int = 12;
    const TAG_LEN_C: c_int = 16;
    const _: () = assert!(NONCE_LEN == 12 && TAG_LEN == 16);

    /// An `EVP_CIPHER_CTX` freed on every path.
    struct Context(*mut ffi::EVP_CIPHER_CTX);

    impl Context {
        fn new() -> Result<Self, EnvelopeError> {
            // Safety: allocation with no preconditions; null is checked.
            let ctx = unsafe { ffi::EVP_CIPHER_CTX_new() };
            if ctx.is_null() {
                Err(EnvelopeError::Crypto)
            } else {
                Ok(Self(ctx))
            }
        }
    }

    impl Drop for Context {
        fn drop(&mut self) {
            // Safety: `self.0` came from `EVP_CIPHER_CTX_new` and is freed once.
            unsafe { ffi::EVP_CIPHER_CTX_free(self.0) };
        }
    }

    fn length(len: usize) -> Result<c_int, EnvelopeError> {
        c_int::try_from(len).map_err(|_| EnvelopeError::TooLarge)
    }

    pub(super) fn encrypt(
        key: &[u8; 32],
        nonce: &[u8; NONCE_LEN],
        plaintext: &[u8],
    ) -> Result<(Vec<u8>, [u8; TAG_LEN]), EnvelopeError> {
        let input_len = length(plaintext.len())?;
        let ctx = Context::new()?;
        let mut out = vec![0u8; plaintext.len() + 16];
        let mut written: c_int = 0;
        let mut finished: c_int = 0;
        let mut tag = [0u8; TAG_LEN];
        // Safety: every pointer is valid for the lengths given; `out` has a
        // block of room beyond the input, more than GCM (a stream mode) uses.
        let ok = unsafe {
            ffi::EVP_EncryptInit_ex(
                ctx.0,
                ffi::EVP_aes_256_gcm(),
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
            ) == 1
                && ffi::EVP_CIPHER_CTX_ctrl(
                    ctx.0,
                    ffi::EVP_CTRL_GCM_SET_IVLEN,
                    IV_LEN_C,
                    ptr::null_mut(),
                ) == 1
                && ffi::EVP_EncryptInit_ex(
                    ctx.0,
                    ptr::null(),
                    ptr::null_mut(),
                    key.as_ptr(),
                    nonce.as_ptr(),
                ) == 1
                && ffi::EVP_EncryptUpdate(
                    ctx.0,
                    out.as_mut_ptr(),
                    &raw mut written,
                    plaintext.as_ptr(),
                    input_len,
                ) == 1
                && ffi::EVP_EncryptFinal_ex(
                    ctx.0,
                    out.as_mut_ptr().add(usize::try_from(written).unwrap_or(0)),
                    &raw mut finished,
                ) == 1
                && ffi::EVP_CIPHER_CTX_ctrl(
                    ctx.0,
                    ffi::EVP_CTRL_GCM_GET_TAG,
                    TAG_LEN_C,
                    tag.as_mut_ptr().cast::<c_void>(),
                ) == 1
        };
        if !ok {
            return Err(EnvelopeError::Crypto);
        }
        let total = usize::try_from(written + finished).map_err(|_| EnvelopeError::Crypto)?;
        if total != plaintext.len() {
            return Err(EnvelopeError::Crypto);
        }
        out.truncate(total);
        Ok((out, tag))
    }

    pub(super) fn decrypt(
        key: &[u8; 32],
        nonce: &[u8; NONCE_LEN],
        ciphertext: &[u8],
        tag: &[u8; TAG_LEN],
    ) -> Result<Zeroizing<Vec<u8>>, EnvelopeError> {
        let input_len = length(ciphertext.len())?;
        let ctx = Context::new()?;
        let mut out = Zeroizing::new(vec![0u8; ciphertext.len() + 16]);
        let mut written: c_int = 0;
        let mut finished: c_int = 0;
        let mut expected_tag = *tag;
        // Safety: as in `encrypt`; the tag buffer is 16 bytes, as declared.
        let setup = unsafe {
            ffi::EVP_DecryptInit_ex(
                ctx.0,
                ffi::EVP_aes_256_gcm(),
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
            ) == 1
                && ffi::EVP_CIPHER_CTX_ctrl(
                    ctx.0,
                    ffi::EVP_CTRL_GCM_SET_IVLEN,
                    IV_LEN_C,
                    ptr::null_mut(),
                ) == 1
                && ffi::EVP_DecryptInit_ex(
                    ctx.0,
                    ptr::null(),
                    ptr::null_mut(),
                    key.as_ptr(),
                    nonce.as_ptr(),
                ) == 1
                && ffi::EVP_DecryptUpdate(
                    ctx.0,
                    out.as_mut_ptr(),
                    &raw mut written,
                    ciphertext.as_ptr(),
                    input_len,
                ) == 1
                && ffi::EVP_CIPHER_CTX_ctrl(
                    ctx.0,
                    ffi::EVP_CTRL_GCM_SET_TAG,
                    TAG_LEN_C,
                    expected_tag.as_mut_ptr().cast::<c_void>(),
                ) == 1
        };
        if !setup {
            return Err(EnvelopeError::Crypto);
        }
        // Safety: as above. Final returns 1 only when the tag verifies.
        let verified = unsafe {
            ffi::EVP_DecryptFinal_ex(
                ctx.0,
                out.as_mut_ptr().add(usize::try_from(written).unwrap_or(0)),
                &raw mut finished,
            )
        } == 1;
        if !verified {
            return Err(EnvelopeError::AuthenticationFailed);
        }
        let total = usize::try_from(written + finished).map_err(|_| EnvelopeError::Crypto)?;
        if total != ciphertext.len() {
            return Err(EnvelopeError::Crypto);
        }
        out.truncate(total);
        Ok(out)
    }
}

#[cfg(not(target_os = "macos"))]
mod ossl {
    use zeroize::Zeroizing;

    use super::{EnvelopeError, NONCE_LEN, TAG_LEN};

    pub(super) fn encrypt(
        _key: &[u8; 32],
        _nonce: &[u8; NONCE_LEN],
        _plaintext: &[u8],
    ) -> Result<(Vec<u8>, [u8; TAG_LEN]), EnvelopeError> {
        Err(EnvelopeError::Crypto)
    }

    pub(super) fn decrypt(
        _key: &[u8; 32],
        _nonce: &[u8; NONCE_LEN],
        _ciphertext: &[u8],
        _tag: &[u8; TAG_LEN],
    ) -> Result<Zeroizing<Vec<u8>>, EnvelopeError> {
        Err(EnvelopeError::Crypto)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        use std::fmt::Write as _;
        bytes.iter().fold(String::new(), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
    }

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn hmac_matches_rfc_4231_cases_1_and_6() {
        assert_eq!(
            hex(&hmac_sha256(&[0x0b; 20], b"Hi There")),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
        assert_eq!(
            hex(&hmac_sha256(
                &[0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First"
            )),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }

    #[test]
    fn hkdf_matches_rfc_5869_case_1() {
        let okm = hkdf_sha256_32(
            &[0x0b; 22],
            &unhex("000102030405060708090a0b0c"),
            &unhex("f0f1f2f3f4f5f6f7f8f9"),
        );
        // The first 32 bytes of the RFC's 42-byte output.
        assert_eq!(
            hex(&okm[..]),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        );
    }

    /// The Swift codec's own fixed vector
    /// (`KeyframeBlobCodecTests.testDeterministicFixturePreservesExactV2Envelope`):
    /// the same key, plaintext, salt and nonce seal to the same digest, so the
    /// window opens what this module seals.
    #[test]
    fn seals_byte_for_byte_like_the_swift_codec() {
        let key: [u8; 32] = std::array::from_fn(|index| u8::try_from(index).unwrap());
        let salt: [u8; SALT_LEN] = std::array::from_fn(|index| 0xa0 + u8::try_from(index).unwrap());
        let nonce: [u8; NONCE_LEN] =
            std::array::from_fn(|index| 0x10 + u8::try_from(index).unwrap());
        let sealed = seal(b"post-privacy evidence", &key, &salt, &nonce).expect("seal");
        assert_eq!(&sealed[..SALT_LEN], &salt);
        assert_eq!(
            sha256_hex(&sealed),
            "6ed2fbabdff5e83436963171f270d800159a021f215a534f7ff3364e9cd9caaa"
        );
        assert_eq!(
            open(&sealed, &key).expect("open").as_slice(),
            b"post-privacy evidence"
        );
    }

    #[test]
    fn a_wrong_key_or_any_changed_byte_fails_authentication() {
        let key = [7u8; 32];
        let sealed = seal(&[0xff, 0xd8, 0xff, 1, 2, 3], &key, &[1; 16], &[2; 12]).expect("seal");
        assert_eq!(
            open(&sealed, &[8u8; 32]).unwrap_err(),
            EnvelopeError::AuthenticationFailed
        );
        for offset in [0, 16, 28, sealed.len() - 1] {
            let mut bytes = sealed.clone();
            bytes[offset] ^= 0xff;
            assert_eq!(
                open(&bytes, &key).unwrap_err(),
                EnvelopeError::AuthenticationFailed,
                "offset {offset}"
            );
        }
        assert_eq!(
            open(&[0u8; 44], &key).unwrap_err(),
            EnvelopeError::InvalidBlob
        );
    }

    #[test]
    fn large_screenshots_round_trip() {
        let key = [9u8; 32];
        let plaintext: Vec<u8> = (0..3_000_000u32)
            .map(|n| u8::try_from(n % 251).unwrap())
            .collect();
        let sealed = seal(&plaintext, &key, &[3; 16], &[4; 12]).expect("seal");
        assert_eq!(
            sealed.len(),
            plaintext.len() + SALT_LEN + NONCE_LEN + TAG_LEN
        );
        assert_eq!(
            open(&sealed, &key).expect("open").as_slice(),
            &plaintext[..]
        );
    }
}
