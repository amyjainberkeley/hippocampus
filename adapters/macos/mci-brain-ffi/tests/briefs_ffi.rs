//! Integration tests for the daily-brief FFI surface
//! (`docs/design/brief-viewer-spec.md`).
//!
//! Each test stands up an ephemeral SQLCipher brain, seeds briefs via the
//! Rust writer, then re-opens through the FFI and exercises the three new
//! READ-ONLY entry points + JSON-`null` semantics for "no brief on this
//! date".

use std::ffi::{CStr, CString};
use std::path::PathBuf;

use mci_brain::{BriefRow, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_brief_dates, mci_brain_ffi_brief_for_date, mci_brain_ffi_close,
    mci_brain_ffi_latest_brief, mci_brain_ffi_open, mci_brain_ffi_string_free, BriefJson,
};
use mci_core::crypto::DbKey;
use tempfile::TempDir;

fn key_hex_for(raw_bytes: [u8; 32]) -> String {
    raw_bytes.iter().fold(String::new(), |mut s, b| {
        use std::fmt::Write;
        write!(s, "{b:02x}").unwrap();
        s
    })
}

fn fresh_db() -> (TempDir, PathBuf, [u8; 32]) {
    let raw: [u8; 32] = [
        0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x11,
    ];
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    (dir, path, raw)
}

fn seed_brief(store: &SqlCipherBrainStore, date_local: &str, generated_ts_us: u64, body: &str) {
    let row = BriefRow {
        id: 0,
        date_local: date_local.into(),
        generated_ts_us,
        model_id: "qwen3-1.7b-int4".into(),
        model_version: "1.0".into(),
        title: format!("Brief for {date_local}"),
        body: body.into(),
        word_count: body.split_whitespace().count() as u32,
        source_event_count: 42,
    };
    store.put_brief(&row).expect("put_brief");
}

fn read_owned(c: *mut std::ffi::c_char) -> String {
    let s = unsafe { CStr::from_ptr(c) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(c) };
    s
}

// ---------------------------------------------------------------------------
// 1. brief_for_date returns the brief as a JSON object
// ---------------------------------------------------------------------------

#[test]
fn ffi_brief_for_date_returns_json_object() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
        seed_brief(
            &writer,
            "2026-05-22",
            1_716_429_780_000_000,
            "## Highlights\n\nA productive day.\n",
        );
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null(), "FFI open succeeds");

    let date_c = CString::new("2026-05-22").unwrap();
    let raw = unsafe { mci_brain_ffi_brief_for_date(h, date_c.as_ptr()) };
    assert!(!raw.is_null());
    let s = read_owned(raw);

    let brief: BriefJson = serde_json::from_str(&s).expect("JSON object");
    assert_eq!(brief.date_local, "2026-05-22");
    assert_eq!(brief.generated_ts_us, 1_716_429_780_000_000);
    assert_eq!(brief.model_id, "qwen3-1.7b-int4");
    assert_eq!(brief.body, "## Highlights\n\nA productive day.\n");
    assert_eq!(brief.source_event_count, 42);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 2. brief_for_date on a missing date returns JSON `null`
// ---------------------------------------------------------------------------

#[test]
fn ffi_brief_for_date_returns_null_for_missing_date() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let _writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    let date_c = CString::new("1999-01-01").unwrap();
    let raw = unsafe { mci_brain_ffi_brief_for_date(h, date_c.as_ptr()) };
    assert!(!raw.is_null());
    let s = read_owned(raw);
    assert_eq!(s, "null", "missing date must serialize to JSON `null`");

    let parsed: Option<BriefJson> = serde_json::from_str(&s).expect("Optional decodes null");
    assert!(parsed.is_none());

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 3. latest_brief returns the most-recently-generated brief
// ---------------------------------------------------------------------------

#[test]
fn ffi_latest_brief_returns_most_recent_by_generated_ts() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
        seed_brief(&writer, "2026-05-20", 1_000_000, "older");
        seed_brief(&writer, "2026-05-22", 3_000_000, "newest");
        seed_brief(&writer, "2026-05-21", 2_000_000, "middle");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let raw = unsafe { mci_brain_ffi_latest_brief(h) };
    assert!(!raw.is_null());
    let s = read_owned(raw);
    let brief: BriefJson = serde_json::from_str(&s).expect("JSON");
    assert_eq!(brief.date_local, "2026-05-22");
    assert_eq!(brief.generated_ts_us, 3_000_000);

    unsafe { mci_brain_ffi_close(h) };
}

#[test]
fn ffi_latest_brief_on_empty_store_returns_null() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let _writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let raw = unsafe { mci_brain_ffi_latest_brief(h) };
    let s = read_owned(raw);
    assert_eq!(s, "null");

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 4. brief_dates returns dates ordered most-recent first, capped by limit
// ---------------------------------------------------------------------------

#[test]
fn ffi_brief_dates_returns_descending_capped() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
        for (d, ts) in [("2026-05-20", 1u64), ("2026-05-22", 3), ("2026-05-21", 2)] {
            seed_brief(&writer, d, ts, "body");
        }
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let raw = unsafe { mci_brain_ffi_brief_dates(h, 10) };
    let s = read_owned(raw);
    let dates: Vec<String> = serde_json::from_str(&s).expect("JSON array of strings");
    assert_eq!(dates, vec!["2026-05-22", "2026-05-21", "2026-05-20"]);

    let raw = unsafe { mci_brain_ffi_brief_dates(h, 2) };
    let s = read_owned(raw);
    let dates: Vec<String> = serde_json::from_str(&s).expect("JSON array");
    assert_eq!(dates, vec!["2026-05-22", "2026-05-21"]);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 5. null handle and null date_local are rejected without segfaulting
// ---------------------------------------------------------------------------

#[test]
fn ffi_brief_for_date_with_null_handle_returns_null() {
    let date_c = CString::new("2026-05-22").unwrap();
    let raw = unsafe { mci_brain_ffi_brief_for_date(std::ptr::null_mut(), date_c.as_ptr()) };
    assert!(raw.is_null());
}

#[test]
fn ffi_brief_for_date_with_null_date_returns_null() {
    let (_dir, path, raw_key) = fresh_db();
    {
        let _writer = SqlCipherBrainStore::new(&path, &DbKey::from_bytes(raw_key)).expect("writer");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };

    let raw = unsafe { mci_brain_ffi_brief_for_date(h, std::ptr::null()) };
    assert!(raw.is_null());

    unsafe { mci_brain_ffi_close(h) };
}
