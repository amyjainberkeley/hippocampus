//! Integration test for `mci-agent enrich`.
//!
//! Pins the gap this closes: the five workers that turn events into
//! entities, episodes and identities were reachable only from the
//! live-capture ingest path, so on any brain filled another way they never
//! ran and the store stayed at `Entities: 0, Episode links: 0`.
//!
//! Runs against a real `SqlCipherBrainStore`. Events are shaped the way the
//! ingest path shapes them — a context header carrying the URL, per
//! ADR-0010 §3 — because Tier-1 extracts from `event.text`, not from the
//! `url` column. The seeder omits that header, which is why enriching the
//! demo brain finds almost nothing and why this test builds its own.

use mci_agent::enrich::{extract_until_drained, run_enrich};
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use tempfile::TempDir;

/// An event shaped like the ingest path produces: context header first,
/// then the body. Without the header there is no URL in `text` for Tier-1
/// to find.
fn event(ts_us: u64, app: &str, url: &str, body: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.into()),
        window_title: Some("test window".into()),
        url: Some(url.into()),
        text: format!("[app={app} | url={url}]\n{body}"),
        embedding: None,
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
    }
}

fn store_with(events: Vec<Event>) -> (TempDir, SqlCipherBrainStore) {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::generate().expect("csprng");
    let store = SqlCipherBrainStore::new(&path, &key).expect("open store");
    for e in &events {
        store.put_event(e).expect("put_event");
    }
    (dir, store)
}

const MIN: u64 = 60 * 1_000_000;

/// Two runs of the same app, separated by a long gap.
fn realistic_events() -> Vec<Event> {
    let t0 = 1_700_000_000_000_000u64;
    vec![
        event(
            t0,
            "com.apple.Safari",
            "https://example.com/pricing",
            "pricing page",
        ),
        event(
            t0 + MIN,
            "com.apple.Safari",
            "https://example.com/docs",
            "the docs",
        ),
        event(
            t0 + 2 * MIN,
            "com.apple.Safari",
            "https://example.com/faq",
            "the faq",
        ),
        // 40 minutes later, past the 10-minute episode gap.
        event(
            t0 + 42 * MIN,
            "com.microsoft.VSCode",
            "https://github.com/a/b",
            "editing",
        ),
        event(
            t0 + 43 * MIN,
            "com.microsoft.VSCode",
            "https://github.com/a/c",
            "still editing",
        ),
    ]
}

#[test]
fn extract_finds_entities_the_capture_path_would_have_found() {
    let (_dir, store) = store_with(realistic_events());

    assert_eq!(
        store.stats().expect("stats").entity_count,
        0,
        "a freshly filled brain has no entities, which is the whole problem"
    );

    let (scanned, mentions) = extract_until_drained(&store, 2, |_| {}).expect("extract");

    assert_eq!(scanned, 5, "every event should be scanned");
    assert!(
        mentions >= 5,
        "expected a URL mention per event, got {mentions}"
    );
    assert!(store.stats().expect("stats").entity_count > 0);
}

#[test]
fn extract_is_idempotent() {
    let (_dir, store) = store_with(realistic_events());

    let (_, first) = extract_until_drained(&store, 8, |_| {}).expect("first");
    assert!(first > 0);
    let after_first = store.stats().expect("stats").entity_count;

    // Re-running must not duplicate: entity and mention ids are content
    // derived, so the writes collapse to INSERT OR IGNORE no-ops.
    // The return value counts rows *offered*, not inserted, so the store
    // is the thing to assert on: INSERT OR IGNORE must collapse the re-run.
    let mentions_after_first = store.stats().expect("stats").entity_mention_count;
    let (_, _) = extract_until_drained(&store, 8, |_| {}).expect("second");
    assert_eq!(
        store.stats().expect("stats").entity_count,
        after_first,
        "entity count must not grow on a re-run"
    );
    assert_eq!(
        store.stats().expect("stats").entity_mention_count,
        mentions_after_first,
        "mention count must not grow on a re-run"
    );
}

#[test]
fn extract_walks_past_events_sharing_a_timestamp() {
    // The cursor advances by timestamp. Two events at the same instant must
    // not stall the walk or get skipped.
    let t0 = 1_700_000_000_000_000u64;
    let (_dir, store) = store_with(vec![
        event(t0, "com.apple.Safari", "https://example.com/one", "one"),
        event(t0, "com.apple.Safari", "https://example.com/two", "two"),
        event(
            t0 + MIN,
            "com.apple.Safari",
            "https://example.com/three",
            "three",
        ),
    ]);

    let (scanned, _) = extract_until_drained(&store, 1, |_| {}).expect("extract");
    assert_eq!(
        scanned, 3,
        "all three events should be scanned exactly once"
    );
}

#[test]
fn full_enrich_segments_episodes_by_gap_and_app() {
    let (_dir, store) = store_with(realistic_events());

    let stats = run_enrich(&store, None, 8, |_, _| {}).expect("enrich");

    assert_eq!(stats.events_scanned, 5);
    assert_eq!(stats.events_segmented, 5, "every event lands in an episode");
    // Three Safari events inside the gap, then a 40-minute jump and an app
    // switch: two episodes, not five.
    assert_eq!(
        stats.episodes_created, 2,
        "expected one episode per contiguous run, got {}",
        stats.episodes_created
    );
    assert_eq!(stats.embedded, 0, "no embedder was supplied");
}

#[test]
fn full_enrich_is_idempotent() {
    let (_dir, store) = store_with(realistic_events());

    let first = run_enrich(&store, None, 8, |_, _| {}).expect("first");
    assert!(first.mentions_written > 0);
    assert!(first.episodes_created > 0);

    let second = run_enrich(&store, None, 8, |_, _| {}).expect("second");
    assert_eq!(second.mentions_written, 0, "no new mentions on a re-run");
    assert_eq!(second.events_segmented, 0, "no re-segmentation");
    assert_eq!(second.episodes_created, 0, "no duplicate episodes");
}

#[test]
fn enrich_runs_every_stage_without_an_embedder() {
    // The embed stage needs a 66 MB Core ML model that is not in the repo.
    // Everything else must still run, because entities, episodes and
    // identities need no model at all.
    let (_dir, store) = store_with(realistic_events());

    let mut seen: Vec<String> = Vec::new();
    let stats = run_enrich(&store, None, 8, |stage, _| {
        let label = stage.label().to_string();
        if seen.last() != Some(&label) {
            seen.push(label);
        }
    })
    .expect("enrich");

    assert_eq!(
        seen,
        vec!["extract", "embed", "segment", "resolve", "consolidate"],
        "all five stages should report, in dependency order"
    );
    assert!(stats.mentions_written > 0, "extraction still did real work");
}
