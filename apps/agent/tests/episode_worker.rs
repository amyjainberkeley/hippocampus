//! Integration tests for the episode worker against a real `SqlCipherBrainStore`.
//!
//! Each test creates a hermetic tempfile-backed encrypted brain, seeds events
//! via `put_event`, runs the episode worker for one cycle (immediate shutdown),
//! and asserts episode assignments.
//!
//! # CSO sign-off notes
//!
//! (a) Worker only UPDATEs `events.episode_id` on existing rows; never INSERTs
//!     events. cascade_reason=0 wall preserved.
//! (b) Hermetic — every brain lives in a `tempfile::TempDir`, disposed on drop.
//! (c) Zero new third-party crates.

use std::sync::Arc;
use std::time::Duration;

use mci_agent::episode_worker;
use mci_brain::episode_segmenter::HeuristicEpisodeSegmenter;
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test_episode.sqlite");
    let key = DbKey::from_bytes([0xCC; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store)
}

fn make_event(ts_us: u64, app: Option<&str>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: app.map(String::from),
        window_title: None,
        url: None,
        text: "test text".into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

async fn run_one_cycle(store: &Arc<SqlCipherBrainStore>) -> episode_worker::SegmentWorkerStats {
    let (tx, rx) = tokio::sync::watch::channel(false);
    let segmenter = Arc::new(HeuristicEpisodeSegmenter::new());
    let store_c = Arc::clone(store);

    // Spawn the worker; it will process one batch then idle-sleep.
    // We send shutdown after a short delay to let it finish one cycle.
    let handle = tokio::spawn(async move {
        episode_worker::run_episode_worker(
            store_c,
            segmenter,
            256,
            Duration::from_millis(50),
            rx,
        )
        .await
    });

    // Give worker time to process the batch and enter idle sleep.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = tx.send(true);

    handle.await.unwrap().unwrap()
}

/// 5 events from 5 different apps → 5 distinct episodes.
#[tokio::test]
async fn five_different_apps_five_episodes() {
    let (_dir, store) = open_temp_store();
    let base = 1_000_000u64;
    let apps = [
        "com.apple.Safari",
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.tinyspeck.slackmacgap",
        "com.apple.mail",
    ];
    for (i, app) in apps.iter().enumerate() {
        let ev = make_event(base + (i as u64) * 1_000_000, Some(app));
        store.put_event(&ev).unwrap();
    }

    let stats = run_one_cycle(&store).await;
    assert_eq!(stats.events_assigned, 5);
    assert_eq!(stats.episodes_created, 5);
}

/// 5 events same app within 10 minutes → 1 episode.
#[tokio::test]
async fn five_same_app_within_gap_one_episode() {
    let (_dir, store) = open_temp_store();
    let base = 1_000_000u64;
    for i in 0..5 {
        let ev = make_event(
            base + i * 2 * 60 * 1_000_000, // 2-minute intervals
            Some("com.apple.Safari"),
        );
        store.put_event(&ev).unwrap();
    }

    let stats = run_one_cycle(&store).await;
    assert_eq!(stats.events_assigned, 5);
    assert_eq!(stats.episodes_created, 1);
}

/// Gap >10 minutes between events in same app → new episode.
#[tokio::test]
async fn gap_exceeds_threshold_new_episode() {
    let (_dir, store) = open_temp_store();
    let base = 1_000_000u64;
    // First cluster: 3 events at 0, 3min, 6min
    for i in 0..3 {
        let ev = make_event(
            base + i * 3 * 60 * 1_000_000,
            Some("com.apple.Safari"),
        );
        store.put_event(&ev).unwrap();
    }
    // Gap: 11 minutes from last event (6min + 11min = 17min mark)
    // Second cluster: 2 events at 17min, 19min
    for i in 0..2 {
        let ev = make_event(
            base + (17 + i * 2) * 60 * 1_000_000,
            Some("com.apple.Safari"),
        );
        store.put_event(&ev).unwrap();
    }

    let stats = run_one_cycle(&store).await;
    assert_eq!(stats.events_assigned, 5);
    assert_eq!(stats.episodes_created, 2);
}

/// Empty store → worker exits cleanly with zero stats.
#[tokio::test]
async fn empty_store_noop() {
    let (_dir, store) = open_temp_store();
    let stats = run_one_cycle(&store).await;
    assert_eq!(stats.events_assigned, 0);
    assert_eq!(stats.episodes_created, 0);
    assert_eq!(stats.batches_run, 0);
}

/// Mixed scenario: app switch mid-session creates correct episode boundaries.
#[tokio::test]
async fn app_switch_creates_boundary() {
    let (_dir, store) = open_temp_store();
    let base = 1_000_000u64;
    // Safari for 3 events (1-second intervals)
    for i in 0..3 {
        store
            .put_event(&make_event(base + i * 1_000_000, Some("com.apple.Safari")))
            .unwrap();
    }
    // Switch to VSCode for 2 events
    for i in 0..2 {
        store
            .put_event(&make_event(
                base + (3 + i) * 1_000_000,
                Some("com.microsoft.VSCode"),
            ))
            .unwrap();
    }

    let stats = run_one_cycle(&store).await;
    assert_eq!(stats.events_assigned, 5);
    assert_eq!(stats.episodes_created, 2);
}
