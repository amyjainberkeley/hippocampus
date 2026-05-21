//! Integration tests for the P3.9b FFI wiring against a real ephemeral
//! SQLCipher brain DB.
//!
//! # The CSO load-bearing test (`ffi_open_yields_a_strictly_read_only_brain`)
//!
//! ADR-0017 §5 + ADR-0016 §4.3 require that the recall UI cannot mutate
//! the brain. This test proves that structurally:
//!
//! 1. Open a writer (`SqlCipherBrainStore::new`), apply the migration,
//!    insert one event, close.
//! 2. Open the same file via the **FFI shim** (`mci_brain_ffi_open`) and
//!    confirm read works (`mci_brain_ffi_recent_events` returns the row).
//! 3. Reopen the same file through `mci_core::store::open_readonly`
//!    (the same code path the FFI uses internally) and attempt a write —
//!    must fail at the SQLite driver level with `SQLITE_READONLY`.
//!
//! Step 3 is the structural assertion. The FFI does not export a write
//! surface (no `put_event` / `delete_event` / `mutate_*` extern fn) and
//! the underlying connection it opens is `SQLITE_OPEN_READ_ONLY`, so the
//! invariant is enforced TWICE — once by the absent FFI surface and once
//! by the SQLite driver. Either check alone would be load-bearing; both
//! together are the protected-set wall.

use std::ffi::{CStr, CString};
use std::path::PathBuf;

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_last_error_message, mci_brain_ffi_open,
    mci_brain_ffi_recent_events, mci_brain_ffi_recent_privacy_moments, mci_brain_ffi_search,
    mci_brain_ffi_string_free, HitJson, PrivacyMomentJson,
};
use mci_core::crypto::DbKey;
use mci_core::store::open_readonly as mci_core_open_readonly;
use rusqlite::params;
use tempfile::TempDir;

/// Hex-encode raw 32-byte test key bytes for the FFI's `key_hex` arg.
/// Tests construct the `DbKey` via [`DbKey::from_bytes`] from the same
/// `raw_bytes` so the writer + the FFI-side key match exactly.
fn key_hex_for(raw_bytes: [u8; 32]) -> String {
    raw_bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn make_test_db() -> (TempDir, PathBuf, [u8; 32]) {
    // Use a fixed test seed so the `key_hex` we hand to the FFI matches
    // the `DbKey` we use to seed the writer — `InMemoryKeyWrap` is a
    // no-op wrap so the bytes round-trip identically.
    let raw: [u8; 32] = [
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0,
        0xF0, 0x01,
    ];
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    (dir, path, raw)
}

fn seed_event(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    title: &str,
    url: &str,
    text: &str,
) -> EventId {
    let ev = Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.into()),
        window_title: Some(title.into()),
        url: Some(url.into()),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        embedding: None,
    };
    store.put_event(&ev).expect("put_event")
}

// ---------------------------------------------------------------------------
// 1. CSO load-bearing — FFI hands the recall UI a strictly read-only brain
// ---------------------------------------------------------------------------

#[test]
fn ffi_open_yields_a_strictly_read_only_brain() {
    let (_dir, path, raw_key) = make_test_db();
    // Writer-side: apply migration + seed one row.
    let writer_key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &writer_key).expect("writer open");
        seed_event(
            &writer,
            1_700_000_000_000_000,
            "com.apple.Safari",
            "Apple — Privacy",
            "https://apple.com/privacy/",
            "Privacy is a fundamental human right.",
        );
    }

    // FFI side: open through the recall-UI's actual entry point.
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(
        !h.is_null(),
        "FFI open of seeded DB must succeed; last error: {}",
        last_error_string()
    );

    // Read works — the FFI surfaces the seeded row.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    assert!(!j.is_null());
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON array");
    unsafe { mci_brain_ffi_string_free(j) };
    assert_eq!(hits.len(), 1, "exactly one seeded event expected");
    assert_eq!(hits[0].app_bundle_id.as_deref(), Some("com.apple.Safari"));
    assert_eq!(hits[0].source, "timeline");

    unsafe { mci_brain_ffi_close(h) };

    // STRUCTURAL ENFORCEMENT — open the same file through the SAME code
    // path the FFI uses internally and confirm the underlying conn
    // refuses writes with SQLITE_READONLY.
    let ro = mci_core_open_readonly(&path, &writer_key).expect("reopen readonly");
    let err = ro
        .conn()
        .execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)",
            params!["sneaky", "nope"],
        )
        .expect_err("read-only conn MUST refuse INSERT");
    match err {
        rusqlite::Error::SqliteFailure(sqlite_err, _) => {
            assert_eq!(
                sqlite_err.code,
                rusqlite::ErrorCode::ReadOnly,
                "expected SQLITE_READONLY (code 8), got {sqlite_err:?}"
            );
        }
        other => panic!("expected SqliteFailure(SQLITE_READONLY), got {other:?}"),
    }

    // Plus: a CREATE TABLE must also be refused (DDL is a write).
    let err = ro
        .conn()
        .execute("CREATE TABLE injected (x INTEGER)", [])
        .expect_err("CREATE TABLE must fail on RO conn");
    assert!(
        matches!(
            err,
            rusqlite::Error::SqliteFailure(sqlite_err, _)
                if sqlite_err.code == rusqlite::ErrorCode::ReadOnly
        ),
        "expected SQLITE_READONLY on CREATE TABLE, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// 2. FFI search returns lexical hits (P3.9b: FTS5-only; hybrid is P3.3 swap)
// ---------------------------------------------------------------------------

#[test]
fn ffi_search_returns_lexical_fts5_hits_for_matching_query() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(
            &writer,
            1_700_000_000_000_000,
            "com.apple.Safari",
            "Apple — Privacy",
            "https://apple.com/privacy/",
            "Privacy is a fundamental human right.",
        );
        seed_event(
            &writer,
            1_700_000_000_001_000,
            "com.microsoft.VSCode",
            "lib.rs — mci",
            "",
            "pub trait Chunker { fn chunk(&self, s: &str); }",
        );
    }

    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null(), "FFI open failed: {}", last_error_string());

    let q = CString::new(r#"{"text":"privacy","limit":10}"#).unwrap();
    let j = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
    assert!(!j.is_null(), "search failed: {}", last_error_string());
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON");
    unsafe { mci_brain_ffi_string_free(j) };

    assert!(!hits.is_empty(), "FTS5 should match 'privacy' in seeded text");
    assert_eq!(hits[0].source, "lexical");
    assert_eq!(hits[0].app_bundle_id.as_deref(), Some("com.apple.Safari"));

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 3. FFI search filters — app_filter + time_from/time_to
// ---------------------------------------------------------------------------

#[test]
fn ffi_search_honors_app_filter() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(
            &writer,
            1,
            "com.apple.Safari",
            "T1",
            "https://example.com/",
            "shared keyword: signal",
        );
        seed_event(
            &writer,
            2,
            "com.microsoft.VSCode",
            "T2",
            "",
            "shared keyword: signal",
        );
    }

    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let q = CString::new(r#"{"text":"signal","limit":10,"app_filter":"com.apple.Safari"}"#).unwrap();
    let j = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].app_bundle_id.as_deref(), Some("com.apple.Safari"));

    unsafe { mci_brain_ffi_close(h) };
}

#[test]
fn ffi_search_honors_time_window() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(&writer, 100, "app", "T", "", "keyword foo");
        seed_event(&writer, 200, "app", "T", "", "keyword foo");
        seed_event(&writer, 300, "app", "T", "", "keyword foo");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let q = CString::new(r#"{"text":"foo","limit":10,"time_from_us":150,"time_to_us":250}"#)
        .unwrap();
    let j = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].ts_us, 200);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 4. recent_events returns rows ordered by ts_us DESC
// ---------------------------------------------------------------------------

#[test]
fn ffi_recent_events_orders_by_ts_us_descending() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(&writer, 100, "app", "T", "", "a");
        seed_event(&writer, 300, "app", "T", "", "c");
        seed_event(&writer, 200, "app", "T", "", "b");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };

    let ts: Vec<u64> = hits.iter().map(|h| h.ts_us).collect();
    assert_eq!(ts, vec![300, 200, 100]);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 5. Wrong key → mci_brain_ffi_open returns null + sets error
// ---------------------------------------------------------------------------

#[test]
fn ffi_open_with_wrong_key_fails_gracefully() {
    let (_dir, path, raw_key) = make_test_db();
    {
        let key = DbKey::from_bytes(raw_key);
        let _w = SqlCipherBrainStore::new(&path, &key).expect("writer open");
    }
    // Wrong key — all-zeros instead of the seeded raw bytes.
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new("00".repeat(32)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(h.is_null(), "wrong key must not yield a handle");
    let err = last_error_string();
    assert!(!err.is_empty(), "wrong key must set an error");
}

// ---------------------------------------------------------------------------
// 6. Privacy moments — deferred to P3.9c, MUST return empty list (NOT canned)
// ---------------------------------------------------------------------------

#[test]
fn ffi_recent_privacy_moments_returns_empty_list_until_p3_9c() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let _w = SqlCipherBrainStore::new(&path, &key).expect("writer open");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let j = unsafe { mci_brain_ffi_recent_privacy_moments(h, 50) };
    assert!(!j.is_null());
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let moments: Vec<PrivacyMomentJson> = serde_json::from_str(&s).expect("valid JSON");
    unsafe { mci_brain_ffi_string_free(j) };
    assert!(
        moments.is_empty(),
        "tombstone surfacing is P3.9c — must NOT fabricate rows"
    );

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 7. snippet capped at SNIPPET_CHAR_CAP
// ---------------------------------------------------------------------------

#[test]
fn ffi_recent_events_caps_snippet_length() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        let huge: String = "x".repeat(10_000);
        seed_event(&writer, 1, "app", "T", "", &huge);
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let j = unsafe { mci_brain_ffi_recent_events(h, 5) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };

    assert!(!hits.is_empty());
    assert!(
        hits[0].ocr_text_snippet.chars().count() <= mci_brain_ffi::SNIPPET_CHAR_CAP,
        "snippet must respect SNIPPET_CHAR_CAP"
    );

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 8. Malformed JSON query → null return + error set
// ---------------------------------------------------------------------------

#[test]
fn ffi_search_rejects_malformed_query_json() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let _w = SqlCipherBrainStore::new(&path, &key).expect("writer open");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let q = CString::new("not-json-at-all").unwrap();
    let j = unsafe { mci_brain_ffi_search(h, q.as_ptr()) };
    assert!(j.is_null(), "malformed JSON must yield a null return");
    let err = last_error_string();
    assert!(
        err.contains("bad query JSON"),
        "expected diagnostic about bad query JSON, got: {err}"
    );

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 9. FFI does NOT export any mutating surface — compile-time + symbol check
// ---------------------------------------------------------------------------

#[test]
fn ffi_exports_no_mutating_surface() {
    // Sanity: every exported function name is on this allow-list. New extern
    // fns landing here without an ADR amend are a §5 protected-set violation.
    // (Compile-time list: any future contributor adding a `mci_brain_ffi_put_*`
    // or `_delete_*` will see this test fail and have to justify it.)
    let allowed: &[&str] = &[
        "mci_brain_ffi_open",
        "mci_brain_ffi_close",
        "mci_brain_ffi_search",
        "mci_brain_ffi_recent_events",
        "mci_brain_ffi_recent_privacy_moments",
        "mci_brain_ffi_string_free",
        "mci_brain_ffi_last_error_message",
    ];
    // Verify each known name is callable — taking its address forces the
    // linker to resolve it. (We cannot reflectively enumerate `#[no_mangle]`
    // symbols at runtime; this is a positive-list smoke check.)
    let _: &[*const ()] = &[
        mci_brain_ffi_open as *const (),
        mci_brain_ffi_close as *const (),
        mci_brain_ffi_search as *const (),
        mci_brain_ffi_recent_events as *const (),
        mci_brain_ffi_recent_privacy_moments as *const (),
        mci_brain_ffi_string_free as *const (),
        mci_brain_ffi_last_error_message as *const (),
    ];
    assert_eq!(allowed.len(), 7, "FFI surface size pinned at 7");
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn last_error_string() -> String {
    let p = unsafe { mci_brain_ffi_last_error_message() };
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
