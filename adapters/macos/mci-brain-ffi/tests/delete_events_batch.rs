//! The window forgets a whole selection, page or search with one delete call
//! (SPEC 3.11): `{"event_ids":[…]}` beside `{"event_id":…}`, so the writer
//! lease, the integrity check and the cleanup run once per forget and the
//! forget ends inside the hold remembering waits in. The mutation surface
//! stays four exports. Every moment here is made up.

use std::ffi::{CStr, CString};
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_delete_event, mci_brain_ffi_last_error_message,
    mci_brain_ffi_open, mci_brain_ffi_string_free, Handle, MAX_DELETE_EVENT_IDS,
};
use mci_core::crypto::DbKey;
use rustix::fs::{flock, FlockOperation};
use serde_json::Value;

const RAW: [u8; 32] = [7; 32];

struct Brain {
    _dir: tempfile::TempDir,
    path: PathBuf,
    handle: *mut Handle,
}

impl Brain {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("brain.sqlite");
        drop(SqlCipherBrainStore::new(&path, &DbKey::from_bytes(RAW)).expect("create"));
        let path_c = CString::new(path.to_str().expect("utf8")).expect("path");
        let key = CString::new("07".repeat(32)).expect("key");
        let handle = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self {
            _dir: dir,
            path,
            handle,
        }
    }

    fn writer(&self) -> SqlCipherBrainStore {
        SqlCipherBrainStore::new(&self.path, &DbKey::from_bytes(RAW)).expect("writer")
    }

    fn seed(&self, count: u64) -> Vec<EventId> {
        let writer = self.writer();
        (0..count)
            .map(|n| writer.put_event(&moment(1_000 + n, n)).expect("put"))
            .collect()
    }

    fn still_saved(&self, id: EventId) -> bool {
        self.writer().get_event(id).expect("read").is_some()
    }

    fn delete(&self, json: &str) -> Result<Value, String> {
        let query = CString::new(json).expect("json");
        let raw = unsafe { mci_brain_ffi_delete_event(self.handle, query.as_ptr()) };
        if raw.is_null() {
            return Err(last_error());
        }
        let bytes = unsafe { CStr::from_ptr(raw) }.to_bytes().to_vec();
        unsafe { mci_brain_ffi_string_free(raw) };
        Ok(serde_json::from_slice(&bytes).expect("json"))
    }
}

impl Drop for Brain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn moment(ts_us: u64, n: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.google.Chrome".into()),
        window_title: Some(format!("Rounding half to even {n} \u{b7} Dev Notes")),
        url: Some("https://devnotes.example/rounding".into()),
        text: format!("Ties go to the nearest even cent. Example {n}."),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn ids_json(ids: &[EventId]) -> String {
    let list = ids
        .iter()
        .map(|id| id.0.to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!(r#"{{"event_ids":[{list}]}}"#)
}

fn last_error() -> String {
    let p = unsafe { mci_brain_ffi_last_error_message() };
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn hold_writer_lease(brain: &Path) -> std::fs::File {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(brain.parent().expect("parent").join(".writer.lock"))
        .expect("lease");
    flock(&file, FlockOperation::NonBlockingLockExclusive).expect("hold lease");
    file
}

#[test]
fn a_whole_forget_is_one_call_and_keeps_every_other_moment() {
    let brain = Brain::new();
    let ids = brain.seed(25);
    let picked = &ids[..20];

    let result = brain.delete(&ids_json(picked)).expect("one committed call");

    assert_eq!(result["committed"], true);
    assert_eq!(result["events_deleted"], 20);
    for id in picked {
        assert!(!brain.still_saved(*id), "{id:?} was picked");
    }
    for id in &ids[20..] {
        assert!(brain.still_saved(*id), "{id:?} was not picked");
    }
}

#[test]
fn one_moment_still_goes_by_itself() {
    let brain = Brain::new();
    let ids = brain.seed(2);
    let result = brain
        .delete(&format!(r#"{{"event_id":{}}}"#, ids[0].0))
        .expect("delete");
    assert_eq!(result["events_deleted"], 1);
    assert!(!brain.still_saved(ids[0]));
    assert!(brain.still_saved(ids[1]));
}

#[test]
fn a_moment_already_gone_counts_nothing_and_is_no_error() {
    let brain = Brain::new();
    let ids = brain.seed(2);
    let result = brain
        .delete(&ids_json(&[ids[0], EventId(9_999_999), ids[0]]))
        .expect("delete");
    assert_eq!(result["events_deleted"], 1);
    assert!(brain.still_saved(ids[1]));
}

#[test]
fn a_list_that_is_empty_too_long_or_beside_one_id_is_refused_and_deletes_nothing() {
    let brain = Brain::new();
    let ids = brain.seed(2);
    let too_many = (0..=MAX_DELETE_EVENT_IDS as u64)
        .map(EventId)
        .collect::<Vec<_>>();
    for json in [
        r#"{"event_ids":[]}"#.to_owned(),
        format!(r#"{{"event_id":{},"event_ids":[{}]}}"#, ids[0].0, ids[1].0),
        "{}".to_owned(),
        r#"{"event_ids":[-1]}"#.to_owned(),
        ids_json(&too_many),
    ] {
        let refused = brain.delete(&json);
        assert!(refused.is_err(), "{json:.80}");
        assert!(
            brain.still_saved(ids[0]) && brain.still_saved(ids[1]),
            "{json:.80}"
        );
    }
}

/// While remembering, the agent holds the writer lease: the whole forget is
/// refused before anything is deleted (the window then holds remembering
/// and asks again).
#[test]
fn a_whole_forget_while_the_lease_is_held_deletes_none_of_it() {
    let brain = Brain::new();
    let ids = brain.seed(5);
    let _lease = hold_writer_lease(&brain.path);

    let refused = brain.delete(&ids_json(&ids)).expect_err("blocked");

    assert!(refused.contains("MCI_MUTATION_BLOCKED"), "{refused}");
    for id in &ids {
        assert!(brain.still_saved(*id));
    }
}

/// Timing probe (not run by default): one call for 20 moments against 20
/// calls of one, on a made-up store of a few weeks' size. Run with
/// `cargo test -p mci-brain-ffi --test delete_events_batch -- --ignored --nocapture`;
/// `PROBE_EVENTS` and `PROBE_BYTES` size the store.
#[test]
#[ignore = "timing probe"]
fn twenty_moments_in_one_call_against_twenty_calls() {
    let events: u64 = std::env::var("PROBE_EVENTS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(5_000);
    let bytes: usize = std::env::var("PROBE_BYTES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3_000);
    let brain = Brain::new();
    let ids = {
        let writer = brain.writer();
        let filler = "trailhead pricing rounding invoice seat tier ".repeat(bytes / 46 + 1);
        (0..events)
            .map(|n| {
                let mut event = moment(1_000 + n * 20_000_000, n);
                event.text = format!("{n} {filler}");
                writer.put_event(&event).expect("put")
            })
            .collect::<Vec<_>>()
    };
    let step = (ids.len() / 41).max(1);
    let one_call = ids
        .iter()
        .step_by(step)
        .take(20)
        .copied()
        .collect::<Vec<_>>();
    let one_by_one = ids
        .iter()
        .skip(step / 2)
        .step_by(step)
        .take(20)
        .copied()
        .collect::<Vec<_>>();

    let started = Instant::now();
    brain.delete(&ids_json(&one_call)).expect("one call");
    let batched = started.elapsed();
    let started = Instant::now();
    for id in &one_by_one {
        brain
            .delete(&format!(r#"{{"event_id":{}}}"#, id.0))
            .expect("one of twenty");
    }
    let separate = started.elapsed();
    eprintln!(
        "probe: {events} moments of ~{bytes} B: 20 in one call {:.2}s; 20 calls {:.2}s",
        batched.as_secs_f64(),
        separate.as_secs_f64()
    );
}
