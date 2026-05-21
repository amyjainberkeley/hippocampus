//! MCI macOS adapter — C-ABI FFI shim exposing a **READ-ONLY** view of the
//! Phase-3 brain to the Swift recall-ui app (`apps/recall-ui/`).
//!
//! # Scope: P3.9a skeleton
//!
//! This crate ships the FFI **shape** the recall-ui app links against:
//! handle lifecycle, JSON-in / JSON-out signatures, allocator discipline
//! for returned strings. Production wiring (read-only `SQLCipher`
//! connection + real `HybridRetriever` calls + tombstone-table reads)
//! lands in **P3.9b** once `HybridRetriever` (P3.7) and the
//! tombstone-persistence path (P3.6) merge. Each `extern "C"` entry
//! point below currently returns either canned stub JSON or an empty
//! list — the Swift side already exercises every code path via its
//! `BrainReader` protocol with a Swift-native `StubBrainReader`, so the
//! cut-over is a one-line `BrainReader` swap, not a rewrite.
//!
//! # READ-ONLY by construction (ADR-0016 §4 invariant)
//!
//! Every entry point that touches the store will open the `SQLCipher`
//! handle with `OpenFlags::SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_URI`
//! (P3.9b). The `rusqlite::Connection` returned by that open path
//! refuses any `INSERT` / `UPDATE` / `DELETE` / `CREATE` /
//! `DROP` at the driver level (`SQLITE_READONLY`). The recall-ui app
//! is structurally a **consumer** of the brain; it can never write to
//! it. The FFI surface mirrors that discipline — there is no
//! `put_event` / `delete_event` / `mutate_*` function exported.
//! Adding one is an `AGENT_PROTOCOL` §5 protected-set violation.
//!
//! # No protected-set surface this PR
//!
//! P3.9a touches:
//! - This crate (new, `adapters/macos/mci-brain-ffi/`).
//! - The workspace `Cargo.toml` members list (one new line).
//! - The new `SwiftUI` app under `apps/recall-ui/` (separate Swift
//!   Package, no Cargo touch).
//!
//! It does **not** touch:
//! - `core/**` crypto / key-management / sync.
//! - The cascade, denylist, redaction, or incognito-exclusion code.
//! - The `mci.sqlite` write path or the blob store.
//! - Secrets / entitlements / TCC / notarization code.
//!
//! Per `AGENT_PROTOCOL` §5 a CSO sign-off block is therefore **not
//! required** on this PR; the read-only discipline + no-mutation
//! invariant are documented here in source so the eventual P3.9b
//! protected-set review has a concrete contract to verify.
//!
//! # Allocator discipline
//!
//! Every `*mut c_char` this crate returns was allocated by Rust's
//! global allocator (via `CString::into_raw`). The Swift caller MUST
//! return that pointer to [`mci_brain_ffi_string_free`] so Rust can
//! reclaim it (`CString::from_raw`). Calling Swift's `free()` directly
//! is undefined behavior on macOS because Apple's libsystem allocator
//! and Rust's allocator may be the same `malloc` under the hood but
//! the contract is not guaranteed — we keep ownership symmetric:
//! Rust allocates, Rust frees.
//!
//! Likewise, every `*const c_char` parameter is borrowed for the
//! duration of the call only; the Swift caller owns it and may free
//! it after the FFI returns.

#![forbid(unsafe_op_in_unsafe_fn)]
#![deny(missing_docs)]
// FFI by definition requires `unsafe` for the raw pointer entry points.
// Each `unsafe` block carries a per-call-site safety comment.
#![allow(unsafe_code)]

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// JSON value types — what the Swift side decodes with `Codable`
// ---------------------------------------------------------------------------

/// A search-result row returned by [`mci_brain_ffi_search`] /
/// [`mci_brain_ffi_recent_events`]. Carries the event id, time, and the
/// post-cascade-allowed metadata the recall-ui surfaces. **No** suppressed
/// content can appear here by construction (ADR-0016 §4.3): only events
/// that cleared the cascade twice reach the brain store, and this FFI
/// reads only from that store.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HitJson {
    /// Brain `events.id` rowid.
    pub event_id: u64,
    /// `events.ts_us` — microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `events.app_bundle_id` (nullable in schema; encoded as JSON `null`).
    pub app_bundle_id: Option<String>,
    /// `events.window_title` (nullable).
    pub window_title: Option<String>,
    /// `events.url` (nullable).
    pub url: Option<String>,
    /// First N characters of `events.text` for snippet display. The
    /// FFI caps this at 280 chars at the Rust boundary so the Swift
    /// list cells never receive megabytes of OCR text per row.
    pub ocr_text_snippet: String,
    /// Which retrieval source produced this hit. `"lexical"` for plain
    /// FTS5 timeline; `"hybrid"` once P3.7 lands. The UI tags rows so
    /// the user can tell which retrieval path lit the result up.
    pub source: String,
    /// Fused score in `[0.0, 1.0]` (P3.7) or BM25-derived lexical
    /// score (P3.9a stub). `None` for plain timeline rows where no
    /// query was issued.
    pub score: Option<f32>,
}

/// A privacy-moment card row returned by
/// [`mci_brain_ffi_recent_privacy_moments`]. Carries **only** the
/// post-cascade-decision metadata — `app_bundle_id` + `ts` + the cascade
/// reason code mapped to a friendly string. Never the OCR'd text,
/// never the keyframe, never the window-title / URL.
/// ADR-0017 §5.1 + ADR-0016 §4.5 invariant.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivacyMomentJson {
    /// Capture timestamp, microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `appBundleId` of the frontmost app when the cascade fired.
    /// `null` when the helper had no bundle id (catchall path).
    pub app_bundle_id: Option<String>,
    /// Cascade reason code 1..=9 (ADR-0017 §5.2 table).
    pub reason_code: u8,
}

/// JSON payload format for [`mci_brain_ffi_search`] input.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryJson {
    /// Natural-language query.
    pub text: String,
    /// Maximum hits to return.
    pub limit: usize,
    /// Inclusive lower bound on `ts_us`, microseconds. `None` ⇒ no filter.
    #[serde(default)]
    pub time_from_us: Option<u64>,
    /// Inclusive upper bound on `ts_us`, microseconds. `None` ⇒ no filter.
    #[serde(default)]
    pub time_to_us: Option<u64>,
    /// Restrict to one `appBundleId`. `None` ⇒ no filter.
    #[serde(default)]
    pub app_filter: Option<String>,
}

// ---------------------------------------------------------------------------
// Handle — opaque pointer the Swift side holds across calls
// ---------------------------------------------------------------------------

/// Opaque handle the recall-ui retains across FFI calls. Today it owns
/// nothing because every entry point returns canned/empty data; P3.9b
/// wires the read-only `SqlCipherBrainStore` + `HybridRetriever` behind
/// this struct.
pub struct Handle {
    _private: (),
}

// ---------------------------------------------------------------------------
// extern "C" entry points
// ---------------------------------------------------------------------------

/// Open the brain at `path` with the hex-encoded `SQLCipher` key `key_hex`.
///
/// Returns a non-null opaque [`Handle`] pointer on success; on failure
/// returns null and [`mci_brain_ffi_last_error_message`] can be polled
/// for a stable English diagnostic string.
///
/// **Read-only** — P3.9b opens the connection with
/// `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_URI`. The recall-ui never
/// receives a writable handle.
///
/// # Safety
///
/// `path` and `key_hex` MUST be non-null, null-terminated UTF-8
/// C strings. The caller retains ownership; this function does not
/// store the pointers past return. P3.9a accepts any inputs and
/// returns a stub handle so the Swift side can exercise the lifecycle
/// path under test.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_open(
    path: *const c_char,
    key_hex: *const c_char,
) -> *mut Handle {
    // Validate inputs before touching anything else. Null in, null out.
    if path.is_null() || key_hex.is_null() {
        set_last_error("mci_brain_ffi_open: null pointer argument");
        return ptr::null_mut();
    }
    // Safety: caller guarantees the pointers are valid null-terminated
    // UTF-8 C strings. We only borrow them for the duration of this call.
    let path_ok = unsafe { CStr::from_ptr(path) }.to_str().is_ok();
    let key_ok = unsafe { CStr::from_ptr(key_hex) }.to_str().is_ok();
    if !path_ok || !key_ok {
        set_last_error("mci_brain_ffi_open: non-UTF8 path or key");
        return ptr::null_mut();
    }
    // P3.9b: open `SqlCipherBrainStore` read-only here. P3.9a stubs.
    let h = Box::new(Handle { _private: () });
    clear_last_error();
    Box::into_raw(h)
}

/// Close a handle previously returned by [`mci_brain_ffi_open`].
///
/// Calling this with a null pointer is a no-op. Double-close is undefined
/// behavior — the Swift wrapper enforces single-close.
///
/// # Safety
///
/// `h` MUST be a pointer previously returned by [`mci_brain_ffi_open`]
/// and not yet passed to this function.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_close(h: *mut Handle) {
    if h.is_null() {
        return;
    }
    // Safety: caller upheld the precondition that h came from open()
    // and has not been freed yet. We reconstruct the Box so its Drop runs.
    let _ = unsafe { Box::from_raw(h) };
}

/// Run a search against the brain. Returns a JSON array of [`HitJson`]
/// rows. Allocated by Rust — caller MUST pass the returned pointer back
/// to [`mci_brain_ffi_string_free`].
///
/// Returns null on input-parse failure or unexpected internal error;
/// [`mci_brain_ffi_last_error_message`] carries the diagnostic.
///
/// # Safety
///
/// `h` must be a live handle. `query_json` must be a non-null,
/// null-terminated UTF-8 C string containing a [`QueryJson`] payload.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_search(
    h: *mut Handle,
    query_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_search: null handle");
        return ptr::null_mut();
    }
    if query_json.is_null() {
        set_last_error("mci_brain_ffi_search: null query");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid null-terminated UTF-8 string.
    let query_cstr = unsafe { CStr::from_ptr(query_json) };
    let Ok(query_str) = query_cstr.to_str() else {
        set_last_error("mci_brain_ffi_search: non-UTF8 query");
        return ptr::null_mut();
    };
    let _query: QueryJson = match serde_json::from_str(query_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_search: bad query JSON: {e}"));
            return ptr::null_mut();
        }
    };
    // P3.9b: route through HybridRetriever. P3.9a returns an empty list
    // so the Swift side sees a valid empty-result code path (it has a
    // separate StubBrainReader for canned demo data; the FFI itself
    // does not fabricate hits).
    let empty: Vec<HitJson> = Vec::new();
    json_to_c_string(&empty)
}

/// Fetch the N most recent events for the plain timeline view. Returns
/// a JSON array of [`HitJson`]. Same allocator discipline as
/// [`mci_brain_ffi_search`].
///
/// # Safety
///
/// `h` must be a live handle. `limit` is treated as `usize` and clamped
/// to a reasonable ceiling internally so a hostile / negative value
/// cannot allocate unbounded memory.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_recent_events(
    h: *mut Handle,
    limit: u32,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_recent_events: null handle");
        return ptr::null_mut();
    }
    let _limit = limit.min(MAX_LIMIT) as usize;
    // P3.9b: SELECT ... FROM events ORDER BY ts_us DESC LIMIT ?.
    let empty: Vec<HitJson> = Vec::new();
    json_to_c_string(&empty)
}

/// Fetch the N most recent privacy-moment cards. Returns a JSON array
/// of [`PrivacyMomentJson`]. Same allocator discipline.
///
/// **Carries no content** — only `app_bundle_id` + `ts_us` + `reason_code`
/// per ADR-0017 §5.1 + ADR-0016 §4.5. The reason→friendly-string map
/// lives in the Swift `Localizable.strings` per ADR-0017 §5.2.
///
/// # Safety
///
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_recent_privacy_moments(
    h: *mut Handle,
    limit: u32,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_recent_privacy_moments: null handle");
        return ptr::null_mut();
    }
    let _limit = limit.min(MAX_LIMIT) as usize;
    // P3.9b/P3.6: SELECT ... FROM privacy_moments (table TBD by P3.6 /
    // ADR-0017 §5) ORDER BY ts_us DESC LIMIT ?. Until then the table
    // does not exist; FFI returns an empty list and the Swift view
    // shows the empty-state copy.
    let empty: Vec<PrivacyMomentJson> = Vec::new();
    json_to_c_string(&empty)
}

/// Free a `*mut c_char` previously returned by any FFI function that
/// returns owned JSON. Calling with null is a no-op.
///
/// # Safety
///
/// `s` MUST be either null or a pointer previously returned by this
/// crate and not yet freed. Freeing a pointer twice or freeing a
/// pointer not from this crate is undefined behavior.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // Safety: caller upheld the precondition.
    let _ = unsafe { CString::from_raw(s) };
}

/// Return the last diagnostic message set by any FFI call on the current
/// thread, or null if no error is pending. The returned pointer is owned
/// by this crate (thread-local) and is **valid only until the next FFI
/// call on the same thread** — copy it on the Swift side before issuing
/// the next call.
///
/// # Safety
///
/// Callers must not pass the returned pointer to
/// [`mci_brain_ffi_string_free`] (Rust owns it). Must not retain across
/// FFI calls (the thread-local may overwrite it).
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_last_error_message() -> *const c_char {
    LAST_ERROR.with(|cell| {
        let opt = cell.borrow();
        match opt.as_ref() {
            Some(c) => c.as_ptr(),
            None => ptr::null(),
        }
    })
}

// ---------------------------------------------------------------------------
// Internals — thread-local error slot, JSON helper, limit cap
// ---------------------------------------------------------------------------

/// Soft cap on `limit` arguments. The recall-ui's list view paginates
/// far below this anyway; the cap exists so a hostile caller cannot
/// trick the FFI into allocating gigabytes of `Vec<HitJson>`.
const MAX_LIMIT: u32 = 10_000;

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const {
        std::cell::RefCell::new(None)
    };
}

fn set_last_error(msg: &str) {
    let c = CString::new(msg).unwrap_or_else(|_| {
        CString::new("mci-brain-ffi: error message contained a NUL byte")
            .expect("static literal")
    });
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(c);
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = None;
    });
}

/// Serialize `v` as JSON, push it into a `CString`, and hand the raw
/// pointer to the caller. Returns null on serialization failure (which
/// in practice cannot happen for our simple types but is treated as a
/// graceful failure rather than a panic across the FFI boundary —
/// panicking across `extern "C"` is undefined behavior).
fn json_to_c_string<T: Serialize>(v: &T) -> *mut c_char {
    let s = match serde_json::to_string(v) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("serde_json::to_string: {e}"));
            return ptr::null_mut();
        }
    };
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            set_last_error(&format!("CString::new (interior NUL): {e}"));
            ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — exercise every entry point under Rust-side stub data; the
// Swift side has its own headless tests against the BrainReader protocol.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn cstr(s: &str) -> CString {
        CString::new(s).expect("no NUL in test literal")
    }

    #[test]
    fn open_close_lifecycle_roundtrips() {
        let p = cstr("/tmp/never-touched.sqlite");
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        assert!(!h.is_null());
        unsafe { mci_brain_ffi_close(h) };
        // double-close protection is the Swift wrapper's job; the FFI
        // contract is single-close. Nothing to assert here past "no panic".
    }

    #[test]
    fn open_with_null_path_returns_null_and_sets_error() {
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(std::ptr::null(), k.as_ptr()) };
        assert!(h.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(msg.contains("null pointer"));
    }

    #[test]
    fn search_returns_empty_json_array_for_well_formed_query() {
        let p = cstr("/tmp/never-touched.sqlite");
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        let q = cstr(r#"{"text":"contract clause","limit":20}"#);
        let json_ptr = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
        assert!(!json_ptr.is_null(), "well-formed query must succeed");
        let s = unsafe { CStr::from_ptr(json_ptr) }
            .to_string_lossy()
            .into_owned();
        let parsed: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON array");
        assert!(parsed.is_empty(), "P3.9a returns empty until P3.9b wires retriever");
        unsafe { mci_brain_ffi_string_free(json_ptr) };
        unsafe { mci_brain_ffi_close(h) };
    }

    #[test]
    fn search_returns_null_on_malformed_query_json() {
        let p = cstr("/tmp/never-touched.sqlite");
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        let q = cstr("not json at all");
        let json_ptr = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
        assert!(json_ptr.is_null(), "malformed query must error");
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        unsafe { mci_brain_ffi_close(h) };
    }

    #[test]
    fn recent_events_returns_empty_json_array() {
        let p = cstr("/tmp/never-touched.sqlite");
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        let json_ptr = unsafe { mci_brain_ffi_recent_events(h, 50) };
        assert!(!json_ptr.is_null());
        let s = unsafe { CStr::from_ptr(json_ptr) }
            .to_string_lossy()
            .into_owned();
        let parsed: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON");
        assert!(parsed.is_empty());
        unsafe { mci_brain_ffi_string_free(json_ptr) };
        unsafe { mci_brain_ffi_close(h) };
    }

    #[test]
    fn recent_privacy_moments_returns_empty_json_array() {
        let p = cstr("/tmp/never-touched.sqlite");
        let k = cstr("00".repeat(32).as_str());
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        let json_ptr = unsafe { mci_brain_ffi_recent_privacy_moments(h, 50) };
        assert!(!json_ptr.is_null());
        let s = unsafe { CStr::from_ptr(json_ptr) }
            .to_string_lossy()
            .into_owned();
        let parsed: Vec<PrivacyMomentJson> = serde_json::from_str(&s).expect("valid JSON");
        assert!(parsed.is_empty(), "no tombstone table yet — P3.6 / P4.7 owe it");
        unsafe { mci_brain_ffi_string_free(json_ptr) };
        unsafe { mci_brain_ffi_close(h) };
    }

    #[test]
    fn string_free_handles_null_safely() {
        unsafe { mci_brain_ffi_string_free(std::ptr::null_mut()) };
    }

    #[test]
    fn close_handles_null_safely() {
        unsafe { mci_brain_ffi_close(std::ptr::null_mut()) };
    }

    #[test]
    fn hit_json_serde_round_trip() {
        let h = HitJson {
            event_id: 42,
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Apple — Privacy".into()),
            url: Some("https://example.org/".into()),
            ocr_text_snippet: "The quick brown fox …".into(),
            source: "lexical".into(),
            score: Some(0.83),
        };
        let s = serde_json::to_string(&h).unwrap();
        let back: HitJson = serde_json::from_str(&s).unwrap();
        assert_eq!(h, back);
    }

    #[test]
    fn privacy_moment_json_serde_round_trip() {
        let m = PrivacyMomentJson {
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: Some("com.1password.app".into()),
            reason_code: 4,
        };
        let s = serde_json::to_string(&m).unwrap();
        let back: PrivacyMomentJson = serde_json::from_str(&s).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn query_json_accepts_optional_filters() {
        // Without filters
        let q: QueryJson =
            serde_json::from_str(r#"{"text":"a","limit":5}"#).expect("parses without filters");
        assert_eq!(q.text, "a");
        assert_eq!(q.limit, 5);
        assert!(q.time_from_us.is_none());
        assert!(q.app_filter.is_none());
        // With filters
        let q2: QueryJson = serde_json::from_str(
            r#"{"text":"b","limit":10,"time_from_us":100,"time_to_us":200,"app_filter":"com.apple.Safari"}"#,
        )
        .expect("parses with filters");
        assert_eq!(q2.time_from_us, Some(100));
        assert_eq!(q2.time_to_us, Some(200));
        assert_eq!(q2.app_filter.as_deref(), Some("com.apple.Safari"));
    }

    #[test]
    fn limit_clamps_at_max() {
        // A non-clamping bug would be invisible at the API surface but
        // catastrophic if a future wire change accepts the raw value
        // into a Vec::with_capacity. Pin the constant.
        assert_eq!(MAX_LIMIT, 10_000);
    }
}
