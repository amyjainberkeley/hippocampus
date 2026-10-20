//! The re-clean job's batch (`mci_brain::reclean`) on a synthetic store: it
//! writes only `moment_readings`, resumes where it stopped, never makes a
//! row twice, keeps every stored byte, and everything it wrote goes when its
//! moment is forgotten or expires. Every moment here is made up.

#![allow(clippy::cast_possible_truncation)]

use std::cell::RefCell;
use std::time::{Duration, Instant};

use mci_brain::moment_readings::{CAPTION_BY_TITLE, CAPTION_RULES_SINCE};
use mci_brain::reading::reading;
use mci_brain::reclean::{
    local_day_start, run_batch, BatchLimits, CaptionRequest, Captioner, ModelUnavailable,
};
use mci_brain::{
    BrainStore, Event, EventId, EventSource, RetentionConfig, SqlCipherBrainStore, READING_VERSION,
};
use mci_core::crypto::DbKey;

const DAY_US: u64 = 86_400_000_000;
/// Oct 12, 2026, 09:00 UTC.
const T0: u64 = 1_791_795_600_000_000;

const CHROME: &str = "com.google.Chrome";
const SAFARI: &str = "com.apple.Safari";
const SLACK: &str = "com.tinyspeck.slackmacgap";

fn store() -> (tempfile::TempDir, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = SqlCipherBrainStore::new(
        &dir.path().join("brain.sqlite"),
        &DbKey::from_bytes([9; 32]),
    )
    .unwrap();
    (dir, store)
}

fn put(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    title: &str,
    url: Option<&str>,
    body: &str,
) -> EventId {
    put_from(store, ts_us, app, title, url, body, EventSource::ScreenOcr)
}

fn put_from(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    title: &str,
    url: Option<&str>,
    body: &str,
    source: EventSource,
) -> EventId {
    let text = format!(
        "[app={app} | title={title} | url={} | ts=2026-10-12T09:00:00.000Z]\n{body}",
        url.unwrap_or("?")
    );
    store
        .put_event_with_source(
            &Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some(app.into()),
                window_title: Some(title.into()),
                url: url.map(str::to_owned),
                text,
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
                embedding: None,
            },
            source,
        )
        .unwrap()
}

const TAB_STRIP: &str =
    "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Chan\u{2026}";

/// Twelve moments over two apps and two days: Chrome with the reported tab
/// strip, Safari pages sharing a tab bar, Slack channels sharing a sidebar.
fn seed(store: &SqlCipherBrainStore) -> Vec<EventId> {
    let mut ids = Vec::new();
    let safari_tabs = "Pricing notes    Stripe Docs    Inbox (12)";
    for (n, (title, page)) in [
        (
            "Per-seat or tiered?",
            "Per-seat or tiered?\nMost teams choose between seats and tiers.",
        ),
        (
            "Stripe Docs",
            "Stripe Docs\nCreate a price with a unit amount.",
        ),
        ("Inbox (12)", "Inbox\nDana sent the invoice for phase two."),
    ]
    .iter()
    .enumerate()
    {
        ids.push(put(
            store,
            T0 + n as u64 * 60_000_000,
            SAFARI,
            title,
            None,
            &format!("{safari_tabs}\npricingnotes.example\n{page}"),
        ));
    }
    for (n, (title, message)) in [
        (
            "general (Channel) - Northwind - Slack",
            "Lunch is at noon on Friday.",
        ),
        (
            "design-review (Channel) - Northwind - Slack",
            "Can someone check the copy before 3 PM?",
        ),
        (
            "launch-plan (Channel) - Northwind - Slack",
            "Shipping 0.3 after lunch.",
        ),
    ]
    .iter()
    .enumerate()
    {
        ids.push(put(
            store,
            T0 + 600_000_000 + n as u64 * 60_000_000,
            SLACK,
            title,
            None,
            &format!("# general\n# design-review\n# launch-plan\n{message}"),
        ));
    }
    for n in 0..6u64 {
        ids.push(put(
            store,
            T0 + DAY_US + n * 30_000_000,
            CHROME,
            "How to type accents on a Mac",
            Some("https://support.example/type-accents"),
            &format!(
                "{TAB_STRIP}\n< > C support.example/type-accents \u{2606}\nHow to type accents on a Mac\nChoose an accent from the menu, step {n}."
            ),
        ));
    }
    ids
}

fn limits(moments: usize, captions: usize) -> BatchLimits {
    BatchLimits {
        moments,
        captions,
        deadline: None,
        utc_offset_s: 0,
    }
}

fn snapshot(store: &SqlCipherBrainStore, ids: &[EventId]) -> Vec<Event> {
    ids.iter()
        .map(|id| store.get_event(*id).unwrap().unwrap())
        .collect()
}

#[test]
fn batches_resume_where_they_stopped_and_never_make_a_row_twice() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let mut total = 0;
    let mut batches = 0;
    loop {
        let stats = run_batch(&store, None, limits(5, 0), T0 + 2 * DAY_US).unwrap();
        total += stats.read;
        batches += 1;
        if stats.caught_up {
            break;
        }
        assert!(batches < 10, "{stats:?}");
    }
    assert_eq!(total, ids.len(), "each moment once");
    assert_eq!(batches, 3, "5 + 5 + 2");
    let progress = store.moment_reading_progress(READING_VERSION).unwrap();
    assert_eq!((progress.done, progress.total), (12, 12));
    let rows = store.moment_readings(&ids).unwrap();
    // Another batch, later: nothing is made again.
    let again = run_batch(&store, None, limits(50, 0), T0 + 3 * DAY_US).unwrap();
    assert_eq!(again.read, 0);
    assert!(again.caught_up);
    assert_eq!(store.moment_readings(&ids).unwrap(), rows, "rows untouched");
}

#[test]
fn newest_moments_are_read_first() {
    let (_dir, store) = store();
    let ids = seed(&store);
    run_batch(&store, None, limits(6, 0), T0 + 2 * DAY_US).unwrap();
    let rows = store.moment_readings(&ids).unwrap();
    // The six Chrome moments are the next day's, so they come first.
    for id in &ids[6..] {
        assert!(rows.contains_key(&id.0), "{id:?}");
    }
    for id in &ids[..6] {
        assert!(!rows.contains_key(&id.0), "{id:?}");
    }
}

#[test]
fn the_stored_text_keeps_every_byte_and_search_still_finds_tab_titles() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let before = snapshot(&store, &ids);
    let found_before = store.fts5_search("Trailhead", 50).unwrap();
    while !run_batch(&store, None, limits(4, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    assert_eq!(snapshot(&store, &ids), before, "events byte for byte");
    let found_after = store.fts5_search("Trailhead", 50).unwrap();
    assert_eq!(found_after.len(), 6, "a tab title still finds its moments");
    assert_eq!(
        found_after.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
        found_before.iter().map(|(id, _)| *id).collect::<Vec<_>>()
    );
}

#[test]
fn learned_chrome_is_stored_and_one_frame_chrome_is_left_to_the_live_reading() {
    let (_dir, store) = store();
    let ids = seed(&store);
    while !run_batch(&store, None, limits(20, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    let rows = store.moment_readings(&ids).unwrap();
    // Safari's tab bar is learned from three pages: the cleaned text is kept.
    let safari = rows[&ids[0].0]
        .reading
        .as_ref()
        .expect("learned chrome moved a line");
    assert_eq!(
        safari.main,
        "Per-seat or tiered?\nMost teams choose between seats and tiers."
    );
    assert!(safari
        .rest
        .contains("Pricing notes    Stripe Docs    Inbox (12)"));
    assert!(safari.rest.contains("pricingnotes.example"));
    // Slack's channel list is learned from three channels.
    let slack = rows[&ids[3].0].reading.as_ref().expect("learned");
    assert_eq!(slack.main, "Lunch is at noon on Friday.");
    // Chrome's six moments share one title: nothing is learned, the one-frame
    // rules already set the strip apart, so no text is stored for them.
    for id in &ids[6..] {
        assert_eq!(rows[&id.0].reading, None, "{id:?}");
    }
}

#[test]
fn every_moment_gets_a_caption_from_its_title() {
    let (_dir, store) = store();
    let ids = seed(&store);
    while !run_batch(&store, None, limits(20, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    let rows = store.moment_readings(&ids).unwrap();
    assert_eq!(
        rows[&ids[3].0].caption.as_deref(),
        Some("Chatting in #general")
    );
    assert_eq!(
        rows[&ids[6].0].caption.as_deref(),
        Some("Reading how to type accents on a Mac")
    );
    for row in rows.values() {
        assert_eq!(row.caption_by.as_deref(), Some(CAPTION_BY_TITLE));
        assert!(!row.model_tried);
        assert_eq!(row.version, READING_VERSION);
    }
}

#[test]
fn everything_written_goes_when_its_moment_is_forgotten_or_expires() {
    let (_dir, store) = store();
    let ids = seed(&store);
    while !run_batch(&store, None, limits(20, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    assert_eq!(store.moment_readings(&ids).unwrap().len(), 12);

    // Forget one moment.
    store.delete_event(ids[0]).unwrap();
    assert_eq!(store.moment_reading(ids[0]).unwrap(), None);
    assert!(store.moment_reading(ids[1]).unwrap().is_some());

    // Delete a range: the Slack moments.
    store
        .delete_events_in_range(T0 + 600_000_000, T0 + 900_000_000)
        .unwrap();
    for id in &ids[3..6] {
        assert_eq!(store.moment_reading(*id).unwrap(), None, "{id:?}");
    }

    // Retention: keep one day, an hour before a day has passed since the
    // Chrome moments, so the first day's moments expire and theirs stay.
    mci_brain::retention_purger::purge_once(
        &store,
        &RetentionConfig::Days(1),
        T0 + 2 * DAY_US - 3_600_000_000,
    )
    .unwrap();
    for id in &ids[1..3] {
        assert_eq!(store.moment_reading(*id).unwrap(), None, "expired {id:?}");
    }
    assert_eq!(store.moment_readings(&ids[6..]).unwrap().len(), 6);

    // Wipe everything.
    store.wipe_all().unwrap();
    assert!(store.moment_readings(&ids).unwrap().is_empty());
    let progress = store.moment_reading_progress(READING_VERSION).unwrap();
    assert_eq!((progress.done, progress.total), (0, 0));
}

#[test]
fn a_moment_forgotten_while_a_batch_reads_it_leaves_nothing() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let read = store.stored_moment(ids[0]).unwrap().unwrap();
    let row = mci_brain::MomentReading {
        event_id: ids[0],
        version: READING_VERSION,
        reading: None,
        caption: Some("Reading Stripe Docs".into()),
        caption_by: Some(CAPTION_BY_TITLE.into()),
        model_tried: false,
        updated_us: T0,
    };
    store.delete_event(ids[0]).unwrap();
    assert!(
        !store.put_moment_reading(&row, &read).unwrap(),
        "no row for a gone moment"
    );
    assert_eq!(store.moment_reading(ids[0]).unwrap(), None);
}

#[test]
fn a_reading_never_lands_on_a_capture_that_took_a_deleted_moments_id() {
    let (_dir, store) = store();
    let first = put(
        &store,
        T0,
        SAFARI,
        "Pricing notes",
        None,
        "Pricing notes\nSeats or tiers.",
    );
    put(
        &store,
        T0 + 60_000_000,
        SAFARI,
        "Stripe Docs",
        None,
        "Stripe Docs\nCreate a price.",
    );
    let newest = put(
        &store,
        T0 + 120_000_000,
        SAFARI,
        "Made-up private draft",
        None,
        "A made-up private draft the person later forgets.",
    );
    // A batch reads the newest moment and makes its row…
    let read = store.stored_moment(newest).unwrap().unwrap();
    let row = mci_brain::MomentReading {
        event_id: newest,
        version: READING_VERSION,
        reading: Some(mci_brain::reading::Reading {
            main: "A made-up private draft the person later forgets.".into(),
            rest: String::new(),
        }),
        caption: Some("Reading \u{201c}Made-up private draft\u{201d}".into()),
        caption_by: Some(CAPTION_BY_TITLE.into()),
        model_tried: false,
        updated_us: T0,
    };
    // …the person deletes the last minutes, and a new capture comes in and
    // takes the id the deletion freed…
    store
        .delete_events_in_range(T0 + 100_000_000, T0 + 200_000_000)
        .unwrap();
    let grocery = put(
        &store,
        T0 + 300_000_000,
        SAFARI,
        "Grocery list",
        None,
        "Grocery list\nMilk",
    );
    assert_eq!(grocery, newest, "the id is taken again");
    // …then the batch writes: nothing lands on the new capture.
    assert!(!store.put_moment_reading(&row, &read).unwrap());
    assert_eq!(store.moment_reading(grocery).unwrap(), None);
    assert!(!store
        .set_model_caption(&read, Some(("Reading a private draft", "local:test")), T0)
        .unwrap());
    assert_eq!(store.moment_reading(grocery).unwrap(), None);
    // The new capture is read on its own when its day is over.
    while !run_batch(&store, None, limits(10, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    let row = store.moment_reading(grocery).unwrap().unwrap();
    assert_eq!(
        row.caption.as_deref(),
        Some("Reading \u{201c}Grocery list\u{201d}")
    );
    assert!(store.moment_reading(first).unwrap().is_some());
}

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// A stand-in for the on-device model: answers from a script, counts calls.
struct Scripted {
    answer: fn(&CaptionRequest) -> Option<String>,
    calls: RefCell<Vec<usize>>,
    /// The title of every window it was asked about.
    titles: RefCell<Vec<String>>,
    unavailable: bool,
}

impl Scripted {
    fn new(answer: fn(&CaptionRequest) -> Option<String>) -> Self {
        Self {
            answer,
            calls: RefCell::new(Vec::new()),
            titles: RefCell::new(Vec::new()),
            unavailable: false,
        }
    }
}

impl Captioner for Scripted {
    fn label(&self) -> String {
        "local:test-model".into()
    }

    fn captions(
        &self,
        requests: &[CaptionRequest],
        _within: Option<Duration>,
    ) -> Result<Vec<Option<String>>, ModelUnavailable> {
        if self.unavailable {
            return Err(ModelUnavailable("on_battery".into()));
        }
        self.calls.borrow_mut().push(requests.len());
        self.titles
            .borrow_mut()
            .extend(requests.iter().map(|request| request.title.clone()));
        Ok(requests
            .iter()
            .map(|request| (self.answer)(request))
            .collect())
    }
}

fn grounded_or_invented(request: &CaptionRequest) -> Option<String> {
    if request.title.contains("accents") {
        Some("Choosing an accent from the menu".into())
    } else if request.title.contains("general") {
        // Not on screen: never used.
        Some("Planning a birthday party".into())
    } else if request.title.contains("design-review") {
        // About the person: never used.
        Some("Feeling stressed about the copy".into())
    } else {
        None
    }
}

#[test]
fn a_grounded_model_line_replaces_the_title_caption_and_others_keep_theirs() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let model = Scripted::new(grounded_or_invented);
    for _ in 0..10 {
        if run_batch(&store, Some(&model), limits(20, 20), T0 + 2 * DAY_US)
            .unwrap()
            .caught_up
        {
            break;
        }
    }
    let rows = store.moment_readings(&ids).unwrap();
    let accents = &rows[&ids[6].0];
    assert_eq!(
        accents.caption.as_deref(),
        Some("Choosing an accent from the menu")
    );
    assert_eq!(accents.caption_by.as_deref(), Some("local:test-model"));
    assert!(accents.model_tried);
    let general = &rows[&ids[3].0];
    assert_eq!(
        general.caption.as_deref(),
        Some("Chatting in #general"),
        "invented line not used"
    );
    assert_eq!(general.caption_by.as_deref(), Some(CAPTION_BY_TITLE));
    assert!(general.model_tried, "asked once, not again");
    let review = &rows[&ids[4].0];
    assert_eq!(
        review.caption.as_deref(),
        Some("Chatting in #design-review"),
        "line about the person not used"
    );
    // Asked once each: no moment is offered again.
    let asked: usize = model.calls.borrow().iter().sum();
    let again = run_batch(&store, Some(&model), limits(20, 20), T0 + 3 * DAY_US).unwrap();
    assert!(again.caught_up);
    assert_eq!(model.calls.borrow().iter().sum::<usize>(), asked);
}

#[test]
fn a_models_caption_outlasts_a_change_to_the_readings_rules_alone() {
    // Rows an earlier version made, whose caption rules were the same: one
    // with the model's line, one the model was asked about and gave none,
    // one never asked.
    let (_dir, store) = store();
    let ids = seed(&store);
    const { assert!(READING_VERSION > CAPTION_RULES_SINCE) };
    let row = |id: EventId, caption: &str, by: &str, tried: bool, version: u32| {
        let read = store.stored_moment(id).unwrap().unwrap();
        let row = mci_brain::MomentReading {
            event_id: id,
            version,
            reading: None,
            caption: Some(caption.into()),
            caption_by: Some(by.into()),
            model_tried: tried,
            updated_us: T0,
        };
        assert!(store.put_moment_reading(&row, &read).unwrap());
    };
    row(
        ids[6],
        "Choosing an accent from the menu",
        "local:test-model",
        true,
        CAPTION_RULES_SINCE,
    );
    row(
        ids[3],
        "Chatting in #general",
        CAPTION_BY_TITLE,
        true,
        CAPTION_RULES_SINCE,
    );
    row(
        ids[4],
        "Chatting in #design-review",
        CAPTION_BY_TITLE,
        false,
        CAPTION_RULES_SINCE,
    );
    // A line no longer grounded in the moment as it now reads goes, and the
    // moment is offered again.
    row(
        ids[1],
        "Planning a birthday party",
        "local:test-model",
        true,
        CAPTION_RULES_SINCE,
    );
    // A row from before the caption rules changed keeps nothing.
    row(
        ids[5],
        "An old model line",
        "local:test-model",
        true,
        CAPTION_RULES_SINCE - 1,
    );
    let model = Scripted::new(|_| None);
    for _ in 0..10 {
        if run_batch(&store, Some(&model), limits(20, 20), T0 + 2 * DAY_US)
            .unwrap()
            .caught_up
        {
            break;
        }
    }
    let rows = store.moment_readings(&ids).unwrap();
    let accents = &rows[&ids[6].0];
    assert_eq!(
        accents.version, READING_VERSION,
        "made again by the new rules"
    );
    assert_eq!(
        accents.caption.as_deref(),
        Some("Choosing an accent from the menu"),
        "the model's line carries over"
    );
    assert_eq!(accents.caption_by.as_deref(), Some("local:test-model"));
    assert!(accents.model_tried);
    assert!(rows[&ids[3].0].model_tried, "asked before: not asked again");
    assert_eq!(
        rows[&ids[3].0].caption_by.as_deref(),
        Some(CAPTION_BY_TITLE)
    );
    assert_ne!(
        rows[&ids[5].0].caption.as_deref(),
        Some("An old model line"),
        "made by older caption rules: not kept"
    );
    assert_eq!(
        rows[&ids[1].0].caption_by.as_deref(),
        Some(CAPTION_BY_TITLE),
        "a line not grounded in the moment now is not kept"
    );
    // Offered: the channel never asked, the one asked under older caption
    // rules, the three Safari pages (one whose line no longer held), and the
    // accents window once for its other five moments. Not the channel asked
    // before.
    let titles = model.titles.borrow();
    let offered = |title: &str| titles.iter().filter(|t| t.as_str() == title).count();
    assert_eq!(offered("Stripe Docs"), 1);
    assert_eq!(offered("general (Channel) - Northwind - Slack"), 0);
    assert_eq!(offered("design-review (Channel) - Northwind - Slack"), 1);
    assert_eq!(offered("launch-plan (Channel) - Northwind - Slack"), 1);
    assert_eq!(offered("How to type accents on a Mac"), 1);
    assert_eq!(titles.len(), 6, "{titles:?}");
}

#[test]
fn a_run_of_moments_in_one_window_is_asked_about_once() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let model = Scripted::new(grounded_or_invented);
    run_batch(&store, Some(&model), limits(20, 20), T0 + 2 * DAY_US).unwrap();
    // Six Chrome moments in one window are one request; the three Safari
    // pages and the three Slack channels are one each.
    let requests: usize = model.calls.borrow().iter().sum();
    assert_eq!(requests, 7, "{:?}", model.calls.borrow());
    let rows = store.moment_readings(&ids[6..]).unwrap();
    assert!(rows
        .values()
        .all(|row| row.caption.as_deref() == Some("Choosing an accent from the menu")));
}

#[test]
fn without_the_model_captions_wait_and_are_offered_later() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let mut model = Scripted::new(grounded_or_invented);
    model.unavailable = true;
    let stats = run_batch(&store, Some(&model), limits(20, 20), T0 + 2 * DAY_US).unwrap();
    assert_eq!(stats.model_unavailable.as_deref(), Some("on_battery"));
    assert!(!stats.caught_up, "captions still wait");
    let rows = store.moment_readings(&ids).unwrap();
    assert!(rows.values().all(|row| !row.model_tried));
    model.unavailable = false;
    run_batch(&store, Some(&model), limits(20, 20), T0 + 2 * DAY_US).unwrap();
    let accents = store.moment_reading(ids[6]).unwrap().unwrap();
    assert_eq!(
        accents.caption.as_deref(),
        Some("Choosing an accent from the menu")
    );
}

#[test]
fn surfaces_that_are_not_work_get_no_caption_and_are_not_offered() {
    let (_dir, store) = store();
    let lock = put(
        &store,
        T0,
        "com.apple.loginwindow",
        "Login",
        None,
        "Enter password",
    );
    let model = Scripted::new(|_| Some("Unlocking the Mac".into()));
    run_batch(&store, Some(&model), limits(5, 5), T0 + DAY_US).unwrap();
    let row = store.moment_reading(lock).unwrap().unwrap();
    assert_eq!(row.caption, None);
    assert!(row.model_tried);
    assert!(model.calls.borrow().is_empty());
}

#[test]
fn a_batch_stops_at_its_deadline_and_the_next_one_goes_on() {
    let (_dir, store) = store();
    let ids = seed(&store);
    let past = BatchLimits {
        moments: 20,
        captions: 0,
        deadline: Instant::now().checked_sub(Duration::from_millis(1)),
        utc_offset_s: 0,
    };
    let stats = run_batch(&store, None, past, T0 + 2 * DAY_US).unwrap();
    assert!(stats.deadline_hit);
    assert_eq!(stats.read, 0);
    assert!(store.moment_readings(&ids).unwrap().is_empty());
    let stats = run_batch(&store, None, limits(20, 0), T0 + 2 * DAY_US).unwrap();
    assert_eq!(stats.read, 12);
}

// ---------------------------------------------------------------------------
// What a batch learns never takes what was said
// ---------------------------------------------------------------------------

/// The line `line` is in what the moment's row or live reading shows.
fn shows(store: &SqlCipherBrainStore, id: EventId, line: &str) -> bool {
    let row = store.moment_reading(id).unwrap().expect("row written");
    let shown = row.reading.unwrap_or_else(|| {
        let event = store.get_event(id).unwrap().unwrap();
        reading(
            &event.text,
            EventSource::ScreenOcr,
            event.app_bundle_id.as_deref(),
            event.window_title.as_deref(),
        )
    });
    shown.main.lines().any(|shown| shown.trim() == line)
}

#[test]
#[allow(clippy::too_many_lines)] // one day of made-up windows
fn replies_code_and_table_cells_that_repeat_across_windows_stay() {
    let (_dir, store) = store();
    let mut cases: Vec<(EventId, &str)> = Vec::new();
    let mut sidebars: Vec<(EventId, &str)> = Vec::new();
    let mut ts = T0;
    let mut next = || {
        ts += 60_000_000;
        ts
    };
    // Slack: three channels, the same short replies in each.
    for channel in ["launch", "design", "pricing"] {
        let title = format!("{channel} (Channel) - Northwind - Slack");
        let body = format!(
            "Maya Chen 10:42 AM\nDraft for {channel} is up, can you look?\nJonas Weber 10:44 AM\nthanks!\nlgtm\nSam Lee 10:50 AM\nShipping {channel} after lunch.\nJonas Weber 10:51 AM\nsounds good"
        );
        let id = put(&store, next(), SLACK, &title, None, &body);
        cases.extend([
            (id, "thanks!"),
            (id, "lgtm"),
            (id, "Jonas Weber 10:44 AM"),
            (id, "sounds good"),
        ]);
    }
    // Messages: three conversations with the same replies.
    for who in ["Sam Lee", "Priya Das", "Jordan Lee"] {
        let body = format!(
            "{who}\nAre you coming tonight?\nOn my way!\nok\nSee you soon\nDelivered\niMessage"
        );
        let id = put(&store, next(), "com.apple.MobileSMS", who, None, &body);
        cases.extend([(id, "On my way!"), (id, "ok")]);
    }
    // VS Code: three files share imports and endings.
    for file in ["tax.rs", "ledger.rs", "api.rs"] {
        let title = format!("{file} \u{2014} trailhead");
        let body = format!(
            "use std::collections::HashMap;\nuse serde::Deserialize;\n\npub fn run_{}() -> Result<(), Error> {{\n    let totals = HashMap::new();\n    Ok(())\n}}",
            file.trim_end_matches(".rs")
        );
        let id = put(&store, next(), "com.microsoft.VSCode", &title, None, &body);
        cases.extend([
            (id, "use std::collections::HashMap;"),
            (id, "use serde::Deserialize;"),
            (id, "let totals = HashMap::new();"),
            (id, "Ok(())"),
        ]);
    }
    // A table in a browser: three trackers share cell values.
    for sheet in ["Launch tracker", "Vendor tracker", "Hiring tracker"] {
        let body = format!(
            "{sheet}\nTask Owner Status\nWrite brief\nMaya\nDone\nReview pricing\nSam\nIn progress\nShip it\nPriya\nDone"
        );
        let id = put(&store, next(), CHROME, sheet, None, &body);
        cases.extend([(id, "Done"), (id, "In progress"), (id, "Task Owner Status")]);
    }
    // Notion: three pages with the same property names and one sidebar.
    for page in ["Q4 planning", "Launch checklist", "Roadmap"] {
        let body = format!(
            "Northwind Workspace\nSearch\nUpdates\n{page}\nOwner\nMaya Chen\nStatus\nIn progress\nGoals for {page} are below."
        );
        let id = put(&store, next(), "notion.id", page, None, &body);
        cases.extend([(id, "Owner"), (id, "Maya Chen"), (id, "In progress")]);
        sidebars.push((id, "Northwind Workspace"));
    }
    while !run_batch(&store, None, limits(40, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    for (id, line) in cases {
        assert!(shows(&store, id, line), "{line:?} left event {}", id.0);
    }
    // The workspace's name at the top of every page is its sidebar.
    for (id, line) in sidebars {
        assert!(!shows(&store, id, line), "{line:?} stays in event {}", id.0);
    }
}

#[test]
fn classified_chat_keeps_its_replies() {
    let (_dir, store) = store();
    let mut ids = Vec::new();
    for (n, channel) in ["launch", "design", "pricing"].iter().enumerate() {
        let body = format!(
            "Maya Chen {h}:12 PM\nDraft for {channel} is up, can you look?\nJonas Weber {h}:14 PM\nthanks!\nSam Lee {h}:20 PM\nShipping {channel} after lunch.\n\n\u{1e}\nNorthwind Studio > Q Search Northwind Studio\nThreads\nChannels\nMessage #{channel}",
            h = n + 1
        );
        ids.push(put(
            &store,
            T0 + n as u64 * 600_000_000,
            SLACK,
            &format!("{channel} (Channel) - Northwind - Slack"),
            None,
            &body,
        ));
    }
    while !run_batch(&store, None, limits(40, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    for id in ids {
        assert_eq!(store.moment_reading(id).unwrap().unwrap().reading, None);
        assert!(shows(&store, id, "thanks!"));
    }
}

// ---------------------------------------------------------------------------
// Days, deadlines and what the model is asked
// ---------------------------------------------------------------------------

#[test]
fn todays_moments_wait_until_the_day_is_over() {
    let (_dir, store) = store();
    let id = put(
        &store,
        T0,
        CHROME,
        "Rounding half to even",
        None,
        "Rounding half to even",
    );
    // The same day, an hour later: the day still gains frames.
    let stats = run_batch(&store, None, limits(10, 0), T0 + 3_600_000_000).unwrap();
    assert_eq!(stats.read, 0);
    assert!(stats.caught_up);
    assert_eq!(store.moment_reading(id).unwrap(), None);
    // The next day it is read.
    let stats = run_batch(&store, None, limits(10, 0), T0 + DAY_US).unwrap();
    assert_eq!(stats.read, 1);
}

#[test]
fn a_day_is_the_macs_own_day() {
    // 2026-10-12 23:30 and 2026-10-13 00:30 in Los Angeles (UTC-7) are two
    // days, though both are Oct 13 in UTC.
    let pdt = -7 * 3_600;
    let late = 1_791_873_000_000_000; // 2026-10-13 06:30 UTC
    let early = late + 3_600_000_000; // 2026-10-13 07:30 UTC
    assert_ne!(local_day_start(late, pdt), local_day_start(early, pdt));
    assert_eq!(local_day_start(late, 0), local_day_start(early, 0));
    assert_eq!(local_day_start(early, pdt), 1_791_874_800_000_000); // 07:00 UTC
}

/// A model that takes `took` to answer and keeps the time it was given.
struct Slow {
    took: Duration,
    given: RefCell<Vec<Option<Duration>>>,
}

impl Captioner for Slow {
    fn label(&self) -> String {
        "local:slow".into()
    }

    fn captions(
        &self,
        requests: &[CaptionRequest],
        within: Option<Duration>,
    ) -> Result<Vec<Option<String>>, ModelUnavailable> {
        self.given.borrow_mut().push(within);
        std::thread::sleep(self.took);
        Ok(vec![None; requests.len()])
    }
}

#[test]
fn a_model_request_gets_the_time_left_and_an_overrun_is_said() {
    let (_dir, store) = store();
    seed(&store);
    while !run_batch(&store, None, limits(40, 0), T0 + 2 * DAY_US)
        .unwrap()
        .caught_up
    {}
    let model = Slow {
        took: Duration::from_millis(300),
        given: RefCell::new(Vec::new()),
    };
    let started = Instant::now();
    let stats = run_batch(
        &store,
        Some(&model),
        BatchLimits {
            moments: 40,
            captions: 40,
            deadline: Some(started + Duration::from_millis(100)),
            utc_offset_s: 0,
        },
        T0 + 2 * DAY_US,
    )
    .unwrap();
    let given = model.given.borrow();
    assert_eq!(given.len(), 1, "no request starts after the deadline");
    assert!(given[0].is_some_and(|within| within <= Duration::from_millis(100)));
    assert!(stats.deadline_hit, "{stats:?}");
}

#[test]
fn a_sensitive_moment_or_a_window_beside_is_never_offered_to_the_model() {
    let (_dir, store) = store();
    let health = put(
        &store,
        T0,
        CHROME,
        "HIV test results - MyChart",
        Some("https://mychart.example/results"),
        "MyChart\nHIV test results\nReviewing your results",
    );
    let beside = put_from(
        &store,
        T0 + 60_000_000,
        SLACK,
        "launch (Channel) - Northwind Studio - Slack",
        None,
        "Jordan Lee 2:14 PM\nstaging is green",
        EventSource::ScreenContext,
    );
    let plain = put(
        &store,
        T0 + 120_000_000,
        CHROME,
        "Rounding half to even",
        None,
        "Rounding half to even\nBanks round ties to the even neighbour.",
    );
    let model = Scripted::new(|request| Some(format!("Reading about {}", request.title)));
    while !run_batch(&store, Some(&model), limits(10, 10), T0 + DAY_US)
        .unwrap()
        .caught_up
    {}
    assert_eq!(
        model.calls.borrow().iter().sum::<usize>(),
        1,
        "only the plain page"
    );
    let health_row = store.moment_reading(health).unwrap().unwrap();
    assert!(health_row.model_tried);
    assert_eq!(health_row.caption_by.as_deref(), Some(CAPTION_BY_TITLE));
    let beside_row = store.moment_reading(beside).unwrap().unwrap();
    assert_eq!(
        beside_row.caption.as_deref(),
        Some("#launch, open in Slack")
    );
    assert!(beside_row.model_tried);
    assert!(store.moment_reading(plain).unwrap().unwrap().model_tried);
}
