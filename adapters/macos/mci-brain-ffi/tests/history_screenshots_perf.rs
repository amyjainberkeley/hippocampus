//! How long History's page takes to read when every moment looks for its
//! window's screenshot, on a heavy synthetic day: a front window read every
//! few seconds, five windows beside it read every fifteen, a screenshot kept
//! on four in ten front-window reads, and kilobytes of text per moment.
//!
//! Ignored by default (timing); run with
//! `cargo test -p mci-brain-ffi --offline --test history_screenshots_perf -- --ignored --nocapture`
//! (tests run unoptimized: the test key wrap is refused in release builds).

use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_open, mci_brain_ffi_search, mci_brain_ffi_string_free,
    HitJson,
};
use mci_core::crypto::DbKey;
use std::ffi::{CStr, CString};
use std::time::Instant;

const SECOND: u64 = 1_000_000;
const T0: u64 = 1_791_820_800_000_000;

fn text(seed: u64, len: usize) -> String {
    let words = [
        "rounding", "invoice", "launch", "checkout", "ledger", "subtotal", "review", "calendar",
    ];
    let mut out = String::with_capacity(len + 16);
    let mut n = seed;
    while out.len() < len {
        n = n
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        out.push_str(words[(n >> 33) as usize % words.len()]);
        out.push(if n % 9 == 0 { '\n' } else { ' ' });
    }
    out
}

#[test]
#[ignore = "timing; run by hand"]
fn a_history_page_on_a_heavy_day_reads_quickly() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mci.sqlite");
    let store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([42; 32])).unwrap();
    let windows = [
        "tax.rs \u{2014} trailhead-shop",
        "Rounding half to even",
        "#launch",
        "Inbox",
        "zsh",
    ];
    let mut kept = 0u32;
    let mut ts = T0;
    let mut n = 0u64;
    // Eight hours.
    while ts < T0 + 8 * 3_600 * SECOND {
        n += 1;
        let front = windows[((ts / (90 * SECOND)) % windows.len() as u64) as usize];
        let keyframe = (n % 5 < 2).then(|| format!("{n:064x}"));
        kept += u32::from(keyframe.is_some());
        let event = |title: &str, keyframe: Option<String>, len: usize| Event {
            id: EventId(0),
            ts_us: ts,
            app_bundle_id: Some("com.example.app".into()),
            window_title: Some(title.into()),
            url: None,
            text: text(n, len),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: keyframe,
            tab_id: None,
            embedding: None,
        };
        store
            .put_event_with_source(&event(front, keyframe, 6_000), EventSource::ScreenOcr)
            .unwrap();
        if n % 3 == 0 {
            for beside in windows.iter().filter(|title| **title != front) {
                store
                    .put_event_with_source(&event(beside, None, 3_000), EventSource::ScreenContext)
                    .unwrap();
            }
        }
        ts += 5 * SECOND;
    }
    drop(store);

    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key = CString::new("2a".repeat(32)).unwrap();
    let handle = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key.as_ptr()) };
    assert!(!handle.is_null());
    let query = CString::new(
        serde_json::json!({
            "text": "", "mode": "text", "browse": true, "limit": 101,
            "time_from_us": T0, "time_to_us": T0 + 8 * 3_600 * SECOND,
        })
        .to_string(),
    )
    .unwrap();
    let mut timings = Vec::new();
    let mut shown = 0;
    for _ in 0..5 {
        let started = Instant::now();
        let raw = unsafe { mci_brain_ffi_search(handle, query.as_ptr()) };
        timings.push(started.elapsed());
        let hits: Vec<HitJson> =
            serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
        unsafe { mci_brain_ffi_string_free(raw) };
        shown = hits
            .iter()
            .filter(|hit| hit.thumbnail_path.is_some())
            .count();
        assert_eq!(hits.len(), 101);
    }
    unsafe { mci_brain_ffi_close(handle) };
    timings.sort();
    println!(
        "front-window reads with a screenshot: {kept}; page of 101: {shown} show one; \
         fastest {:?}, median {:?}, slowest {:?}",
        timings[0], timings[2], timings[4]
    );
    assert!(
        timings[2].as_millis() < 250,
        "History's page took {:?}",
        timings[2]
    );
}
