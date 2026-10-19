//! History shows the screenshot behind every moment that has one.
//!
//! The capture helper keeps a screenshot only when the window in front
//! changes, when the picture changes a lot, or after five quiet minutes
//! (`KeyframePolicy` in the capture helper). Every other moment of that
//! window is read without a new screenshot, because its picture is the one
//! kept a moment earlier. History opens a run of one window as its newest
//! moment, so a hit that names only its own screenshot leaves almost every
//! row without one, although the screenshot is on disk.
//!
//! These tests read a synthetic brain through the C ABI, as the window does.

use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_events_by_ids, mci_brain_ffi_open,
    mci_brain_ffi_recent_events, mci_brain_ffi_search, mci_brain_ffi_string_free, HitJson,
};
use mci_core::crypto::DbKey;
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

const SECOND: u64 = 1_000_000;
const MINUTE: u64 = 60 * SECOND;
/// A fixed morning, so the moments sit in one day.
const T0: u64 = 1_791_820_800_000_000;
const KEY: [u8; 32] = [42; 32];

const CHROME: &str = "com.google.Chrome";
const CODE: &str = "com.microsoft.VSCode";
const SLACK: &str = "com.tinyspeck.slackmacgap";
const TERMINAL: &str = "com.apple.Terminal";
const MAIL: &str = "com.apple.mail";

const ARTICLE: &str = "Rounding half to even \u{00B7} Dev Notes";
const TAX: &str = "tax.rs \u{2014} trailhead-shop";

fn digest(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

struct Brain {
    dir: tempfile::TempDir,
    store: Option<SqlCipherBrainStore>,
}

impl Brain {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store =
            SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &DbKey::from_bytes(KEY))
                .unwrap();
        Self {
            dir,
            store: Some(store),
        }
    }

    fn path(&self) -> PathBuf {
        self.dir.path().join("mci.sqlite")
    }

    fn put(
        &self,
        ts_us: u64,
        app: &str,
        title: &str,
        source: EventSource,
        keyframe: Option<u8>,
    ) -> u64 {
        self.store
            .as_ref()
            .expect("brain still open for writing")
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some(app.into()),
                    window_title: Some(title.into()),
                    url: None,
                    text: format!("{title}\nsynthetic text at {ts_us}"),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: keyframe.map(digest),
                    tab_id: None,
                    embedding: None,
                },
                source,
            )
            .unwrap()
            .0
    }

    fn blob(&self, n: u8) -> String {
        blob_path(self.dir.path(), n)
    }

    /// The brain as it was before sources were recorded: no `event_sources`
    /// table and schema version 8, so every row reads as unattributed.
    fn make_old_schema(&mut self) {
        drop(self.store.take());
        let db = mci_core::store::open(&self.path(), &DbKey::from_bytes(KEY)).unwrap();
        db.conn()
            .execute_batch(
                "DROP TABLE event_sources; UPDATE meta SET value='8' WHERE key='brain_schema_version';",
            )
            .unwrap();
    }

    fn open(&self) -> Reader {
        let path = CString::new(self.path().to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Reader { handle }
    }
}

fn blob_path(dir: &Path, n: u8) -> String {
    PathBuf::from(dir)
        .join("blobs")
        .join(format!("{}.bin", digest(n)))
        .to_string_lossy()
        .into_owned()
}

struct Reader {
    handle: *mut mci_brain_ffi::Handle,
}

impl Reader {
    /// History's own read: one day, newest first.
    fn history(&self) -> HashMap<u64, HitJson> {
        let query = CString::new(
            serde_json::json!({
                "text": "", "mode": "text", "browse": true, "limit": 200,
                "time_from_us": T0, "time_to_us": T0 + 24 * 60 * MINUTE,
            })
            .to_string(),
        )
        .unwrap();
        by_id(read(unsafe {
            mci_brain_ffi_search(self.handle, query.as_ptr())
        }))
    }

    fn recent(&self) -> HashMap<u64, HitJson> {
        by_id(read(unsafe {
            mci_brain_ffi_recent_events(self.handle, 200)
        }))
    }

    fn by_ids(&self, ids: &[u64]) -> HashMap<u64, HitJson> {
        let query = CString::new(serde_json::json!({ "ids": ids }).to_string()).unwrap();
        by_id(read(unsafe {
            mci_brain_ffi_events_by_ids(self.handle, query.as_ptr())
        }))
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn read(raw: *mut c_char) -> Vec<HitJson> {
    assert!(!raw.is_null());
    let hits = serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
    unsafe { mci_brain_ffi_string_free(raw) };
    hits
}

fn by_id(hits: Vec<HitJson>) -> HashMap<u64, HitJson> {
    hits.into_iter().map(|hit| (hit.event_id, hit)).collect()
}

/// A morning as the helper stores it: two windows in front, each with the
/// screenshot kept when it came to the front and moments read after it
/// without one, a page from the browser extension, and windows beside them.
struct Morning {
    brain: Brain,
    article: Vec<u64>,
    article_page: u64,
    tax: Vec<u64>,
    beside: u64,
    tax_after_quiet: u64,
    article_again: u64,
    terminal: u64,
    terminal_beside: u64,
    mail: u64,
}

fn morning() -> Morning {
    let brain = Brain::new();
    let article = vec![
        brain.put(T0, CHROME, ARTICLE, EventSource::ScreenOcr, Some(1)),
        brain.put(
            T0 + 6 * SECOND,
            CHROME,
            ARTICLE,
            EventSource::ScreenOcr,
            None,
        ),
        brain.put(
            T0 + 12 * SECOND,
            CHROME,
            ARTICLE,
            EventSource::BrowserPageWithOcr,
            None,
        ),
    ];
    let article_page = brain.put(
        T0 + 8 * SECOND,
        CHROME,
        ARTICLE,
        EventSource::BrowserPage,
        None,
    );
    let tax = vec![
        brain.put(T0 + 20 * SECOND, CODE, TAX, EventSource::ScreenOcr, Some(2)),
        brain.put(T0 + 26 * SECOND, CODE, TAX, EventSource::ScreenOcr, None),
        brain.put(T0 + 4 * MINUTE, CODE, TAX, EventSource::ScreenOcr, None),
    ];
    // A chat beside the editor: only its text is kept.
    let beside = brain.put(
        T0 + 28 * SECOND,
        SLACK,
        "#launch",
        EventSource::ScreenContext,
        None,
    );
    // Past the five quiet minutes the helper keeps a new screenshot; a moment
    // without one is not shown with a picture older than that.
    let tax_after_quiet = brain.put(
        T0 + 20 * SECOND + 6 * MINUTE,
        CODE,
        TAX,
        EventSource::ScreenOcr,
        None,
    );
    // Back in the browser, but no screenshot was kept on the way back: the
    // newest screenshot is the editor's, so this moment has none.
    let article_again = brain.put(
        T0 + 7 * MINUTE,
        CHROME,
        ARTICLE,
        EventSource::ScreenOcr,
        None,
    );
    // Two windows with one name: the one in front kept a screenshot, the
    // one beside it is text only and never borrows its neighbour's picture.
    let terminal = brain.put(
        T0 + 10 * MINUTE,
        TERMINAL,
        "zsh",
        EventSource::ScreenOcr,
        Some(3),
    );
    let terminal_beside = brain.put(
        T0 + 10 * MINUTE + 5 * SECOND,
        TERMINAL,
        "zsh",
        EventSource::ScreenContext,
        None,
    );
    // A message read from Mail's files is not a moment on screen.
    brain.put(
        T0 + 12 * MINUTE,
        MAIL,
        "Invoice",
        EventSource::ScreenOcr,
        Some(4),
    );
    let mail = brain.put(
        T0 + 12 * MINUTE + 5 * SECOND,
        MAIL,
        "Invoice",
        EventSource::StructuredApp,
        None,
    );
    Morning {
        brain,
        article,
        article_page,
        tax,
        beside,
        tax_after_quiet,
        article_again,
        terminal,
        terminal_beside,
        mail,
    }
}

/// `id` shows the screenshot at `blob`, taken at `taken_us`.
fn assert_shows(hits: &HashMap<u64, HitJson>, id: u64, blob: &str, taken_us: u64) {
    let hit = hits
        .get(&id)
        .unwrap_or_else(|| panic!("moment {id} missing"));
    assert_eq!(
        hit.thumbnail_path.as_deref(),
        Some(blob),
        "moment {id} ({:?}) should show its window's screenshot",
        hit.window_title
    );
    assert_eq!(
        hit.thumbnail_ts_us,
        Some(taken_us),
        "moment {id} should say when its screenshot was taken"
    );
}

fn assert_text_only(hits: &HashMap<u64, HitJson>, id: u64) {
    let hit = hits
        .get(&id)
        .unwrap_or_else(|| panic!("moment {id} missing"));
    assert_eq!(
        hit.thumbnail_path, None,
        "moment {id} ({:?}) has no screenshot",
        hit.window_title
    );
    assert_eq!(hit.thumbnail_ts_us, None);
}

fn assert_morning(m: &Morning, hits: &HashMap<u64, HitJson>) {
    let article = m.brain.blob(1);
    let tax = m.brain.blob(2);
    for id in &m.article {
        assert_shows(hits, *id, &article, T0);
    }
    assert_shows(hits, m.article_page, &article, T0);
    for id in &m.tax {
        assert_shows(hits, *id, &tax, T0 + 20 * SECOND);
    }
    assert_shows(hits, m.terminal, &m.brain.blob(3), T0 + 10 * MINUTE);
    assert_text_only(hits, m.beside);
    assert_text_only(hits, m.tax_after_quiet);
    assert_text_only(hits, m.article_again);
    assert_text_only(hits, m.terminal_beside);
    assert_text_only(hits, m.mail);
}

#[test]
fn history_rows_show_the_screenshot_their_window_kept() {
    let m = morning();
    let hits = m.brain.open().history();
    assert_eq!(hits.len(), 14);
    assert_morning(&m, &hits);
}

#[test]
fn recent_and_linked_moments_show_the_same_screenshot() {
    let m = morning();
    let reader = m.brain.open();
    assert_morning(&m, &reader.recent());
    let ids: Vec<u64> = m
        .article
        .iter()
        .chain(&m.tax)
        .copied()
        .chain([m.article_page, m.beside, m.tax_after_quiet, m.article_again])
        .chain([m.terminal, m.terminal_beside, m.mail])
        .collect();
    let linked = reader.by_ids(&ids);
    for id in &m.tax {
        assert_shows(&linked, *id, &m.brain.blob(2), T0 + 20 * SECOND);
    }
    for id in &m.article {
        assert_shows(&linked, *id, &m.brain.blob(1), T0);
    }
    assert_text_only(&linked, m.beside);
    assert_text_only(&linked, m.article_again);
    assert_text_only(&linked, m.mail);
}

/// Memories saved before sources were recorded read as unattributed. Their
/// screenshots are found the same way: their own, or the one their window
/// kept a moment earlier.
#[test]
fn older_memories_show_their_windows_screenshot_too() {
    let mut brain = Brain::new();
    let article = [
        brain.put(T0, CHROME, ARTICLE, EventSource::ScreenOcr, Some(1)),
        brain.put(
            T0 + 6 * SECOND,
            CHROME,
            ARTICLE,
            EventSource::ScreenOcr,
            None,
        ),
        brain.put(
            T0 + 9 * SECOND,
            CHROME,
            ARTICLE,
            EventSource::BrowserPage,
            None,
        ),
    ];
    let tax = [
        brain.put(T0 + 20 * SECOND, CODE, TAX, EventSource::ScreenOcr, Some(2)),
        brain.put(T0 + 2 * MINUTE, CODE, TAX, EventSource::ScreenOcr, None),
    ];
    let article_again = brain.put(
        T0 + 3 * MINUTE,
        CHROME,
        ARTICLE,
        EventSource::ScreenOcr,
        None,
    );
    let tax_after_quiet = brain.put(
        T0 + 20 * SECOND + 6 * MINUTE,
        CODE,
        TAX,
        EventSource::ScreenOcr,
        None,
    );
    brain.make_old_schema();

    let reader = brain.open();
    for hits in [reader.history(), reader.recent()] {
        assert_eq!(hits.len(), 7);
        assert!(hits.values().all(|hit| hit.source_kind == "unknown"));
        for id in article {
            assert_shows(&hits, id, &brain.blob(1), T0);
        }
        for id in tax {
            assert_shows(&hits, id, &brain.blob(2), T0 + 20 * SECOND);
        }
        assert_text_only(&hits, article_again);
        assert_text_only(&hits, tax_after_quiet);
    }
    let linked = reader.by_ids(&[tax[1], article[1], article_again]);
    assert_shows(&linked, tax[1], &brain.blob(2), T0 + 20 * SECOND);
    assert_shows(&linked, article[1], &brain.blob(1), T0);
    assert_text_only(&linked, article_again);
}
