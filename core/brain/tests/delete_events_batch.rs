//! Forgetting several moments at once (SPEC 3.11): one transaction for the
//! whole forget, and the cleanup after it once, not once per moment. The
//! window forgets a selection, a page or a search this way, inside the hold
//! remembering waits in. Every moment here is made up.

use std::path::PathBuf;

use mci_brain::reading::Reading;
use mci_brain::{BrainStore, Event, EventId, MomentReading, SqlCipherBrainStore, READING_VERSION};
use mci_core::crypto::DbKey;

fn store() -> (tempfile::TempDir, PathBuf, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([7; 32])).expect("open");
    (dir, path, store)
}

fn moment(ts_us: u64, text: &str, blob: Option<&str>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.microsoft.VSCode".into()),
        window_title: Some("tax.rs \u{2014} trailhead-shop".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: blob.map(Into::into),
        tab_id: None,
        embedding: None,
    }
}

#[test]
fn one_call_forgets_every_picked_moment_and_keeps_the_rest() {
    let (_dir, _path, store) = store();
    let ids = (0..6_u64)
        .map(|n| {
            store
                .put_event(&moment(100 + n, &format!("rounding note {n}"), None))
                .expect("put")
        })
        .collect::<Vec<_>>();

    let outcome = store
        .delete_events_with_outcome(&[ids[0], ids[2], ids[4]])
        .expect("one committed transaction");

    assert_eq!(outcome.events_deleted, 3);
    assert!(outcome.vacuum_ok());
    assert!(outcome.blob_cleanup_ok());
    for (n, id) in ids.iter().enumerate() {
        let kept = store.get_event(*id).expect("read").is_some();
        assert_eq!(kept, n % 2 == 1, "moment {n}");
    }
}

#[test]
fn a_moment_already_gone_or_picked_twice_counts_once_and_is_no_error() {
    let (_dir, _path, store) = store();
    let id = store
        .put_event(&moment(100, "gift card copy", None))
        .expect("put");
    let outcome = store
        .delete_events_with_outcome(&[id, id, EventId(9_999_999), EventId(u64::MAX)])
        .expect("nothing missing is an error");
    assert_eq!(outcome.events_deleted, 1);
    let again = store
        .delete_events_with_outcome(&[id])
        .expect("forgetting it again deletes nothing");
    assert_eq!(again.events_deleted, 0);
    assert_eq!(
        store
            .delete_events_with_outcome(&[])
            .expect("an empty forget")
            .events_deleted,
        0
    );
}

#[test]
fn their_screenshots_go_once_no_moment_left_shows_them() {
    let (_dir, path, store) = store();
    let blobs = path.parent().expect("parent").join("blobs");
    std::fs::create_dir(&blobs).expect("blob dir");
    let shared = "a".repeat(64);
    let own = "b".repeat(64);
    let kept = "c".repeat(64);
    for digest in [&shared, &own, &kept] {
        std::fs::write(blobs.join(format!("{digest}.bin")), b"sealed").expect("blob");
    }
    let first = store
        .put_event(&moment(100, "first", Some(&shared)))
        .expect("put");
    let second = store
        .put_event(&moment(200, "second", Some(&shared)))
        .expect("put");
    let third = store
        .put_event(&moment(300, "third", Some(&own)))
        .expect("put");
    let other = store
        .put_event(&moment(400, "kept", Some(&kept)))
        .expect("put");

    let outcome = store
        .delete_events_with_outcome(&[first, second, third])
        .expect("delete");

    assert_eq!(outcome.events_deleted, 3);
    assert!(
        !blobs.join(format!("{shared}.bin")).exists(),
        "both of its moments went"
    );
    assert!(!blobs.join(format!("{own}.bin")).exists());
    assert!(
        blobs.join(format!("{kept}.bin")).exists(),
        "a kept moment keeps its screenshot"
    );
    assert!(store.get_event(other).expect("read").is_some());
}

#[test]
fn their_readings_and_captions_go_with_them() {
    let (_dir, _path, store) = store();
    let ids = (0..3_u64)
        .map(|n| {
            let id = store
                .put_event(&moment(100 + n, &format!("tiered pricing {n}"), None))
                .expect("put");
            let read = store.stored_moment(id).expect("read").expect("stored");
            assert!(store
                .put_moment_reading(
                    &MomentReading {
                        event_id: id,
                        version: READING_VERSION,
                        reading: Some(Reading {
                            main: format!("tiered pricing {n}"),
                            rest: String::new(),
                        }),
                        caption: Some("Editing tax.rs".into()),
                        caption_by: Some("title".into()),
                        model_tried: false,
                        updated_us: 500,
                    },
                    &read,
                )
                .expect("reading"));
            id
        })
        .collect::<Vec<_>>();

    store.delete_events_with_outcome(&ids[..2]).expect("delete");

    assert_eq!(store.moment_reading(ids[0]).expect("read"), None);
    assert_eq!(store.moment_reading(ids[1]).expect("read"), None);
    assert!(store.moment_reading(ids[2]).expect("read").is_some());
}
