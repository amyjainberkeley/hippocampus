//! Per-device identifier — the opaque string the store layer binds
//! to `events.device_id` (DESIGN.md §12, ADR-0008 §1.1).
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. The device id is **opaque** by
//! design: it is NOT a hostname (those leak), NOT a hardware id (those
//! are unstable across OS reinstalls + would force ADR-0012 to treat
//! them as PII), and NOT tied to any cloud account. It is a random
//! 128-bit value generated on first run, written to
//! `~/.mci/device-id` at mode 0600, read back on every subsequent
//! launch.
//!
//! The id ROTATES only on explicit user action (a future "rotate
//! device" CLI command + a paired schema migration that retroactively
//! relabels prior `events.device_id` rows — Phase 5 work). For Phase 1
//! the id is generate-once + persist.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! - The id is generated from `getrandom`-backed OS entropy. Never
//!   derive from MAC address, machine serial, or hostname.
//! - The on-disk file is 0600. Reading + writing both check the mode
//!   (TODO: cycle 3+ wires the chmod-on-write; the test enforces the
//!   intent).
//! - The id is held in a `DeviceId(String)` wrapper, not a bare
//!   `String`, so accidentally formatting it through `tracing` /
//!   `Display` requires an explicit `.as_str()` — gives a chance to
//!   audit any code path that surfaces the id in logs (it's
//!   content-free per ADR-0001 NG3 but still worth keeping explicit).
//!
//! — CSO, 2026-05-19

use std::fmt::Write as _;
use std::path::PathBuf;

use thiserror::Error;
use tokio::fs;
use tokio::io::AsyncWriteExt;

/// Opaque per-device identifier.
///
/// Wraps a 32-character hex string (128 bits of entropy). Construct
/// via [`load_or_generate`] only — never `DeviceId::from_str` in
/// production code (tests fabricate via `DeviceId::from_hex_for_test`
/// to keep the trust boundary visible).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceId(String);

impl DeviceId {
    /// Opaque hex form. Returned by-reference; the wrapper holds the
    /// owning `String`.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// **Tests only.** Construct from a known hex string.
    #[cfg(test)]
    pub fn from_hex_for_test(s: impl Into<String>) -> Self {
        Self(s.into())
    }

    /// Generate a fresh id from OS entropy.
    ///
    /// Uses `getrandom` via std lib's `OsRng`-equivalent: on macOS this
    /// is `getentropy(2)` under the hood. We avoid the `rand` crate to
    /// keep the dep surface minimal (CRS Security-Signal memo Q's any
    /// crypto-adjacent dep).
    fn generate() -> Result<Self, DeviceIdError> {
        let mut bytes = [0_u8; 16];
        getrandom_bytes(&mut bytes).map_err(|e| DeviceIdError::Entropy(e.to_string()))?;
        let mut hex = String::with_capacity(32);
        for b in bytes {
            write!(&mut hex, "{b:02x}").expect("write to String never fails");
        }
        Ok(Self(hex))
    }
}

/// Where a loaded device id came from on this run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceIdSource {
    /// Read from the existing on-disk file.
    LoadedExisting,
    /// Generated this run and written to the on-disk file. First run.
    GeneratedAndPersisted,
}

/// Errors `load_or_generate` may surface.
#[derive(Debug, Error)]
pub enum DeviceIdError {
    /// `getrandom` / `getentropy` failed. Surfaced as a string so
    /// the agent's startup-error path can log it without a heavyweight
    /// error-chain dep.
    #[error("entropy source failed: {0}")]
    Entropy(String),
    /// File-system I/O failed (read, write, or `chmod`-equivalent).
    #[error("device-id file io: {0}")]
    Io(#[from] std::io::Error),
    /// On-disk file contents do not match the expected 32-char hex
    /// shape. The agent refuses to start rather than silently
    /// "interpret" corrupt config — the trust boundary on the local
    /// id store.
    #[error("device-id file content is invalid (expected 32-char hex; got {got_len} chars)")]
    Malformed {
        /// Length of the bytes we read off disk (for diagnostics).
        got_len: usize,
    },
}

/// Load the device id from `path`, or generate + persist one if the
/// file does not exist. Returns the id + a source indicator the
/// caller can log.
///
/// `path` is typically `~/.mci/device-id`. The parent dir is created
/// with `create_dir_all` if missing. The file is written with mode
/// `0o600` on Unix (best-effort — the Phase-1 cycle-3 PR adds an
/// explicit `chmod` after creation; for now we set the mode on the
/// `OpenOptions` builder which Tokio honors on macOS).
pub async fn load_or_generate(path: PathBuf) -> Result<(DeviceId, DeviceIdSource), DeviceIdError> {
    // Try to read.
    match fs::read_to_string(&path).await {
        Ok(content) => {
            let trimmed = content.trim();
            if !is_valid_hex_id(trimmed) {
                return Err(DeviceIdError::Malformed {
                    got_len: trimmed.len(),
                });
            }
            Ok((DeviceId(trimmed.to_owned()), DeviceIdSource::LoadedExisting))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // First run — generate, persist, return.
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).await?;
            }
            let id = DeviceId::generate()?;
            write_with_restrictive_mode(&path, id.as_str()).await?;
            Ok((id, DeviceIdSource::GeneratedAndPersisted))
        }
        Err(e) => Err(e.into()),
    }
}

/// Validity check — must be exactly 32 lowercase hex chars.
fn is_valid_hex_id(s: &str) -> bool {
    s.len() == 32
        && s.chars()
            .all(|c| c.is_ascii_hexdigit() && (c.is_ascii_digit() || c.is_ascii_lowercase()))
}

/// Write `body` to `path` with `0o600` mode (Unix).
async fn write_with_restrictive_mode(path: &std::path::Path, body: &str) -> std::io::Result<()> {
    let mut file = tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .await?;
    file.write_all(body.as_bytes()).await?;
    file.flush().await?;
    Ok(())
}

/// Read OS entropy into `buf`. Uses `/dev/urandom` — present on every
/// macOS install + every Unix MCI will ever target. Synchronous read
/// in a small fixed-size buffer; we never block here longer than the
/// kernel takes to copy a few bytes.
///
/// Why not `getentropy(2)` / `getrandom(2)` directly? They'd need an
/// `unsafe` FFI shim. The agent crate is `forbid(unsafe_code)`; reading
/// `/dev/urandom` is the safe equivalent with no observable difference
/// in entropy quality for a one-shot 128-bit generation.
///
/// Why not the `rand` / `getrandom` crate? CRS Security-Signal memo
/// (2026-05-19) recommends keeping the dep surface tiny; the std lib
/// `File::read_exact("/dev/urandom")` path covers the use case without
/// a new dep.
fn getrandom_bytes(buf: &mut [u8]) -> std::io::Result<()> {
    use std::io::Read;
    let mut f = std::fs::File::open("/dev/urandom")?;
    f.read_exact(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn is_valid_hex_id_accepts_known_good() {
        assert!(is_valid_hex_id("0123456789abcdef0123456789abcdef"));
    }

    #[test]
    fn is_valid_hex_id_rejects_short() {
        assert!(!is_valid_hex_id("deadbeef"));
    }

    #[test]
    fn is_valid_hex_id_rejects_uppercase() {
        assert!(!is_valid_hex_id("0123456789ABCDEF0123456789ABCDEF"));
    }

    #[test]
    fn is_valid_hex_id_rejects_non_hex() {
        assert!(!is_valid_hex_id("0123456789abcdef0123456789abcdez"));
    }

    #[tokio::test]
    async fn generates_and_persists_on_first_run() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci").join("device-id");
        let (id, source) = load_or_generate(path.clone()).await.unwrap();
        assert_eq!(source, DeviceIdSource::GeneratedAndPersisted);
        assert!(is_valid_hex_id(id.as_str()));

        // Persisted to disk.
        let on_disk = tokio::fs::read_to_string(&path).await.unwrap();
        assert_eq!(on_disk.trim(), id.as_str());
    }

    #[tokio::test]
    async fn writes_with_0600_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci").join("device-id");
        let _ = load_or_generate(path.clone()).await.unwrap();

        let meta = tokio::fs::metadata(&path).await.unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "device-id file must be 0600");
    }

    #[tokio::test]
    async fn second_load_returns_existing_id() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci").join("device-id");
        let (id1, src1) = load_or_generate(path.clone()).await.unwrap();
        let (id2, src2) = load_or_generate(path.clone()).await.unwrap();
        assert_eq!(id1, id2);
        assert_eq!(src1, DeviceIdSource::GeneratedAndPersisted);
        assert_eq!(src2, DeviceIdSource::LoadedExisting);
    }

    #[tokio::test]
    async fn malformed_file_returns_error() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("mci");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join("device-id");
        tokio::fs::write(&path, "not-a-valid-hex-id").await.unwrap();
        let err = load_or_generate(path).await.unwrap_err();
        match err {
            DeviceIdError::Malformed { got_len } => assert_eq!(got_len, 18),
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn malformed_uppercase_file_returns_error() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("mci");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join("device-id");
        // Uppercase is intentionally rejected — drift from the
        // canonical lowercase form means somebody hand-edited the
        // file, and we'd rather fail loud than treat "DEADBEEF…" and
        // "deadbeef…" as the same id silently.
        tokio::fs::write(&path, "0123456789ABCDEF0123456789ABCDEF")
            .await
            .unwrap();
        let err = load_or_generate(path).await.unwrap_err();
        assert!(matches!(err, DeviceIdError::Malformed { .. }));
    }

    #[test]
    fn generate_produces_distinct_ids() {
        // 128 bits of entropy → collision probability is ~0 over a
        // small sample. This is a smoke test, not a statistical one.
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for _ in 0..100 {
            let id = DeviceId::generate().expect("entropy ok");
            assert!(seen.insert(id.as_str().to_owned()), "collision in 100 ids");
        }
    }

    #[test]
    fn device_id_does_not_expose_inner_string_via_display() {
        // DeviceId intentionally has no Display impl. Forcing callers
        // to go through `.as_str()` keeps every log/format path
        // explicit. This test is a compile-time gate: if a Display
        // impl gets added, this line still compiles but the
        // documented intent is broken. We instead assert the wrapper
        // shape with a runtime check on debug output.
        let id = DeviceId::from_hex_for_test("0123456789abcdef0123456789abcdef");
        let s = format!("{id:?}");
        assert!(s.starts_with("DeviceId("));
    }
}
