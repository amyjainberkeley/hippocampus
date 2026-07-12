//! emlx 3-segment splitter.
//!
//! emlx format (per Mail-spike memo §3):
//!
//! ```text
//! ┌────────────────────────────────────────────────────────┐
//! │ bytes 0..9  : ASCII decimal byte-count, space-padded   │
//! │ byte  10    : 0x0A (LF)                                │
//! │ bytes 11..11+N : RFC 5322 message (N = decoded count)  │
//! │ bytes 11+N..   : XML <plist> trailer                   │
//! └────────────────────────────────────────────────────────┘
//! ```
//!
//! Mail.app has written this shape unchanged since Tiger (2005); the
//! V9 → V10 schema migration left it untouched. The splitter is pure
//! and dependency-free.

use std::path::Path;

use crate::error::MailReaderError;

/// Three-way borrowed view into an emlx file's bytes.
#[derive(Debug, Clone, Copy)]
pub struct EmlxParts<'a> {
    /// The RFC 5322 + MIME message (segment 2). Feed this to `mail-parser`.
    pub rfc5322: &'a [u8],
    /// The XML `<plist>` trailer (segment 3). Decode with the `plist` crate.
    /// May be empty for emlx files Mail.app wrote without trailer keys.
    pub plist_trailer: &'a [u8],
}

/// Length of the fixed prefix: 10 ASCII bytes + 1 LF.
pub const EMLX_PREFIX_LEN: usize = 11;

/// Split an emlx byte buffer into its segments.
///
/// `path` is only used for error attribution.
pub fn split_emlx<'a>(bytes: &'a [u8], path: &Path) -> Result<EmlxParts<'a>, MailReaderError> {
    if bytes.len() < EMLX_PREFIX_LEN {
        return Err(MailReaderError::InvalidEmlx {
            path: path.to_path_buf(),
            reason: format!(
                "file too short for emlx prefix: {} bytes < {}",
                bytes.len(),
                EMLX_PREFIX_LEN
            ),
        });
    }

    // The 10-byte ASCII length field is right-padded with 0x20 (space).
    // It is the byte-count of segment 2 (the RFC 5322 message).
    let length_field = &bytes[..10];
    if !length_field
        .iter()
        .all(|b| b.is_ascii_digit() || *b == b' ')
    {
        return Err(MailReaderError::InvalidEmlx {
            path: path.to_path_buf(),
            reason: "length-prefix bytes are not ASCII digits or spaces".into(),
        });
    }
    if bytes[10] != b'\n' {
        return Err(MailReaderError::InvalidEmlx {
            path: path.to_path_buf(),
            reason: format!("byte 10 is 0x{:02x}, expected LF (0x0a)", bytes[10]),
        });
    }

    // Trim space-padding and decode. `from_utf8` is safe because we already
    // verified ASCII digits + spaces.
    let trimmed = core::str::from_utf8(length_field).expect("ASCII").trim();
    let n: usize = trimmed.parse().map_err(|e| MailReaderError::InvalidEmlx {
        path: path.to_path_buf(),
        reason: format!("length-prefix decode failed ({e}): {trimmed:?}"),
    })?;

    let segment2_end =
        EMLX_PREFIX_LEN
            .checked_add(n)
            .ok_or_else(|| MailReaderError::InvalidEmlx {
                path: path.to_path_buf(),
                reason: "length-prefix arithmetic overflow".into(),
            })?;
    if segment2_end > bytes.len() {
        return Err(MailReaderError::InvalidEmlx {
            path: path.to_path_buf(),
            reason: format!(
                "declared RFC 5322 length {n} overruns file ({} bytes available after prefix)",
                bytes.len().saturating_sub(EMLX_PREFIX_LEN)
            ),
        });
    }

    let rfc5322 = &bytes[EMLX_PREFIX_LEN..segment2_end];
    let plist_trailer = &bytes[segment2_end..];

    Ok(EmlxParts {
        rfc5322,
        plist_trailer,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn synthesize_emlx(body: &[u8], trailer: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(EMLX_PREFIX_LEN + body.len() + trailer.len());
        // 10-byte ASCII length, right-padded with spaces.
        let s = format!("{}", body.len());
        let mut prefix = [b' '; 10];
        prefix[..s.len()].copy_from_slice(s.as_bytes());
        out.extend_from_slice(&prefix);
        out.push(b'\n');
        out.extend_from_slice(body);
        out.extend_from_slice(trailer);
        out
    }

    fn fake_path() -> PathBuf {
        PathBuf::from("/tmp/synthetic-fixture-0.emlx")
    }

    #[test]
    fn split_round_trip_small() {
        // Minimal RFC 5322 message; trailer is a one-key plist.
        let body = b"From: <alice@example.com>\r\nTo: <bob@example.com>\r\n\
                     Subject: synthesized fixture\r\nDate: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <fixture-1@example.invalid>\r\nMime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\r\nhello body.\r\n";
        let trailer = b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                        <plist version=\"1.0\"><dict><key>flags</key><integer>1</integer></dict></plist>\n";
        let buf = synthesize_emlx(body, trailer);
        let parts = split_emlx(&buf, &fake_path()).expect("split ok");
        assert_eq!(
            parts.rfc5322, body,
            "RFC 5322 segment must round-trip exact bytes"
        );
        assert_eq!(
            parts.plist_trailer, trailer,
            "plist trailer must round-trip exact bytes"
        );
    }

    #[test]
    fn split_zero_trailer_ok() {
        let body = b"From: <a@b.c>\r\n\r\nx";
        let buf = synthesize_emlx(body, b"");
        let parts = split_emlx(&buf, &fake_path()).expect("split ok");
        assert_eq!(parts.rfc5322, body);
        assert!(parts.plist_trailer.is_empty());
    }

    #[test]
    fn split_short_file_errors() {
        let err = split_emlx(b"123", &fake_path()).unwrap_err();
        assert!(matches!(err, MailReaderError::InvalidEmlx { .. }));
    }

    #[test]
    fn split_bad_prefix_errors() {
        // Non-numeric prefix.
        let buf = b"abcdefghij\nFrom:\r\n\r\nx";
        let err = split_emlx(buf, &fake_path()).unwrap_err();
        assert!(matches!(err, MailReaderError::InvalidEmlx { .. }));
    }

    #[test]
    fn split_missing_lf_errors() {
        let buf = b"5         From:";
        let err = split_emlx(buf, &fake_path()).unwrap_err();
        assert!(matches!(err, MailReaderError::InvalidEmlx { .. }));
    }

    #[test]
    fn split_length_overrun_errors() {
        // Declares 9999 bytes of body but only has 3.
        let buf = b"9999      \nbody";
        let err = split_emlx(buf, &fake_path()).unwrap_err();
        assert!(matches!(err, MailReaderError::InvalidEmlx { .. }));
    }

    #[test]
    fn split_prefix_exact_shape_matches_spike() {
        // Spike memo §3 documents prefix bytes for length 6085 as
        // "6085      \n" (4 digits + 6 spaces + LF).
        let body = vec![b'x'; 6085];
        let buf = synthesize_emlx(&body, b"");
        assert_eq!(&buf[..10], b"6085      ", "right-padded with 6 spaces");
        assert_eq!(buf[10], b'\n');
    }
}
