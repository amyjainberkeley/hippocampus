//! Integration test for `idle_batch::backfill_until_drained`, the loop
//! behind `mci-agent embed-backfill`.
//!
//! What this pins is the gap that made semantic recall dead on arrival:
//! the store had every piece (`unembedded_events` to find work,
//! `set_event_embedding` to write, `vec_search` to read) and nothing
//! joined them up, so `event_vectors` stayed empty and `HybridRetriever`
//! silently had no semantic side to fuse.
//!
//! Runs against a real `SqlCipherBrainStore` on a temp file, with the
//! deterministic `FixedDimEmbedder` stub standing in for Core ML. That
//! keeps the test honest about the plumbing without needing the 33 MB
//! `.mlpackage`, which is not in the repository.

use mci_agent::idle_batch::backfill_until_drained;
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use tempfile::TempDir;

fn event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.app".into()),
        window_title: Some("test window".into()),
        url: None,
        text: text.into(),
        // Left None on purpose: an event carrying its own embedding would
        // never appear in the un-embedded queue, which is the thing under
        // test here.
        embedding: None,
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
    }
}

fn store_with(events: &[(u64, &str)]) -> (TempDir, SqlCipherBrainStore) {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::generate().expect("csprng");
    let store = SqlCipherBrainStore::new(&path, &key).expect("open store");
    for (ts, text) in events {
        store.put_event(&event(*ts, text)).expect("put_event");
    }
    (dir, store)
}

#[test]
fn backfill_embeds_every_event_then_drains() {
    let (_dir, store) = store_with(&[
        (
            1_000,
            "sqlite-vec provides vector search via the vec0 virtual table",
        ),
        (2_000, "ScreenCaptureKit delivers frames via SCStreamOutput"),
        (3_000, "the cascade blocks capture on password prompts"),
    ]);

    // Precondition: nothing embedded, so all three are queued.
    assert_eq!(
        store.unembedded_events(10).expect("query").len(),
        3,
        "all events should start un-embedded"
    );

    let embedder = FixedDimEmbedder::default();
    let stats =
        backfill_until_drained(&store, &embedder, 2, |_| {}).expect("backfill should succeed");

    assert_eq!(stats.events_embedded, 3);
    assert_eq!(stats.embed_errors, 0);
    assert_eq!(stats.store_errors, 0);
    // batch_size 2 over 3 events: two full reads plus the drain check.
    assert!(
        stats.batches_run >= 2,
        "expected >=2 batches, got {}",
        stats.batches_run
    );

    // Postcondition: the queue is empty, which is what makes this
    // idempotent. A second run must find nothing rather than
    // re-embedding and tripping the UNIQUE constraint.
    assert_eq!(
        store.unembedded_events(10).expect("query").len(),
        0,
        "queue should be drained"
    );
}

#[test]
fn backfill_is_idempotent() {
    let (_dir, store) = store_with(&[(1_000, "first"), (2_000, "second")]);
    let embedder = FixedDimEmbedder::default();

    let first = backfill_until_drained(&store, &embedder, 8, |_| {}).expect("first run");
    assert_eq!(first.events_embedded, 2);

    // Running again must be a no-op, not a UNIQUE violation.
    let second = backfill_until_drained(&store, &embedder, 8, |_| {}).expect("second run");
    assert_eq!(second.events_embedded, 0);
    assert_eq!(second.store_errors, 0);
    assert_eq!(second.batches_run, 0);
}

#[test]
fn embedded_events_become_findable_by_vector_search() {
    // The point of the whole exercise: after backfill there is a
    // semantic side for HybridRetriever to fuse. Before it, vec_search
    // returns nothing no matter what the query is.
    let (_dir, store) = store_with(&[
        (1_000, "sqlite-vec provides vector search"),
        (2_000, "ScreenCaptureKit delivers frames"),
    ]);
    let embedder = FixedDimEmbedder::default();

    let probe = mci_brain::Embedder::embed_one(&embedder, "sqlite-vec provides vector search")
        .expect("embed probe");

    assert!(
        store.vec_search(&probe, 5).expect("vec_search").is_empty(),
        "no vectors should exist before backfill"
    );

    backfill_until_drained(&store, &embedder, 8, |_| {}).expect("backfill");

    let hits = store.vec_search(&probe, 5).expect("vec_search");
    assert_eq!(hits.len(), 2, "both events should now be searchable");

    // FixedDimEmbedder is deterministic, so the exact text used as the
    // probe must come back as the nearest neighbour.
    assert_eq!(
        hits[0].0,
        EventId(1),
        "the event whose text matches the probe should rank first"
    );
}
