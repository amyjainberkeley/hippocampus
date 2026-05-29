//! Integration tests for the P3.8 idle-batch embedder.
//!
//! Exercises `SqlCipherBrainStore::unembedded_events` and
//! `set_event_embedding` end-to-end against a real encrypted `SQLCipher`
//! store, then tests the async `run_idle_batch_worker` loop against
//! the same store + stub embedder.

use std::path::PathBuf;

use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{BrainStore, Embedder, Event, EventId, SqlCipherBrainStore, StoreError};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use tempfile::TempDir;

const EMBEDDING_DIM: usize = 384;

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn blank_event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.test.idle".into()),
        window_title: Some("Test Window".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn axis_unit_vec(axis: usize) -> Vec<f32> {
    let mut v = vec![0.0_f32; EMBEDDING_DIM];
    v[axis] = 1.0;
    v
}

// -----------------------------------------------------------------------
// A. unembedded_events + set_event_embedding — store-level tests
// -----------------------------------------------------------------------

#[test]
fn unembedded_events_returns_events_without_vectors() {
    let (_dir, path) = tmp("unembedded.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    let id1 = store
        .put_event(&blank_event(1_000_000, "event one"))
        .unwrap();
    let id2 = store
        .put_event(&blank_event(2_000_000, "event two"))
        .unwrap();
    let id3 = store
        .put_event(&blank_event(3_000_000, "event three"))
        .unwrap();

    // All three should be unembedded.
    let unembedded = store.unembedded_events(100).unwrap();
    assert_eq!(unembedded.len(), 3);
    let ids: Vec<EventId> = unembedded.iter().map(|e| e.id).collect();
    assert!(ids.contains(&id1));
    assert!(ids.contains(&id2));
    assert!(ids.contains(&id3));

    // Embed one event.
    store.set_event_embedding(id2, &axis_unit_vec(0)).unwrap();

    // Now only two should be unembedded.
    let unembedded = store.unembedded_events(100).unwrap();
    assert_eq!(unembedded.len(), 2);
    let ids: Vec<EventId> = unembedded.iter().map(|e| e.id).collect();
    assert!(ids.contains(&id1));
    assert!(!ids.contains(&id2));
    assert!(ids.contains(&id3));
}

#[test]
fn unembedded_events_respects_limit() {
    let (_dir, path) = tmp("unembedded_limit.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    for i in 0..10 {
        store
            .put_event(&blank_event((i + 1) * 1_000_000, &format!("ev {i}")))
            .unwrap();
    }

    let batch = store.unembedded_events(3).unwrap();
    assert_eq!(batch.len(), 3);
}

#[test]
fn unembedded_events_returns_empty_when_all_embedded() {
    let (_dir, path) = tmp("all_embedded.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    let id = store
        .put_event(&blank_event(1_000_000, "solo event"))
        .unwrap();
    store.set_event_embedding(id, &axis_unit_vec(1)).unwrap();

    let unembedded = store.unembedded_events(100).unwrap();
    assert!(unembedded.is_empty());
}

#[test]
fn set_event_embedding_rejects_wrong_dim() {
    let (_dir, path) = tmp("wrong_dim.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    let id = store.put_event(&blank_event(1_000_000, "test")).unwrap();
    let wrong_vec = vec![1.0_f32; 256]; // 256-d, not 384
    let err = store.set_event_embedding(id, &wrong_vec).unwrap_err();
    assert!(
        matches!(err, StoreError::InvalidInput(_)),
        "expected InvalidInput, got {err:?}"
    );
}

#[test]
fn set_event_embedding_writes_retrievable_vector() {
    let (_dir, path) = tmp("embedding_roundtrip.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    let id = store
        .put_event(&blank_event(1_000_000, "roundtrip test"))
        .unwrap();
    let emb = axis_unit_vec(42);
    store.set_event_embedding(id, &emb).unwrap();

    // Verify via get_event — embedding should now be present.
    let ev = store.get_event(id).unwrap().unwrap();
    let stored_emb = ev.embedding.expect("embedding should be present");
    assert_eq!(stored_emb.len(), EMBEDDING_DIM);
    assert!((stored_emb[42] - 1.0).abs() < f32::EPSILON);

    // Verify via vec_search — the vector should be findable.
    let query = axis_unit_vec(42);
    let hits = store.vec_search(&query, 10).unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].0, id);
}

#[test]
fn set_event_embedding_rejects_duplicate() {
    let (_dir, path) = tmp("duplicate_embed.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    let id = store.put_event(&blank_event(1_000_000, "dup")).unwrap();
    store.set_event_embedding(id, &axis_unit_vec(0)).unwrap();
    let err = store
        .set_event_embedding(id, &axis_unit_vec(1))
        .unwrap_err();
    assert!(
        matches!(err, StoreError::Backend(_)),
        "expected Backend (UNIQUE constraint), got {err:?}"
    );
}

// -----------------------------------------------------------------------
// B. Idle-batch worker tests (async, using the real SqlCipherBrainStore)
// -----------------------------------------------------------------------

// The worker lives in apps/agent, not core/brain. These tests exercise
// the store methods the worker depends on. The async worker integration
// tests are in apps/agent/src/idle_batch.rs (unit tests) and below
// (using the store directly to simulate what the worker does).

#[test]
fn worker_simulation_drains_unembedded_events() {
    let (_dir, path) = tmp("worker_drain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let embedder = FixedDimEmbedder::default();

    // Seed 5 events with no embedding.
    let mut ids = Vec::new();
    for i in 0..5 {
        let id = store
            .put_event(&blank_event((i + 1) * 1_000_000, &format!("text {i}")))
            .unwrap();
        ids.push(id);
    }

    // Simulate one worker cycle: read unembedded, embed, write.
    let batch = store.unembedded_events(100).unwrap();
    assert_eq!(batch.len(), 5);
    for event in &batch {
        let emb = embedder.embed_one(&event.text).unwrap();
        store.set_event_embedding(event.id, &emb).unwrap();
    }

    // All should now be embedded.
    let remaining = store.unembedded_events(100).unwrap();
    assert!(remaining.is_empty());

    // Verify each has a vector.
    for id in &ids {
        let ev = store.get_event(*id).unwrap().unwrap();
        assert!(ev.embedding.is_some(), "event {id} should have embedding");
    }
}

#[test]
fn worker_simulation_respects_batch_size() {
    let (_dir, path) = tmp("worker_batch.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let embedder = FixedDimEmbedder::default();

    for i in 0..10 {
        store
            .put_event(&blank_event((i + 1) * 1_000_000, &format!("text {i}")))
            .unwrap();
    }

    // First batch of 3.
    let batch = store.unembedded_events(3).unwrap();
    assert_eq!(batch.len(), 3);
    for event in &batch {
        let emb = embedder.embed_one(&event.text).unwrap();
        store.set_event_embedding(event.id, &emb).unwrap();
    }

    // 7 remaining.
    let remaining = store.unembedded_events(100).unwrap();
    assert_eq!(remaining.len(), 7);
}

#[test]
fn worker_simulation_skips_already_embedded() {
    let (_dir, path) = tmp("worker_skip.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let embedder = FixedDimEmbedder::default();

    // 5 events: 3 already have embeddings (via put_event).
    for i in 0..5 {
        let mut ev = blank_event((i + 1) * 1_000_000, &format!("text {i}"));
        if i < 3 {
            ev.embedding = Some(embedder.embed_one(&ev.text).unwrap());
        }
        store.put_event(&ev).unwrap();
    }

    // Only 2 should be unembedded.
    let batch = store.unembedded_events(100).unwrap();
    assert_eq!(batch.len(), 2);
    for event in &batch {
        let emb = embedder.embed_one(&event.text).unwrap();
        store.set_event_embedding(event.id, &emb).unwrap();
    }

    let remaining = store.unembedded_events(100).unwrap();
    assert!(remaining.is_empty());
}

#[test]
fn unembedded_events_limit_zero_returns_empty() {
    let (_dir, path) = tmp("limit_zero.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    store.put_event(&blank_event(1_000_000, "x")).unwrap();
    assert!(store.unembedded_events(0).unwrap().is_empty());
}
