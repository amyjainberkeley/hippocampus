//! V2-P10 — Rust-side reader for the user-mutable allowlist layer.
//!
//! Mirrors `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/
//! Suppression/UserAllowlistTOMLLoader.swift` byte-for-byte schema-wise.
//! The Swift helper consumes the same file for the capture-side cascade
//! union; this Rust module consumes it for the agent-side deep-hook
//! plugin master switch (ADR-0017 §3.4.2(d) + ADR-0032 §3(a)).
//!
//! # Trust contract (ADR-0017 §3.4 binding, restated)
//!
//! 1. The user-layer STRICTLY ADDS bundle ids — cannot remove a CSO
//!    baseline entry.
//! 2. Per-entry `deep_hook_enabled` flips the agent-side per-plugin
//!    master switch (`MessagesPluginConfig::plugin_enabled` for
//!    Messages; the analogous start gate for Mail).
//! 3. Per ADR-0017 §3.4.1 / §3.4.2(b) the file MUST be mode 0600
//!    (group + world bits clear) and owned by the current uid. Any
//!    other state is refused — the caller treats the refusal as
//!    `UserAllowlist::empty()` so the agent never refuses to start
//!    because the user-layer is corrupt.
//!
//! # File-permission gate
//!
//! The Swift loader rejects:
//!
//! - `attrs.posixPermissions & 0o077 != 0` → `insecureFilePermissions`
//! - `attrs.ownerAccountID != getuid()` → `notOwnedByCurrentUser`
//!
//! This module mirrors both checks via
//! `std::os::unix::fs::MetadataExt::{mode, uid}` + `libc::getuid()`.
//!
//! # Schema (TOML subset — strictly tighter than the baseline schema)
//!
//! ```toml
//! [[entries]]
//! bundle_id = "com.apple.MobileSMS"
//! capture_enabled = true
//! deep_hook_enabled = true
//! added_at = "2026-05-29"
//! rationale = "I want Messages content in my brain"   # optional
//! ```
//!
//! Required keys: `bundle_id`, `capture_enabled`, `deep_hook_enabled`,
//! `added_at`. Optional key: `rationale`. Each `[[entries]]` table must
//! provide the four required keys exactly once. Quoted strings cannot
//! contain backslashes or embedded quotes (matches the Swift parser's
//! same defensive limit).

#![cfg(unix)]

use std::collections::HashSet;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use thiserror::Error;

/// One row of the user-mutable allowlist.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserAllowlistEntry {
    /// Apple bundle id (`com.apple.MobileSMS`, `com.apple.mail`, …).
    pub bundle_id: String,
    /// User opted in to capture for this bundle. Capture is the
    /// pixel/OCR-path cascade union (helper-side); this bit gates THAT
    /// path on the Swift side. Agent-side wiring uses it as a prereq
    /// for `deep_hook_enabled`.
    pub capture_enabled: bool,
    /// User opted in to deep-hook ingest for this bundle. ADR-0032
    /// §3(a) master switch for Messages; analogous start gate for Mail.
    /// MUST be ignored when `capture_enabled = false` per ADR-0017
    /// §3.4 (a deep-hook with capture-off is contradictory — the
    /// user has implicitly said "I am not opting this app in").
    pub deep_hook_enabled: bool,
    /// ISO-8601-style date (`yyyy-mm-dd`) the user added the entry.
    pub added_at: String,
    /// Optional user-supplied note. Not interpreted.
    pub rationale: Option<String>,
}

/// In-memory snapshot of the user-layer allowlist.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UserAllowlist {
    /// Parsed entries in source order.
    pub entries: Vec<UserAllowlistEntry>,
}

impl UserAllowlist {
    /// Empty snapshot — the graceful default state for a fresh install
    /// (no `user-allowlist.toml` on disk).
    #[must_use]
    pub fn empty() -> Self {
        Self { entries: Vec::new() }
    }

    /// Bundle ids the user has opted IN to capture. Returned as a
    /// `HashSet` to match the union-with-baseline operation the agent
    /// uses to decide deep-hook eligibility. Multiple entries with the
    /// same bundle id collapse to one set member.
    #[must_use]
    pub fn capture_enabled_bundle_ids(&self) -> HashSet<String> {
        self.entries
            .iter()
            .filter(|e| e.capture_enabled)
            .map(|e| e.bundle_id.clone())
            .collect()
    }

    /// Bundle ids the user has opted IN to deep-hook ingest AND to
    /// capture. Per ADR-0017 §3.4 a row with `deep_hook_enabled = true`
    /// but `capture_enabled = false` is a contradiction; this accessor
    /// drops such rows so the supervisor never starts a pump for an
    /// implicitly-not-opted-in bundle. The strictness is binding —
    /// driver-CSO audit row 1.
    #[must_use]
    pub fn deep_hook_enabled_bundle_ids(&self) -> HashSet<String> {
        self.entries
            .iter()
            .filter(|e| e.capture_enabled && e.deep_hook_enabled)
            .map(|e| e.bundle_id.clone())
            .collect()
    }

    /// Stable hash over the deep-hook-enabled set. Used by the
    /// supervisor to detect whether reconcile needs to re-evaluate
    /// FDA probes / pump start-stop. Sorts the bundle ids for
    /// determinism — `HashSet`'s iteration order is not stable.
    #[must_use]
    pub fn deep_hook_state_hash(&self) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut bundles: Vec<String> =
            self.deep_hook_enabled_bundle_ids().into_iter().collect();
        bundles.sort();
        let mut h = DefaultHasher::new();
        bundles.hash(&mut h);
        h.finish()
    }
}

/// Errors the user-layer loader can surface. Variant shapes mirror the
/// Swift `UserAllowlistError` enum so log lines stay parseable across
/// both languages.
#[derive(Debug, Error)]
#[allow(missing_docs)]
pub enum UserAllowlistError {
    /// `[[entries]]` table was opened but `bundle_id = "..."` never appeared.
    #[error("missing bundle_id at line {line}")]
    MissingBundleId { line: usize },
    /// `[[entries]]` table was opened but `capture_enabled = ...` never appeared.
    #[error("missing capture_enabled at line {line}")]
    MissingCaptureEnabled { line: usize },
    /// `[[entries]]` table was opened but `deep_hook_enabled = ...` never appeared.
    #[error("missing deep_hook_enabled at line {line}")]
    MissingDeepHookEnabled { line: usize },
    /// `[[entries]]` table was opened but `added_at = "..."` never appeared.
    #[error("missing added_at at line {line}")]
    MissingAddedAt { line: usize },
    /// Quoted-string value parsed as empty (`bundle_id = ""`) for a
    /// required key.
    #[error("empty value for {key} at line {line}")]
    EmptyValue { line: usize, key: String },
    /// `key = value` could not be tokenized (no `=`, unbalanced
    /// quotes, embedded backslash, …).
    #[error("malformed key/value line at line {line}")]
    MalformedKvLine { line: usize },
    /// A non-blank, non-comment, non-table line appeared before the
    /// first `[[entries]]` marker.
    #[error("unexpected line at line {line}")]
    UnexpectedLine { line: usize },
    /// Required key set twice inside the same table.
    #[error("duplicate {key} at line {line}")]
    DuplicateKey { line: usize, key: String },
    /// Boolean-valued required key tried to parse a non-boolean value.
    #[error("invalid boolean for {key} at line {line}")]
    InvalidBoolean { line: usize, key: String },
    /// File mode has group or world bits set (any of `S_IRWXG | S_IRWXO`).
    #[error("insecure file permissions: mode {mode:#o}")]
    InsecureFilePermissions { mode: u32 },
    /// File is owned by a uid other than the current process's uid.
    #[error("user-allowlist owned by uid {file_uid}, expected {current_uid}")]
    NotOwnedByCurrentUser { file_uid: u32, current_uid: u32 },
    /// I/O error reading the file (other than the missing-file case
    /// which is folded into `UserAllowlist::empty()`).
    #[error("io error: {0}")]
    Io(#[from] io::Error),
}

/// Canonical path for the user-layer allowlist. Matches the Swift
/// helper's `defaultUserAllowlistURL`.
#[must_use]
pub fn default_user_allowlist_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/user-allowlist.toml")
}

/// Load and parse `path` (typically [`default_user_allowlist_path`]).
///
/// - Missing file → [`UserAllowlist::empty`].
/// - Bad perms / foreign owner / parse failure → `Err(...)`. The
///   caller MUST decide whether to fail-stop or fall back to empty;
///   the production supervisor falls back to empty + logs.
pub fn load_from_path(path: &Path) -> Result<UserAllowlist, UserAllowlistError> {
    match fs::metadata(path) {
        Ok(md) => validate_permissions(&md)?,
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            return Ok(UserAllowlist::empty());
        }
        Err(err) => return Err(UserAllowlistError::Io(err)),
    }

    let source = fs::read_to_string(path)?;
    let entries = parse(&source)?;
    Ok(UserAllowlist { entries })
}

/// Permission check matching the Swift loader's `validatePermissions`.
///
/// Group + world bits clear: `mode & 0o077 == 0`. Owner uid must equal
/// the current process's uid (real, not effective — the Swift side uses
/// `getuid()` not `geteuid()`).
fn validate_permissions(md: &fs::Metadata) -> Result<(), UserAllowlistError> {
    let mode = md.mode() & 0o7777;
    if mode & 0o077 != 0 {
        return Err(UserAllowlistError::InsecureFilePermissions { mode });
    }
    let file_uid = md.uid();
    let current_uid = current_real_uid();
    if file_uid != current_uid {
        return Err(UserAllowlistError::NotOwnedByCurrentUser {
            file_uid,
            current_uid,
        });
    }
    Ok(())
}

/// Real-uid of the calling process. `rustix::process::getuid()` is a
/// safe wrapper over the POSIX `getuid(2)` syscall — no `unsafe`
/// needed, which keeps `#![forbid(unsafe_code)]` on `mci-agent`
/// uncompromised. `rustix` is already a `mci-core` dep on the
/// workspace lockfile.
fn current_real_uid() -> u32 {
    rustix::process::getuid().as_raw()
}

/// Parse the TOML subset. Returns the entries in source order.
///
/// Mirrors `UserAllowlistTOMLLoader.parse` in the Swift helper exactly —
/// the same line-by-line state machine, the same key allow-list, the
/// same value shapes (`"quoted-string"` or `true|false`), the same
/// per-table required-key set.
pub fn parse(source: &str) -> Result<Vec<UserAllowlistEntry>, UserAllowlistError> {
    let mut entries: Vec<UserAllowlistEntry> = Vec::new();
    let mut pending_bundle_id: Option<String> = None;
    let mut pending_capture: Option<bool> = None;
    let mut pending_deep_hook: Option<bool> = None;
    let mut pending_added_at: Option<String> = None;
    let mut pending_rationale: Option<String> = None;
    let mut pending_start_line: usize = 0;
    let mut in_table = false;

    for (idx, raw_line) in source.split('\n').enumerate() {
        let line_number = idx + 1;
        let line = raw_line.trim();

        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if line == "[[entries]]" {
            flush_pending(
                &mut entries,
                &mut pending_bundle_id,
                &mut pending_capture,
                &mut pending_deep_hook,
                &mut pending_added_at,
                &mut pending_rationale,
                pending_start_line,
                in_table,
            )?;
            in_table = true;
            pending_start_line = line_number;
            continue;
        }

        if !in_table {
            return Err(UserAllowlistError::UnexpectedLine { line: line_number });
        }

        let (key, value) = parse_kv(line, line_number)?;
        match key.as_str() {
            "bundle_id" => {
                if pending_bundle_id.is_some() {
                    return Err(UserAllowlistError::DuplicateKey {
                        line: line_number,
                        key,
                    });
                }
                let Value::String(s) = value else {
                    return Err(UserAllowlistError::MalformedKvLine { line: line_number });
                };
                if s.is_empty() {
                    return Err(UserAllowlistError::EmptyValue {
                        line: line_number,
                        key,
                    });
                }
                pending_bundle_id = Some(s);
            }
            "capture_enabled" => {
                if pending_capture.is_some() {
                    return Err(UserAllowlistError::DuplicateKey {
                        line: line_number,
                        key,
                    });
                }
                let Value::Bool(b) = value else {
                    return Err(UserAllowlistError::InvalidBoolean {
                        line: line_number,
                        key,
                    });
                };
                pending_capture = Some(b);
            }
            "deep_hook_enabled" => {
                if pending_deep_hook.is_some() {
                    return Err(UserAllowlistError::DuplicateKey {
                        line: line_number,
                        key,
                    });
                }
                let Value::Bool(b) = value else {
                    return Err(UserAllowlistError::InvalidBoolean {
                        line: line_number,
                        key,
                    });
                };
                pending_deep_hook = Some(b);
            }
            "added_at" => {
                if pending_added_at.is_some() {
                    return Err(UserAllowlistError::DuplicateKey {
                        line: line_number,
                        key,
                    });
                }
                let Value::String(s) = value else {
                    return Err(UserAllowlistError::MalformedKvLine { line: line_number });
                };
                if s.is_empty() {
                    return Err(UserAllowlistError::EmptyValue {
                        line: line_number,
                        key,
                    });
                }
                pending_added_at = Some(s);
            }
            "rationale" => {
                if pending_rationale.is_some() {
                    return Err(UserAllowlistError::DuplicateKey {
                        line: line_number,
                        key,
                    });
                }
                let Value::String(s) = value else {
                    return Err(UserAllowlistError::MalformedKvLine { line: line_number });
                };
                pending_rationale = Some(s);
            }
            _ => {
                return Err(UserAllowlistError::MalformedKvLine { line: line_number });
            }
        }
    }

    flush_pending(
        &mut entries,
        &mut pending_bundle_id,
        &mut pending_capture,
        &mut pending_deep_hook,
        &mut pending_added_at,
        &mut pending_rationale,
        pending_start_line,
        in_table,
    )?;

    Ok(entries)
}

#[allow(clippy::too_many_arguments)]
fn flush_pending(
    entries: &mut Vec<UserAllowlistEntry>,
    pending_bundle_id: &mut Option<String>,
    pending_capture: &mut Option<bool>,
    pending_deep_hook: &mut Option<bool>,
    pending_added_at: &mut Option<String>,
    pending_rationale: &mut Option<String>,
    pending_start_line: usize,
    in_table: bool,
) -> Result<(), UserAllowlistError> {
    if !in_table {
        return Ok(());
    }
    let bundle_id = pending_bundle_id
        .take()
        .ok_or(UserAllowlistError::MissingBundleId {
            line: pending_start_line,
        })?;
    let capture_enabled =
        pending_capture
            .take()
            .ok_or(UserAllowlistError::MissingCaptureEnabled {
                line: pending_start_line,
            })?;
    let deep_hook_enabled =
        pending_deep_hook
            .take()
            .ok_or(UserAllowlistError::MissingDeepHookEnabled {
                line: pending_start_line,
            })?;
    let added_at = pending_added_at
        .take()
        .ok_or(UserAllowlistError::MissingAddedAt {
            line: pending_start_line,
        })?;
    let rationale = pending_rationale.take();
    entries.push(UserAllowlistEntry {
        bundle_id,
        capture_enabled,
        deep_hook_enabled,
        added_at,
        rationale,
    });
    Ok(())
}

enum Value {
    String(String),
    Bool(bool),
}

fn parse_kv(line: &str, line_number: usize) -> Result<(String, Value), UserAllowlistError> {
    let eq = line
        .find('=')
        .ok_or(UserAllowlistError::MalformedKvLine { line: line_number })?;
    let key = line[..eq].trim().to_owned();
    let value_part = line[eq + 1..].trim();

    if value_part == "true" {
        return Ok((key, Value::Bool(true)));
    }
    if value_part == "false" {
        return Ok((key, Value::Bool(false)));
    }

    if value_part.len() < 2
        || !value_part.starts_with('"')
        || !value_part.ends_with('"')
    {
        return Err(UserAllowlistError::MalformedKvLine { line: line_number });
    }
    let inner = &value_part[1..value_part.len() - 1];
    if inner.contains('"') || inner.contains('\\') {
        return Err(UserAllowlistError::MalformedKvLine { line: line_number });
    }
    Ok((key, Value::String(inner.to_owned())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(bundle: &str, cap: bool, dh: bool) -> UserAllowlistEntry {
        UserAllowlistEntry {
            bundle_id: bundle.to_owned(),
            capture_enabled: cap,
            deep_hook_enabled: dh,
            added_at: "2026-05-31".to_owned(),
            rationale: None,
        }
    }

    // ----- Schema parsing -----

    #[test]
    fn parses_single_entry_with_all_required_keys() {
        let src = "[[entries]]\n\
                   bundle_id = \"com.apple.MobileSMS\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let entries = parse(src).expect("parse ok");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].bundle_id, "com.apple.MobileSMS");
        assert!(entries[0].capture_enabled);
        assert!(entries[0].deep_hook_enabled);
        assert_eq!(entries[0].added_at, "2026-05-31");
        assert!(entries[0].rationale.is_none());
    }

    #[test]
    fn parses_optional_rationale() {
        let src = "[[entries]]\n\
                   bundle_id = \"com.apple.mail\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n\
                   rationale = \"my reason\"\n";
        let entries = parse(src).expect("parse ok");
        assert_eq!(entries[0].rationale.as_deref(), Some("my reason"));
    }

    #[test]
    fn skips_blank_lines_and_comments() {
        let src = "# header comment\n\
                   \n\
                   [[entries]]\n\
                   # inline comment\n\
                   bundle_id = \"x.y\"\n\
                   capture_enabled = false\n\
                   deep_hook_enabled = false\n\
                   added_at = \"2026-05-31\"\n\
                   \n";
        let entries = parse(src).expect("parse ok");
        assert_eq!(entries.len(), 1);
        assert!(!entries[0].capture_enabled);
    }

    #[test]
    fn parses_multiple_entries_preserving_order() {
        let src = "[[entries]]\n\
                   bundle_id = \"a.b\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = false\n\
                   added_at = \"2026-05-31\"\n\
                   \n\
                   [[entries]]\n\
                   bundle_id = \"c.d\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let entries = parse(src).expect("parse ok");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].bundle_id, "a.b");
        assert_eq!(entries[1].bundle_id, "c.d");
    }

    // ----- Error paths -----

    #[test]
    fn rejects_missing_required_key() {
        let src = "[[entries]]\n\
                   bundle_id = \"x.y\"\n\
                   capture_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let err = parse(src).expect_err("missing deep_hook_enabled");
        assert!(matches!(
            err,
            UserAllowlistError::MissingDeepHookEnabled { .. }
        ));
    }

    #[test]
    fn rejects_empty_bundle_id() {
        let src = "[[entries]]\n\
                   bundle_id = \"\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let err = parse(src).expect_err("empty bundle_id");
        match err {
            UserAllowlistError::EmptyValue { key, .. } => {
                assert_eq!(key, "bundle_id");
            }
            other => panic!("expected EmptyValue; got {other:?}"),
        }
    }

    #[test]
    fn rejects_duplicate_key_in_same_table() {
        let src = "[[entries]]\n\
                   bundle_id = \"x.y\"\n\
                   bundle_id = \"a.b\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let err = parse(src).expect_err("dup");
        assert!(matches!(err, UserAllowlistError::DuplicateKey { .. }));
    }

    #[test]
    fn rejects_kv_before_table() {
        let src = "bundle_id = \"x.y\"\n";
        let err = parse(src).expect_err("kv before table");
        assert!(matches!(err, UserAllowlistError::UnexpectedLine { .. }));
    }

    #[test]
    fn rejects_invalid_boolean() {
        let src = "[[entries]]\n\
                   bundle_id = \"x.y\"\n\
                   capture_enabled = \"true\"\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n";
        let err = parse(src).expect_err("string for bool");
        assert!(matches!(err, UserAllowlistError::InvalidBoolean { .. }));
    }

    #[test]
    fn rejects_quoted_string_with_embedded_quote() {
        let src = "[[entries]]\n\
                   bundle_id = \"\"\"\n";
        let err = parse(src).expect_err("bad string");
        assert!(matches!(err, UserAllowlistError::MalformedKvLine { .. }));
    }

    #[test]
    fn rejects_quoted_string_with_backslash() {
        let src = "[[entries]]\n\
                   bundle_id = \"a\\b\"\n";
        let err = parse(src).expect_err("backslash");
        assert!(matches!(err, UserAllowlistError::MalformedKvLine { .. }));
    }

    #[test]
    fn rejects_unknown_key() {
        let src = "[[entries]]\n\
                   bundle_id = \"x.y\"\n\
                   capture_enabled = true\n\
                   deep_hook_enabled = true\n\
                   added_at = \"2026-05-31\"\n\
                   unknown_key = \"v\"\n";
        let err = parse(src).expect_err("unknown");
        assert!(matches!(err, UserAllowlistError::MalformedKvLine { .. }));
    }

    // ----- Set accessors + audit row 1 binding -----

    #[test]
    fn deep_hook_set_requires_both_bits_per_adr0017_3_4() {
        // Driver-CSO audit row 1: deep_hook_enabled=true AND
        // capture_enabled=true are BOTH required.
        let list = UserAllowlist {
            entries: vec![
                entry("com.apple.MobileSMS", true, true),   // OK — both on
                entry("com.apple.mail", false, true),       // contradiction
                entry("com.spotify.client", true, false),   // capture-only
                entry("com.apple.Notes", false, false),     // not opted in
            ],
        };
        let dh = list.deep_hook_enabled_bundle_ids();
        assert!(dh.contains("com.apple.MobileSMS"));
        assert!(!dh.contains("com.apple.mail"), "deep_hook with capture_off → DROPPED");
        assert!(!dh.contains("com.spotify.client"));
        assert!(!dh.contains("com.apple.Notes"));
        assert_eq!(dh.len(), 1);

        let cap = list.capture_enabled_bundle_ids();
        assert!(cap.contains("com.apple.MobileSMS"));
        assert!(cap.contains("com.spotify.client"));
        assert!(!cap.contains("com.apple.mail"));
        assert!(!cap.contains("com.apple.Notes"));
    }

    #[test]
    fn deep_hook_state_hash_stable_for_same_set_different_order() {
        let a = UserAllowlist {
            entries: vec![
                entry("com.apple.MobileSMS", true, true),
                entry("com.apple.mail", true, true),
            ],
        };
        let b = UserAllowlist {
            entries: vec![
                entry("com.apple.mail", true, true),
                entry("com.apple.MobileSMS", true, true),
            ],
        };
        assert_eq!(a.deep_hook_state_hash(), b.deep_hook_state_hash());
    }

    #[test]
    fn deep_hook_state_hash_changes_when_set_changes() {
        let a = UserAllowlist {
            entries: vec![entry("com.apple.MobileSMS", true, true)],
        };
        let b = UserAllowlist {
            entries: vec![
                entry("com.apple.MobileSMS", true, true),
                entry("com.apple.mail", true, true),
            ],
        };
        assert_ne!(a.deep_hook_state_hash(), b.deep_hook_state_hash());
    }

    #[test]
    fn empty_list_has_empty_sets() {
        assert!(UserAllowlist::empty().capture_enabled_bundle_ids().is_empty());
        assert!(
            UserAllowlist::empty()
                .deep_hook_enabled_bundle_ids()
                .is_empty()
        );
    }

    // ----- File-permission gate (driver-CSO audit row 2) -----

    #[test]
    fn missing_file_returns_empty_not_error() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("user-allowlist.toml");
        // File deliberately not written.
        let list = load_from_path(&path).expect("missing → empty");
        assert!(list.entries.is_empty());
    }

    #[test]
    fn loads_well_formed_file_with_0600() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("user-allowlist.toml");
        let content = "[[entries]]\n\
                       bundle_id = \"com.apple.MobileSMS\"\n\
                       capture_enabled = true\n\
                       deep_hook_enabled = true\n\
                       added_at = \"2026-05-31\"\n";
        fs::write(&path, content).unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o600);
        fs::set_permissions(&path, perms).unwrap();

        let list = load_from_path(&path).expect("load ok");
        assert_eq!(list.entries.len(), 1);
        assert!(list
            .deep_hook_enabled_bundle_ids()
            .contains("com.apple.MobileSMS"));
    }

    #[test]
    fn refuses_world_readable_file() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("user-allowlist.toml");
        fs::write(&path, "[[entries]]\n").unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o644); // world-readable
        fs::set_permissions(&path, perms).unwrap();

        let err = load_from_path(&path).expect_err("must refuse");
        match err {
            UserAllowlistError::InsecureFilePermissions { mode } => {
                assert_eq!(mode & 0o077, 0o044);
            }
            other => panic!("expected InsecureFilePermissions; got {other:?}"),
        }
    }

    #[test]
    fn refuses_group_readable_file() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("user-allowlist.toml");
        fs::write(&path, "[[entries]]\n").unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o640); // group-readable
        fs::set_permissions(&path, perms).unwrap();

        let err = load_from_path(&path).expect_err("must refuse");
        assert!(matches!(
            err,
            UserAllowlistError::InsecureFilePermissions { .. }
        ));
    }

    #[test]
    fn current_real_uid_is_self() {
        // Self-check: the unsafe getuid call should agree with what
        // `id -u` would say; we can't shell out, but we can confirm
        // it's a sensible value (non-max, deterministic across calls).
        let a = current_real_uid();
        let b = current_real_uid();
        assert_eq!(a, b);
        assert!(a < u32::MAX);
    }
}
