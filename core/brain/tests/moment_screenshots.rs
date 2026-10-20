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

// Pictures of the windows beside the front one (SPEC 6.4): a side picture
// is kept on a side window's own moment, and borrowing keeps the two kinds
// apart. Front-window moments borrow only front-window screenshots; a side
// moment shows its own picture, or the newest side picture of the same
// window at most five minutes older, and never a front-window screenshot.

const SLACK: &str = "com.tinyspeck.slackmacgap";
const LAUNCH: &str = "launch (Channel) - Northwind Studio - Slack";

/// What every moment in `ids` shows, in order.
fn shown_all(brain: &Brain, ids: &[EventId]) -> Vec<Option<(EventId, u64, String)>> {
    ids.iter().map(|id| brain.shown(*id)).collect()
}

#[test]
fn a_side_picture_never_changes_which_screenshot_a_front_moment_shows() {
    // A front-window afternoon: the article kept a screenshot, then the
    // editor, then the article again without one (the window changed).
    let front = Brain::new();
    let side = Brain::new();
    let timeline: Vec<(Row<'_>, EventSource)> = vec![
        (
            Row::new(T0, CHROME, ARTICLE).kept(1),
            EventSource::ScreenOcr,
        ),
        (
            Row::new(T0 + 20 * SECOND, CHROME, ARTICLE),
            EventSource::ScreenOcr,
        ),
        (
            Row::new(T0 + 40 * SECOND, CHROME, ARTICLE),
            EventSource::BrowserPageWithOcr,
        ),
        (
            Row::new(T0 + 60 * SECOND, CODE, TAX).kept(2),
            EventSource::ScreenOcr,
        ),
        (
            Row::new(T0 + 90 * SECOND, CODE, TAX),
            EventSource::ScreenOcr,
        ),
        (
            Row::new(T0 + 2 * MINUTE, CHROME, ARTICLE),
            EventSource::ScreenOcr,
        ),
        (Row::new(T0 + 3 * MINUTE, CODE, TAX), EventSource::ScreenOcr),
        (Row::new(T0 + 9 * MINUTE, CODE, TAX), EventSource::ScreenOcr),
    ];
    let mut front_ids = Vec::new();
    let mut side_ids = Vec::new();
    for (row, source) in &timeline {
        front_ids.push(front.put(row, *source));
    }
    // The same afternoon with pictures of the windows beside it kept in
    // between, one of them of the very window that is in front elsewhere.
    let beside: Vec<Row<'_>> = vec![
        Row::new(T0 + 10 * SECOND, SLACK, LAUNCH).kept(11),
        Row::new(T0 + 30 * SECOND, CODE, TAX).kept(12),
        Row::new(T0 + 50 * SECOND, CHROME, ARTICLE).kept(13),
        Row::new(T0 + 80 * SECOND, SLACK, LAUNCH).kept(14),
        Row::new(T0 + 100 * SECOND, CHROME, ARTICLE).kept(15),
        Row::new(T0 + 150 * SECOND, CODE, TAX).kept(16),
        Row::new(T0 + 4 * MINUTE, SLACK, LAUNCH),
    ];
    let mut merged: Vec<(&Row<'_>, EventSource, bool)> = timeline
        .iter()
        .map(|(row, source)| (row, *source, true))
        .chain(
            beside
                .iter()
                .map(|row| (row, EventSource::ScreenContext, false)),
        )
        .collect();
    merged.sort_by_key(|(row, _, _)| row.ts_us);
    for (row, source, is_front) in merged {
        let id = side.put(row, source);
        if is_front {
            side_ids.push(id);
        }
    }

    let before = shown_all(&front, &front_ids);
    let after = shown_all(&side, &side_ids);
    // The ids differ between the two stores; what each moment shows does not.
    let strip = |shown: Vec<Option<(EventId, u64, String)>>| {
        shown
            .into_iter()
            .map(|shot| shot.map(|(_, ts, digest)| (ts, digest)))
            .collect::<Vec<_>>()
    };
    assert_eq!(strip(before.clone()), strip(after));
    // And the afternoon itself reads as it always did.
    assert_eq!(
        strip(before),
        vec![
            Some((T0, digest(1))),
            Some((T0, digest(1))),
            Some((T0, digest(1))),
            Some((T0 + 60 * SECOND, digest(2))),
            Some((T0 + 60 * SECOND, digest(2))),
            None,
            Some((T0 + 60 * SECOND, digest(2))),
            None,
        ]
    );
}

#[test]
fn a_side_moment_that_kept_a_picture_shows_its_own() {
    let brain = Brain::new();
    let id = brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(21),
        EventSource::ScreenContext,
    );
    assert_eq!(brain.shown(id), Some((id, T0, digest(21))));
}

#[test]
fn a_side_moment_shows_the_newest_side_picture_of_its_window_up_to_five_minutes_older() {
    let brain = Brain::new();
    brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(21),
        EventSource::ScreenContext,
    );
    let newer = brain.put(
        &Row::new(T0 + MINUTE, SLACK, LAUNCH).kept(22),
        EventSource::ScreenContext,
    );
    // Another window's picture in between changes nothing for this one.
    brain.put(
        &Row::new(T0 + 90 * SECOND, CODE, TAX).kept(23),
        EventSource::ScreenContext,
    );
    let later = brain.put(
        &Row::new(T0 + 2 * MINUTE, SLACK, LAUNCH),
        EventSource::ScreenContext,
    );
    let edge = brain.put(
        &Row::new(
            T0 + MINUTE + SqlCipherBrainStore::SCREENSHOT_REUSE_US,
            SLACK,
            LAUNCH,
        ),
        EventSource::ScreenContext,
    );
    let past = brain.put(
        &Row::new(
            T0 + MINUTE + SqlCipherBrainStore::SCREENSHOT_REUSE_US + 1,
            SLACK,
            LAUNCH,
        ),
        EventSource::ScreenContext,
    );
    assert_eq!(brain.shown(later), Some((newer, T0 + MINUTE, digest(22))));
    assert_eq!(brain.shown(edge), Some((newer, T0 + MINUTE, digest(22))));
    assert_eq!(brain.shown(past), None);
}

#[test]
fn a_side_moment_never_borrows_a_front_window_screenshot() {
    let brain = Brain::new();
    // The window was in front a moment ago and kept a screenshot there.
    brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(31),
        EventSource::ScreenOcr,
    );
    let beside = brain.put(
        &Row::new(T0 + 30 * SECOND, SLACK, LAUNCH),
        EventSource::ScreenContext,
    );
    assert_eq!(brain.shown(beside), None);
    // A front moment never borrows the side picture of its own window either.
    brain.put(
        &Row::new(T0 + MINUTE, CHROME, ARTICLE).kept(32),
        EventSource::ScreenContext,
    );
    let in_front = brain.put(
        &Row::new(T0 + 70 * SECOND, CHROME, ARTICLE),
        EventSource::ScreenOcr,
    );
    assert_eq!(brain.shown(in_front), None);
}

#[test]
fn a_side_moment_never_borrows_another_windows_picture() {
    let brain = Brain::new();
    brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(41),
        EventSource::ScreenContext,
    );
    brain.put(
        &Row::new(T0, CHROME, "New Tab")
            .url("https://a.example/")
            .kept(42),
        EventSource::ScreenContext,
    );
    let other_title = brain.put(
        &Row::new(
            T0 + SECOND,
            SLACK,
            "general (Channel) - Northwind Studio - Slack",
        ),
        EventSource::ScreenContext,
    );
    let other_app = brain.put(
        &Row::new(T0 + 2 * SECOND, CODE, LAUNCH),
        EventSource::ScreenContext,
    );
    let other_page = brain.put(
        &Row::new(T0 + 3 * SECOND, CHROME, "New Tab").url("https://b.example/"),
        EventSource::ScreenContext,
    );
    let before = brain.put(
        &Row::new(T0 - SECOND, SLACK, LAUNCH),
        EventSource::ScreenContext,
    );
    assert_eq!(brain.shown(other_title), None);
    assert_eq!(brain.shown(other_app), None);
    assert_eq!(brain.shown(other_page), None);
    assert_eq!(brain.shown(before), None);
}

#[test]
fn a_malformed_side_picture_is_never_shown() {
    let brain = Brain::new();
    brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(51),
        EventSource::ScreenContext,
    );
    let mut bad = Row::new(T0 + SECOND, SLACK, LAUNCH);
    bad.keyframe = Some("not-a-digest".into());
    brain.put(&bad, EventSource::ScreenContext);
    let after = brain.put(
        &Row::new(T0 + 2 * SECOND, SLACK, LAUNCH),
        EventSource::ScreenContext,
    );
    // The window's newest picture cannot be opened; the older one is
    // another picture of it, so the moment shows none.
    assert_eq!(brain.shown(after), None);
}

#[test]
fn deleting_the_side_moment_that_kept_a_picture_takes_it_from_its_window() {
    let brain = Brain::new();
    let kept = brain.put(
        &Row::new(T0, SLACK, LAUNCH).kept(61),
        EventSource::ScreenContext,
    );
    let later = brain.put(
        &Row::new(T0 + 30 * SECOND, SLACK, LAUNCH),
        EventSource::ScreenContext,
    );
    assert_eq!(brain.shown(later), Some((kept, T0, digest(61))));
    brain.store.delete_event(kept).unwrap();
    assert_eq!(brain.shown(later), None);
}
