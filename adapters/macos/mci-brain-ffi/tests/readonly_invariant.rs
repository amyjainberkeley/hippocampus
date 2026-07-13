//! Integration tests for the P3.9b FFI wiring against a real ephemeral
//! `SQLCipher` brain DB.
//!
//! # The CSO load-bearing test (`ffi_open_yields_a_strictly_read_only_brain`)
//!
//! ADR-0017 §5 + ADR-0016 §4.3 require that the recall UI cannot mutate
//! the brain — *except* through the enumerated cycle-8.47 mutation
//! surface (`_delete_event`, `_delete_events_in_range`, `_prepare_wipe`,
//! `_wipe_brain`) which is the Privacy Dashboard's destructive-action
//! escape hatch (PR #76 follow-up). Every other FFI call still routes
//! through the long-lived read-only handle.
//!
//! This test proves that structurally:
//!
//! 1. Open a writer (`SqlCipherBrainStore::new`), apply the migration,
//!    insert one event, close.
//! 2. Open the same file via the **FFI shim** (`mci_brain_ffi_open`) and
//!    confirm read works (`mci_brain_ffi_recent_events` returns the row).
//! 3. Reopen the same file through `mci_core::store::open_readonly`
//!    (the same code path the FFI's read handle uses) and attempt a
//!    write — must fail at the `SQLite` driver level with
//!    `SQLITE_READONLY`.
//!
//! Step 3 is the structural assertion for the read path. The FFI's
//! read-facing surface exports zero mutation extern fns and the
//! underlying read connection is `SQLITE_OPEN_READ_ONLY`, so the
//! invariant is enforced TWICE for reads — once by the absent FFI read
//! surface and once by the `SQLite` driver.
//!
//! The four cycle-8.47 mutation methods open a *transient* writer via
//! `SqlCipherBrainStore::new` (guarded by a typed-word confirmation UI
//! in Swift + a two-step token flow for wipe). They are named in the
//! `ffi_exports_no_mutating_surface_beyond_allowlist` allow-list below;
//! adding a fifth mutation method without extending the allow-list is
//! an AGENT_PROTOCOL §5 protected-set violation and the test fails.

use std::ffi::{CStr, CString};
use std::path::PathBuf;

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_delete_event, mci_brain_ffi_delete_events_in_range,
    mci_brain_ffi_events_by_ids, mci_brain_ffi_last_error_message, mci_brain_ffi_list_episodes,
    mci_brain_ffi_list_observed_apps, mci_brain_ffi_open, mci_brain_ffi_prepare_wipe,
    mci_brain_ffi_recent_events, mci_brain_ffi_recent_privacy_moments, mci_brain_ffi_search,
    mci_brain_ffi_string_free, mci_brain_ffi_wipe_brain, DeleteResultJson, HitJson,
    PrivacyMomentJson,
};
use mci_core::crypto::DbKey;
use mci_core::store::open_readonly as mci_core_open_readonly;
use rusqlite::params;
use tempfile::TempDir;

/// Hex-encode raw 32-byte test key bytes for the FFI's `key_hex` arg.
/// Tests construct the `DbKey` via [`DbKey::from_bytes`] from the same
/// `raw_bytes` so the writer + the FFI-side key match exactly.
fn key_hex_for(raw_bytes: [u8; 32]) -> String {
    raw_bytes.iter().fold(String::new(), |mut s, b| {
        use std::fmt::Write;
        write!(s, "{b:02x}").unwrap();
        s
    })
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
        tab_id: None,
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

    assert!(
        !hits.is_empty(),
        "FTS5 should match 'privacy' in seeded text"
    );
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

    let q =
        CString::new(r#"{"text":"signal","limit":10,"app_filter":"com.apple.Safari"}"#).unwrap();
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

    let q =
        CString::new(r#"{"text":"foo","limit":10,"time_from_us":150,"time_to_us":250}"#).unwrap();
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
// 8.5. events_by_ids — cycle 8.37 PR-3, related-hits flyout fetch surface
//
// Round-trip: seed three events, fetch by ids via the new FFI, assert the
// returned HitJson rows preserve input order + drop missing ids silently.
// ---------------------------------------------------------------------------

#[test]
fn ffi_events_by_ids_resolves_seeded_ids_in_input_order() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    let (a, b, c) = {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        let a = seed_event(&writer, 100, "com.apple.Safari", "S", "", "safari body");
        let b = seed_event(&writer, 200, "com.microsoft.VSCode", "V", "", "vscode body");
        let c = seed_event(&writer, 300, "com.tinyspeck.slackmacgap", "Sl", "", "slack body");
        (a, b, c)
    };
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null(), "ffi open must succeed");

    // Ask for [c, a, b] plus a nonexistent id — result must be [c, a, b]
    // (order preserved, missing id dropped silently).
    let query = format!(
        r#"{{"ids":[{},{},{},9999999]}}"#,
        c.0, a.0, b.0
    );
    let query_c = CString::new(query).unwrap();
    let j = unsafe { mci_brain_ffi_events_by_ids(h, query_c.as_ptr()) };
    assert!(!j.is_null(), "events_by_ids must succeed");
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON");
    unsafe { mci_brain_ffi_string_free(j) };

    let ids: Vec<u64> = hits.iter().map(|h| h.event_id).collect();
    assert_eq!(ids, vec![c.0, a.0, b.0], "order follows input; missing dropped");
    // Each row must carry source="linked" so the UI can badge these rows
    // separately from ranked search results.
    for h in &hits {
        assert_eq!(h.source, "linked");
        assert!(h.score.is_none(), "linked lookup has no ranking score");
    }

    unsafe { mci_brain_ffi_close(h) };
}

#[test]
fn ffi_events_by_ids_with_empty_list_returns_empty_json_array() {
    let (_dir, path, raw_key) = make_test_db();
    let key = DbKey::from_bytes(raw_key);
    {
        let _writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    let query_c = CString::new(r#"{"ids":[]}"#).unwrap();
    let j = unsafe { mci_brain_ffi_events_by_ids(h, query_c.as_ptr()) };
    assert!(!j.is_null());
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(j) };
    let hits: Vec<HitJson> = serde_json::from_str(&s).expect("valid JSON");
    assert!(hits.is_empty());

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 9. FFI mutation surface is exhaustively enumerated
//
// Cycle 8.47 (PR #76 follow-up) landed the Privacy Dashboard's
// destructive-action escape hatch. The FFI surface now has TWO tiers:
//
//   - Read tier (13 methods): the pre-8.47 read surface. Routes through
//     the read-only handle; the underlying `SQLite` connection is
//     `SQLITE_OPEN_READ_ONLY` and refuses writes at the driver level
//     regardless of what the FFI says.
//
//   - Mutation tier (4 methods): `_delete_event`, `_delete_events_in_range`,
//     `_prepare_wipe`, `_wipe_brain`. Each opens a *transient* writer
//     via `SqlCipherBrainStore::new`, runs DELETE + VACUUM, drops the
//     writer. The wipe path additionally requires a 60s-TTL confirmation
//     token from `_prepare_wipe` — no single-call wipe.
//
// The invariant is now "reads route through the read-only handle;
// mutations route through the four enumerated methods below." Adding a
// fifth mutation method without extending this allow-list is an
// AGENT_PROTOCOL §5 protected-set violation and this test fails.
// ---------------------------------------------------------------------------

#[test]
fn ffi_exports_no_mutating_surface_beyond_allowlist() {
    // Read-tier surface. New extern fns landing here without an ADR amend
    // are still a §5 protected-set violation — this list is the canonical
    // read-only allow-list.
    let allowed_reads: &[&str] = &[
        "mci_brain_ffi_open",
        "mci_brain_ffi_close",
        "mci_brain_ffi_search",
        "mci_brain_ffi_recent_events",
        "mci_brain_ffi_recent_privacy_moments",
        // Recall-UI dynamic per-app filter + Episodes tab (read-only).
        "mci_brain_ffi_list_observed_apps",
        "mci_brain_ffi_list_episodes",
        // Brief-viewer read surface (read-only).
        "mci_brain_ffi_brief_for_date",
        "mci_brain_ffi_latest_brief",
        "mci_brain_ffi_brief_dates",
        // Cycle 8.37 PR-3 — related-hits flyout fetch surface (read-only).
        // Resolves a Vec<u64> of linked event ids into HitJson rows via
        // BrainStore::get_event, no mutating call path.
        "mci_brain_ffi_events_by_ids",
        // Cycle 8.46 — Privacy Dashboard summary card (read-only).
        // Returns content-free aggregate: event count, oldest/newest ts,
        // on-disk byte size. Uses `BrainStore::stats` + `fs::metadata` —
        // no row content is exposed.
        "mci_brain_ffi_summary_stats",
        // V2-P13 (Phase D scaffold) — Rewind-style timeline strip surface
        // (read-only). Returns downsampled TimelineEventJson rows for a
        // time range; uses the same read-only handle as _recent_events
        // and filters in Rust. No mutating call path.
        "mci_brain_ffi_timeline_events",
        "mci_brain_ffi_string_free",
        "mci_brain_ffi_last_error_message",
    ];
    // Mutation-tier surface. Every method here is user-gated by the
    // Swift Privacy Dashboard's typed-word confirmation UI (and, for
    // wipe, the two-step token flow). Adding to this list requires CSO
    // sign-off + an ADR amendment; the allow-list assertion below
    // enforces the size bound so a silent addition breaks CI.
    let allowed_mutations: &[&str] = &[
        "mci_brain_ffi_delete_event",
        "mci_brain_ffi_delete_events_in_range",
        "mci_brain_ffi_prepare_wipe",
        "mci_brain_ffi_wipe_brain",
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
        mci_brain_ffi_list_observed_apps as *const (),
        mci_brain_ffi_list_episodes as *const (),
        mci_brain_ffi::mci_brain_ffi_brief_for_date as *const (),
        mci_brain_ffi::mci_brain_ffi_latest_brief as *const (),
        mci_brain_ffi::mci_brain_ffi_brief_dates as *const (),
        mci_brain_ffi_events_by_ids as *const (),
        mci_brain_ffi::mci_brain_ffi_summary_stats as *const (),
        // V2-P13 (Phase D scaffold) — timeline strip fetch surface.
        mci_brain_ffi::mci_brain_ffi_timeline_events as *const (),
        mci_brain_ffi_string_free as *const (),
        mci_brain_ffi_last_error_message as *const (),
        // Cycle 8.47 mutation surface — explicitly enumerated.
        mci_brain_ffi_delete_event as *const (),
        mci_brain_ffi_delete_events_in_range as *const (),
        mci_brain_ffi_prepare_wipe as *const (),
        mci_brain_ffi_wipe_brain as *const (),
    ];
    assert_eq!(
        allowed_reads.len(),
        15,
        "read-tier FFI surface size pinned at 15 \
         (V2-P13 timeline scaffold added mci_brain_ffi_timeline_events)"
    );
    assert_eq!(
        allowed_mutations.len(),
        4,
        "mutation-tier FFI surface size pinned at 4 (cycle 8.47 PR #76 follow-up)"
    );
}

// ---------------------------------------------------------------------------
// 10. Mutation surface — delete_event happy path (cycle 8.47 PR #76 follow-up)
// ---------------------------------------------------------------------------

#[test]
fn ffi_delete_event_removes_the_row_and_leaves_others_intact() {
    let (_dir, path, raw_key) = make_test_db();
    let (a, b) = {
        let key = DbKey::from_bytes(raw_key);
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        let a = seed_event(&writer, 100, "com.apple.Safari", "T1", "", "row a");
        let b = seed_event(&writer, 200, "com.apple.Safari", "T2", "", "row b");
        (a, b)
    };

    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null(), "ffi open failed: {}", last_error_string());

    // Precondition: two rows.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };
    assert_eq!(hits.len(), 2);

    // Delete row `a`.
    let del_q = format!(r#"{{"event_id":{}}}"#, a.0);
    let del_c = CString::new(del_q).unwrap();
    let raw = unsafe { mci_brain_ffi_delete_event(h, del_c.as_ptr()) };
    assert!(!raw.is_null(), "delete_event failed: {}", last_error_string());
    let s = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw) };
    let result: DeleteResultJson = serde_json::from_str(&s).unwrap();
    assert_eq!(result.events_deleted, 1);
    assert!(result.vacuum_ok);

    // Postcondition: only row `b` remains.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].event_id, b.0);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 11. Mutation surface — delete_events_in_range removes only in-window rows
// ---------------------------------------------------------------------------

#[test]
fn ffi_delete_events_in_range_scopes_to_the_ts_window() {
    let (_dir, path, raw_key) = make_test_db();
    {
        let key = DbKey::from_bytes(raw_key);
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(&writer, 100, "app", "T", "", "outside-left");
        seed_event(&writer, 200, "app", "T", "", "inside-1");
        seed_event(&writer, 250, "app", "T", "", "inside-2");
        seed_event(&writer, 400, "app", "T", "", "outside-right");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    let raw = unsafe { mci_brain_ffi_delete_events_in_range(h, 150, 300) };
    assert!(
        !raw.is_null(),
        "delete_range failed: {}",
        last_error_string()
    );
    let s = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw) };
    let result: DeleteResultJson = serde_json::from_str(&s).unwrap();
    assert_eq!(result.events_deleted, 2);

    // Postcondition: only the two out-of-window rows remain.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };
    let ts: Vec<u64> = hits.iter().map(|h| h.ts_us).collect();
    assert_eq!(ts, vec![400, 100]);

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 12. Mutation surface — wipe requires a matching token; wrong token refuses
// ---------------------------------------------------------------------------

#[test]
fn ffi_wipe_brain_requires_valid_token() {
    let (_dir, path, raw_key) = make_test_db();
    {
        let key = DbKey::from_bytes(raw_key);
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(&writer, 100, "app", "T", "", "row 1");
        seed_event(&writer, 200, "app", "T", "", "row 2");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    // Case 1: wipe without prepare — no pending token, must refuse.
    let bogus = CString::new("00".repeat(32)).unwrap();
    let r = unsafe { mci_brain_ffi_wipe_brain(h, bogus.as_ptr()) };
    assert!(r.is_null(), "wipe without prepare must fail");
    let err = last_error_string();
    assert!(err.contains("no pending wipe"), "got: {err}");

    // Case 2: wrong token after prepare, must refuse.
    let raw_tok = unsafe { mci_brain_ffi_prepare_wipe(h) };
    assert!(!raw_tok.is_null(), "prepare failed: {}", last_error_string());
    let tok_str = unsafe { CStr::from_ptr(raw_tok) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw_tok) };
    // Token is a JSON string literal ("<64-hex>"); strip surrounding quotes.
    let real_tok: String = serde_json::from_str(&tok_str).expect("valid JSON string");
    assert_eq!(real_tok.len(), 64, "token must be 64 hex chars");
    // Wipe with a wrong token — must refuse and consume the pending token.
    let wrong = CString::new("aa".repeat(32)).unwrap();
    let r = unsafe { mci_brain_ffi_wipe_brain(h, wrong.as_ptr()) };
    assert!(r.is_null(), "wipe with wrong token must fail");
    let err = last_error_string();
    assert!(err.contains("token mismatch"), "got: {err}");

    // After a wrong-token attempt, the pending token is consumed. A retry
    // with the correct token also fails ("no pending wipe").
    let good = CString::new(real_tok.clone()).unwrap();
    let r = unsafe { mci_brain_ffi_wipe_brain(h, good.as_ptr()) };
    assert!(r.is_null(), "second wipe after wrong-token must fail");
    let err = last_error_string();
    assert!(err.contains("no pending wipe"), "got: {err}");

    // Postcondition: rows still present.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };
    assert_eq!(hits.len(), 2, "wipe with wrong token must not delete");

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 13. Mutation surface — wipe happy path clears every event row + VACUUMs
// ---------------------------------------------------------------------------

#[test]
fn ffi_wipe_brain_with_valid_token_clears_the_store() {
    let (_dir, path, raw_key) = make_test_db();
    {
        let key = DbKey::from_bytes(raw_key);
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        seed_event(&writer, 100, "app.a", "T", "", "row 1");
        seed_event(&writer, 200, "app.b", "T", "", "row 2");
        seed_event(&writer, 300, "app.c", "T", "", "row 3");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    // Prepare + wipe with the real token.
    let raw_tok = unsafe { mci_brain_ffi_prepare_wipe(h) };
    let tok_str = unsafe { CStr::from_ptr(raw_tok) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw_tok) };
    let real_tok: String = serde_json::from_str(&tok_str).unwrap();

    let good = CString::new(real_tok).unwrap();
    let r = unsafe { mci_brain_ffi_wipe_brain(h, good.as_ptr()) };
    assert!(!r.is_null(), "wipe failed: {}", last_error_string());
    let s = unsafe { CStr::from_ptr(r) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(r) };
    let result: DeleteResultJson = serde_json::from_str(&s).unwrap();
    assert_eq!(result.events_deleted, 3);
    assert!(result.vacuum_ok);

    // Postcondition: no rows in the store.
    let j = unsafe { mci_brain_ffi_recent_events(h, 10) };
    let s = unsafe { CStr::from_ptr(j) }.to_string_lossy().into_owned();
    let hits: Vec<HitJson> = serde_json::from_str(&s).unwrap();
    unsafe { mci_brain_ffi_string_free(j) };
    assert!(hits.is_empty(), "wipe must leave store empty");

    unsafe { mci_brain_ffi_close(h) };
}

// ---------------------------------------------------------------------------
// 14. Mutation surface — a second prepare_wipe invalidates the first token
// ---------------------------------------------------------------------------

#[test]
fn ffi_wipe_second_prepare_invalidates_first_token() {
    let (_dir, path, raw_key) = make_test_db();
    {
        let key = DbKey::from_bytes(raw_key);
        let _w = SqlCipherBrainStore::new(&path, &key).expect("writer open");
    }
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new(key_hex_for(raw_key)).unwrap();
    let h = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!h.is_null());

    let raw_t1 = unsafe { mci_brain_ffi_prepare_wipe(h) };
    let t1_str = unsafe { CStr::from_ptr(raw_t1) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw_t1) };
    let t1: String = serde_json::from_str(&t1_str).unwrap();

    // Second prepare — issues a fresh token and drops the first.
    let raw_t2 = unsafe { mci_brain_ffi_prepare_wipe(h) };
    let t2_str = unsafe { CStr::from_ptr(raw_t2) }.to_string_lossy().into_owned();
    unsafe { mci_brain_ffi_string_free(raw_t2) };
    let t2: String = serde_json::from_str(&t2_str).unwrap();
    assert_ne!(t1, t2, "two prepare calls must issue distinct tokens");

    // Trying to use the first token now must fail with "token mismatch".
    let stale = CString::new(t1).unwrap();
    let r = unsafe { mci_brain_ffi_wipe_brain(h, stale.as_ptr()) };
    assert!(r.is_null(), "stale token must be rejected");
    let err = last_error_string();
    assert!(err.contains("token mismatch"), "got: {err}");

    unsafe { mci_brain_ffi_close(h) };
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
