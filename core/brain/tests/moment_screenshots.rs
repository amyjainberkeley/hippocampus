//! Which stored screenshot shows a moment.
//!
//! The capture helper keeps a screenshot only when the window in front
//! changes, when its picture changes a lot, or after five quiet minutes
//! (`KeyframePolicy`). The window's other moments are read without one
//! because they look like the screenshot kept a moment earlier, so that
//! screenshot is theirs too. Everything here is synthetic.

use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const SECOND: u64 = 1_000_000;
const MINUTE: u64 = 60 * SECOND;
const T0: u64 = 1_791_820_800_000_000;

const CHROME: &str = "com.google.Chrome";
const CODE: &str = "com.microsoft.VSCode";
const ARTICLE: &str = "Rounding half to even \u{00B7} Dev Notes";
const TAX: &str = "tax.rs \u{2014} trailhead-shop";

fn digest(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

struct Row<'a> {
    ts_us: u64,
    app: &'a str,
    title: Option<&'a str>,
    url: Option<&'a str>,
    keyframe: Option<String>,
}

impl<'a> Row<'a> {
    fn new(ts_us: u64, app: &'a str, title: &'a str) -> Self {
        Self {
            ts_us,
            app,
            title: Some(title),
            url: None,
            keyframe: None,
        }
    }

    fn kept(mut self, n: u8) -> Self {
        self.keyframe = Some(digest(n));
        self
    }

    fn url(mut self, url: &'a str) -> Self {
        self.url = Some(url);
        self
    }

    fn event(&self) -> Event {
        Event {
            id: EventId(0),
            ts_us: self.ts_us,
            app_bundle_id: Some(self.app.into()),
            window_title: self.title.map(Into::into),
            url: self.url.map(Into::into),
            text: format!("synthetic text at {}", self.ts_us),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: self.keyframe.clone(),
            tab_id: None,
            embedding: None,
        }
    }
}

struct Brain {
    _dir: tempfile::TempDir,
    path: std::path::PathBuf,
    key: DbKey,
    store: SqlCipherBrainStore,
}

impl Brain {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mci.sqlite");
        let key = DbKey::from_bytes([7; 32]);
        let store = SqlCipherBrainStore::new(&path, &key).unwrap();
        Self {
            _dir: dir,
            path,
            key,
            store,
        }
    }

    fn put(&self, row: &Row<'_>, source: EventSource) -> EventId {
        self.store
            .put_event_with_source(&row.event(), source)
            .unwrap()
    }

    /// The screenshot a stored moment shows, read the way the window reads it.
    fn shown(&self, id: EventId) -> Option<(EventId, u64, String)> {
        let event = self.store.get_event(id).unwrap().unwrap();
        let source = self.store.event_source(id).unwrap();
        self.store
            .screenshot_for_event(&event, source)
            .unwrap()
            .map(|shot| (shot.event_id, shot.ts_us, shot.digest))
    }
}

#[test]
fn a_moment_that_kept_a_screenshot_shows_its_own() {
    let brain = Brain::new();
    let id = brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(id), Some((id, T0, digest(1))));

    // A stored digest with stray whitespace is still the same file name.
    let mut padded = Row::new(T0 + SECOND, CODE, TAX);
    padded.keyframe = Some(format!("  {}\n", digest(2)));
    let padded = brain.put(&padded, EventSource::ScreenOcr);
    assert_eq!(brain.shown(padded), Some((padded, T0 + SECOND, digest(2))));
}

#[test]
fn later_moments_of_the_window_show_the_screenshot_it_kept() {
    let brain = Brain::new();
    let kept = brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    for (offset, source) in [
        (6 * SECOND, EventSource::ScreenOcr),
        (8 * SECOND, EventSource::BrowserPage),
        (12 * SECOND, EventSource::BrowserPageWithOcr),
        (5 * MINUTE, EventSource::ScreenOcr),
    ] {
        let id = brain.put(&Row::new(T0 + offset, CHROME, ARTICLE), source);
        assert_eq!(
            brain.shown(id),
            Some((kept, T0, digest(1))),
            "{source:?} moment {offset}us after the screenshot"
        );
    }
}

#[test]
fn a_screenshot_is_never_shown_for_a_moment_before_it() {
    let brain = Brain::new();
    let before = brain.put(&Row::new(T0, CHROME, ARTICLE), EventSource::ScreenOcr);
    brain.put(
        &Row::new(T0 + SECOND, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(before), None);
}

#[test]
fn a_newer_screenshot_of_another_window_means_the_window_changed() {
    let brain = Brain::new();
    brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    let editor = brain.put(
        &Row::new(T0 + 10 * SECOND, CODE, TAX).kept(2),
        EventSource::ScreenOcr,
    );
    // Back in the browser, but no screenshot was kept on the way back.
    let back = brain.put(
        &Row::new(T0 + 20 * SECOND, CHROME, ARTICLE),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(back), None);
    let typing = brain.put(
        &Row::new(T0 + 30 * SECOND, CODE, TAX),
        EventSource::ScreenOcr,
    );
    assert_eq!(
        brain.shown(typing),
        Some((editor, T0 + 10 * SECOND, digest(2)))
    );
}

#[test]
fn screenshots_older_than_five_quiet_minutes_are_not_reused() {
    let brain = Brain::new();
    let kept = brain.put(&Row::new(T0, CODE, TAX).kept(2), EventSource::ScreenOcr);
    let edge = brain.put(
        &Row::new(T0 + SqlCipherBrainStore::SCREENSHOT_REUSE_US, CODE, TAX),
        EventSource::ScreenOcr,
    );
    let past = brain.put(
        &Row::new(T0 + SqlCipherBrainStore::SCREENSHOT_REUSE_US + 1, CODE, TAX),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(edge), Some((kept, T0, digest(2))));
    assert_eq!(brain.shown(past), None);
}

#[test]
fn windows_beside_the_front_one_imports_and_messages_never_borrow_a_screenshot() {
    let brain = Brain::new();
    brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    for source in [
        EventSource::ScreenContext,
        EventSource::StructuredApp,
        EventSource::TranscriptImport,
        EventSource::McpResource,
    ] {
        let id = brain.put(&Row::new(T0 + SECOND, CHROME, ARTICLE), source);
        assert_eq!(
            brain.shown(id),
            None,
            "{source:?} must not show the front window"
        );
    }
}

#[test]
fn another_page_under_the_same_title_is_not_the_same_screen() {
    let brain = Brain::new();
    let kept = brain.put(
        &Row::new(T0, CHROME, "New Tab")
            .url("https://a.example/")
            .kept(1),
        EventSource::BrowserPageWithOcr,
    );
    let other = brain.put(
        &Row::new(T0 + SECOND, CHROME, "New Tab").url("https://b.example/"),
        EventSource::BrowserPage,
    );
    let same = brain.put(
        &Row::new(T0 + 2 * SECOND, CHROME, "New Tab").url("https://a.example/"),
        EventSource::BrowserPage,
    );
    // The screen text names no page: the title and the time decide.
    let unnamed = brain.put(
        &Row::new(T0 + 3 * SECOND, CHROME, "New Tab"),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(other), None);
    assert_eq!(brain.shown(same), Some((kept, T0, digest(1))));
    assert_eq!(brain.shown(unnamed), Some((kept, T0, digest(1))));
}

#[test]
fn untitled_windows_and_other_apps_never_share() {
    let brain = Brain::new();
    let mut untitled = Row::new(T0, CODE, "");
    untitled.keyframe = Some(digest(3));
    brain.put(&untitled, EventSource::ScreenOcr);
    let mut after = Row::new(T0 + SECOND, CODE, "");
    after.title = None;
    let after = brain.put(&after, EventSource::ScreenOcr);
    assert_eq!(brain.shown(after), None);

    brain.put(
        &Row::new(T0 + 2 * SECOND, CODE, TAX).kept(4),
        EventSource::ScreenOcr,
    );
    let other_app = brain.put(
        &Row::new(T0 + 3 * SECOND, CHROME, TAX),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(other_app), None);
}

#[test]
fn a_malformed_stored_digest_is_never_shown() {
    let brain = Brain::new();
    brain.put(&Row::new(T0, CODE, TAX).kept(2), EventSource::ScreenOcr);
    let mut bad = Row::new(T0 + SECOND, CODE, TAX);
    bad.keyframe = Some(digest(0xAB).to_uppercase());
    let bad = brain.put(&bad, EventSource::ScreenOcr);
    let after = brain.put(
        &Row::new(T0 + 2 * SECOND, CODE, TAX),
        EventSource::ScreenOcr,
    );
    // The newest screenshot cannot be opened: the older one is another
    // picture of the window, so neither moment shows one.
    assert_eq!(brain.shown(bad), None);
    assert_eq!(brain.shown(after), None);
}

#[test]
fn rows_from_before_sources_were_recorded_follow_the_same_rule() {
    let brain = Brain::new();
    let kept = brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    let later = brain.put(
        &Row::new(T0 + 6 * SECOND, CHROME, ARTICLE),
        EventSource::ScreenOcr,
    );
    let other = brain.put(
        &Row::new(T0 + 7 * SECOND, CODE, TAX),
        EventSource::ScreenOcr,
    );
    let Brain {
        _dir,
        path,
        key,
        store,
    } = brain;
    drop(store);
    // The schema as it was before sources were recorded.
    let db = mci_core::store::open(&path, &key).unwrap();
    db.conn()
        .execute_batch(
            "DROP TABLE event_sources; UPDATE meta SET value='8' WHERE key='brain_schema_version';",
        )
        .unwrap();
    drop(db);
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    let shown = |id: EventId| {
        let event = reader.get_event(id).unwrap().unwrap();
        let source = reader.event_source(id).unwrap();
        assert_eq!(source, EventSource::Unknown);
        reader
            .screenshot_for_event(&event, source)
            .unwrap()
            .map(|shot| (shot.event_id, shot.ts_us, shot.digest))
    };
    assert_eq!(shown(kept), Some((kept, T0, digest(1))));
    assert_eq!(shown(later), Some((kept, T0, digest(1))));
    assert_eq!(shown(other), None);
}

#[test]
fn deleting_the_moment_that_kept_a_screenshot_takes_it_from_its_window() {
    let brain = Brain::new();
    let kept = brain.put(
        &Row::new(T0, CHROME, ARTICLE).kept(1),
        EventSource::ScreenOcr,
    );
    let later = brain.put(
        &Row::new(T0 + 6 * SECOND, CHROME, ARTICLE),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(later), Some((kept, T0, digest(1))));
    brain.store.delete_events_in_range(T0, T0).unwrap();
    assert_eq!(brain.shown(later), None);
}
