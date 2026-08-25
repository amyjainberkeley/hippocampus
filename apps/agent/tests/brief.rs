//! Integration tests for `mci-agent brief`.
//!
//! Pins the gap this closes: the daily-brief worker was spawned only from
//! inside the `--drain-stdin` live-capture arm, and capture ships off. On a
//! brain filled any other way the worker never ran, and no command existed
//! that produced a brief at all.
//!
//! Two halves, because no CoreML model exists on a dev machine or in CI:
//!
//! - The generation half drives `brief_worker::generate_brief_once` — the
//!   exact function the `brief` CLI arm calls — with the `StubBriefAuthor`
//!   and `StubLlamaBackend` from `mci_brief`, so the pipeline runs without
//!   a model.
//! - The refusal half spawns the real binary, because "what does the
//!   command do on a machine with no model" is a question about argument
//!   parsing and exit codes, not about generation.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;

use mci_agent::brief_worker::{
    self, generate_brief_once, AuthorFactory, BriefGate, BriefOutcome, BriefWindow,
    BriefWorkerError,
};
use mci_brain::{BrainStore, Event, EventId, EventRecord, SqlCipherBrainStore};
use mci_brief::author::{AuthorError, BriefAuthor, StubBriefAuthor};
use mci_brief::llama_author::LlamaBriefAuthor;
use mci_brief::llama_backend::StubLlamaBackend;
use mci_brief::model::{Brief, BriefId, BriefState};
use mci_core::crypto::DbKey;
use tempfile::TempDir;

// ---------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------

/// An event shaped the way the ingest path shapes them: ADR-0010 §1.3
/// context header, then the body.
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
/// 2026-05-19T00:00:00Z, in microseconds. UTC is the zone every test here
/// uses so the local day and the UTC day are the same thing.
const DAY_START_US: u64 = 1_779_148_800_000_000;
const DAY: &str = "2026-05-19";

/// A working morning: three browser events, then an editor.
fn workday_events() -> Vec<Event> {
    vec![
        event(
            DAY_START_US + 9 * 60 * MIN,
            "com.apple.Safari",
            "https://example.com/pricing",
            "reviewing the pricing page",
        ),
        event(
            DAY_START_US + 9 * 60 * MIN + 4 * MIN,
            "com.apple.Safari",
            "https://example.com/docs",
            "reading the retention documentation",
        ),
        event(
            DAY_START_US + 11 * 60 * MIN,
            "com.microsoft.VSCode",
            "https://github.com/a/b",
            "editing the brief worker module",
        ),
    ]
}

/// The stub author, wrapped the way the CLI wraps the real one.
fn stub_factory() -> AuthorFactory {
    Arc::new(|| Ok(Box::new(StubBriefAuthor) as Box<dyn BriefAuthor>))
}

/// The real `LlamaBriefAuthor` over a canned backend. Exercises prompt
/// rendering, citation parsing and the id filter — everything except the
/// model itself.
fn llama_factory(cited_ids: Vec<u64>) -> AuthorFactory {
    Arc::new(move || {
        let backend = Arc::new(StubLlamaBackend::with_event_ids(cited_ids.clone()));
        Ok(Box::new(LlamaBriefAuthor::new(backend)) as Box<dyn BriefAuthor>)
    })
}

fn whole_day() -> BriefWindow {
    BriefWindow::for_local_date(DAY, 0).expect("valid date")
}

// ---------------------------------------------------------------------
// The path a user takes
// ---------------------------------------------------------------------

#[test]
fn cli_path_writes_a_draft_brief_for_a_brain_capture_never_touched() {
    let (_dir, store) = store_with(workday_events());
    assert_eq!(
        store.brief_count().expect("brief_count"),
        0,
        "a brain filled outside live capture has no briefs, which is the whole problem"
    );

    let outcome = generate_brief_once(&store, &stub_factory(), "Daily brief", &whole_day(), 1)
        .expect("generate");

    let BriefOutcome::Stored {
        date_local,
        event_count,
        word_count,
        id,
        citation_violations,
    } = outcome
    else {
        panic!("a brain with events must produce a brief, got {outcome:?}");
    };
    assert_eq!(date_local, DAY);
    assert_eq!(event_count, 3, "every event in the day feeds the brief");
    assert!(word_count > 0);
    assert!(id > 0);
    assert_eq!(
        citation_violations, 0,
        "the stub cites the events it was handed, so nothing should trip"
    );

    let row = store
        .brief_for_date(DAY)
        .expect("brief_for_date")
        .expect("a row for the day we asked for");
    assert_eq!(row.source_event_count, 3);
    assert!(row.body.contains("pricing page"), "body: {}", row.body);
    assert_eq!(store.brief_count().expect("brief_count"), 1);
}

#[test]
fn the_real_author_runs_end_to_end_over_a_stub_backend() {
    let (_dir, store) = store_with(workday_events());
    let ids: Vec<u64> = store
        .events_since(0, 16)
        .expect("events_since")
        .iter()
        .map(|r| r.event_id.0)
        .collect();

    let outcome = generate_brief_once(
        &store,
        &llama_factory(ids.clone()),
        "Daily brief",
        &whole_day(),
        1,
    )
    .expect("generate");

    let BriefOutcome::Stored {
        citation_violations,
        event_count,
        ..
    } = outcome
    else {
        panic!("expected a stored brief, got {outcome:?}");
    };
    assert_eq!(event_count, 3);

    let row = store.brief_for_date(DAY).unwrap().unwrap();
    for id in &ids {
        assert!(
            row.body.contains(&format!("[event:{id}]")),
            "every real id survives prompt→generate→parse: {}",
            row.body
        );
    }

    // Every citation resolves — the ids are real — and every one is still
    // flagged, because `StubLlamaBackend` returns canned text that ignores
    // the prompt, so its words appear nowhere in the events it cites. The
    // tripwire's ContentMismatch arm is doing exactly its job: a brief
    // whose prose has no relationship to its evidence does not get to be
    // approved. Pinned so a future change to the overlap rule is visible.
    assert_eq!(
        citation_violations, 3,
        "one ContentMismatch per citation from a backend that ignores its prompt"
    );
}

#[test]
fn a_brief_that_cites_nothing_real_is_still_written_but_reported() {
    // The author invents an id the brain has never seen. `LlamaBriefAuthor`
    // drops it (only input ids survive), which leaves a brief with a body
    // and no citations — an OrphanClaim. The draft must still land: a draft
    // is exactly the thing a human reviews. What must not happen is silence.
    let (_dir, store) = store_with(workday_events());

    let outcome = generate_brief_once(
        &store,
        &llama_factory(vec![999_999]),
        "Daily brief",
        &whole_day(),
        1,
    )
    .expect("generate");

    let BriefOutcome::Stored {
        citation_violations,
        ..
    } = outcome
    else {
        panic!("expected a stored brief, got {outcome:?}");
    };
    assert_eq!(
        citation_violations, 1,
        "a body with no surviving citation is one violation"
    );
    assert_eq!(
        store.brief_count().expect("brief_count"),
        1,
        "the draft is written anyway; the tripwire blocks approval, not drafting"
    );
}

#[test]
fn regenerating_a_date_replaces_that_date_rather_than_piling_up() {
    // `put_brief` is INSERT OR REPLACE on UNIQUE(date_local). Running the
    // command twice for the same day is therefore safe and idempotent in
    // the way that matters: one day, one brief.
    let (_dir, store) = store_with(workday_events());

    let first = generate_brief_once(&store, &stub_factory(), "Daily brief", &whole_day(), 1)
        .expect("first");
    let second = generate_brief_once(&store, &stub_factory(), "Daily brief", &whole_day(), 2)
        .expect("second");

    assert_eq!(
        store.brief_count().expect("brief_count"),
        1,
        "a second run must not leave two briefs for one day"
    );

    let (
        BriefOutcome::Stored {
            word_count: w1,
            event_count: e1,
            ..
        },
        BriefOutcome::Stored {
            word_count: w2,
            event_count: e2,
            ..
        },
    ) = (&first, &second)
    else {
        panic!("both runs must store: {first:?} then {second:?}");
    };
    assert_eq!((w1, e1), (w2, e2), "same inputs, same brief");

    let row = store.brief_for_date(DAY).unwrap().unwrap();
    assert_eq!(
        row.generated_ts_us, 2,
        "the row carries the second run's timestamp, so it was replaced, not skipped"
    );
}

#[test]
fn a_dated_window_reads_that_day_and_no_other() {
    let mut events = workday_events();
    // The day before and the day after, close enough to the boundary that a
    // sloppy window would swallow them.
    events.push(event(
        DAY_START_US - MIN,
        "com.apple.Safari",
        "https://example.com/yesterday",
        "yesterday's work",
    ));
    events.push(event(
        DAY_START_US + 24 * 60 * MIN,
        "com.apple.Safari",
        "https://example.com/tomorrow",
        "tomorrow's work",
    ));
    // And one landing exactly on local midnight, which belongs to the day
    // it opens, not the one it closes.
    events.push(event(
        DAY_START_US,
        "com.apple.Safari",
        "https://example.com/midnight",
        "the midnight event",
    ));
    let (_dir, store) = store_with(events);

    let outcome = generate_brief_once(&store, &stub_factory(), "Daily brief", &whole_day(), 1)
        .expect("generate");

    let BriefOutcome::Stored { event_count, .. } = outcome else {
        panic!("expected a stored brief, got {outcome:?}");
    };
    assert_eq!(
        event_count, 4,
        "three workday events plus the midnight one; neither neighbour day"
    );
    let row = store.brief_for_date(DAY).unwrap().unwrap();
    assert!(row.body.contains("midnight event"), "body: {}", row.body);
    assert!(!row.body.contains("yesterday's work"), "body: {}", row.body);
    assert!(!row.body.contains("tomorrow's work"), "body: {}", row.body);
}

#[test]
fn an_empty_window_writes_nothing_and_says_so() {
    let (_dir, store) = store_with(workday_events());
    let empty_day = BriefWindow::for_local_date("2026-05-21", 0).expect("valid date");

    let outcome =
        generate_brief_once(&store, &stub_factory(), "Daily brief", &empty_day, 1).expect("run");

    assert_eq!(outcome, BriefOutcome::SkippedEmpty);
    assert_eq!(
        store.brief_count().expect("brief_count"),
        0,
        "an empty day must not leave an empty brief behind"
    );
}

// ---------------------------------------------------------------------
// ADR-0018 §4.1 — no auto-approve
// ---------------------------------------------------------------------

/// An author that hands back an already-approved brief. Stands in for the
/// mistake ADR-0018 §4.1 is written against.
#[derive(Debug)]
struct AutoApprovingAuthor;

impl BriefAuthor for AutoApprovingAuthor {
    fn author(&self, retrieval: &[EventRecord], topic: &str) -> Result<Brief, AuthorError> {
        let now_us = retrieval.iter().map(|r| r.ts_us).max().unwrap_or(0);
        Ok(Brief {
            id: BriefId(0),
            title: topic.to_owned(),
            body: "approved without anybody reading it".to_owned(),
            citations: retrieval.iter().map(|r| r.event_id).collect(),
            state: BriefState::Approved,
            created_ts_us: now_us,
            updated_ts_us: now_us,
            human_approver_id: Some("the-machine".to_owned()),
        })
    }
}

#[test]
fn the_cli_path_cannot_produce_anything_but_a_draft() {
    let (_dir, store) = store_with(workday_events());
    let factory: AuthorFactory =
        Arc::new(|| Ok(Box::new(AutoApprovingAuthor) as Box<dyn BriefAuthor>));

    let err = generate_brief_once(&store, &factory, "Daily brief", &whole_day(), 1)
        .expect_err("an approved brief must be refused, not stored");

    assert!(
        matches!(err, BriefWorkerError::NotDraft(_)),
        "expected NotDraft, got {err:?}"
    );
    assert_eq!(
        store.brief_count().expect("brief_count"),
        0,
        "nothing may be persisted when the state is wrong"
    );
}

#[test]
fn a_generated_brief_carries_no_approver() {
    // The other half of the invariant: the normal path leaves the approver
    // slot empty. Only `lifecycle::advance` fills it, and only from a human.
    let brief = StubBriefAuthor
        .author(
            &[EventRecord {
                event_id: EventId(1),
                ts_us: DAY_START_US,
                app_bundle_id: Some("com.apple.Safari".into()),
                window_title: None,
                url: None,
                text_snippet: "some work".into(),
            }],
            "Daily brief",
        )
        .expect("author");
    assert_eq!(brief.state, BriefState::Draft);
    assert_eq!(brief.human_approver_id, None);
}

// ---------------------------------------------------------------------
// The refusal path, through the real binary
// ---------------------------------------------------------------------

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

#[test]
fn no_model_exits_non_zero_and_explains_itself() {
    let tmp = TempDir::new().expect("tempdir");
    let model_dir = tmp.path().join("Models");
    std::fs::create_dir_all(&model_dir).expect("mkdir");
    assert_eq!(
        brief_worker::brief_gate(&model_dir, false),
        BriefGate::ModelMissing,
        "fixture must genuinely have no model"
    );

    let out = Command::new(agent_bin())
        .arg("brief")
        .arg("--db-path")
        .arg(tmp.path().join("brain.sqlite"))
        .arg("--model-dir")
        .arg(&model_dir)
        .env("HOME", tmp.path())
        .env("MCI_DB_KEY_HEX", "a".repeat(64))
        .env_remove("MCI_BRIEFS_DISABLED")
        .output()
        .expect("spawn mci-agent");

    assert!(
        !out.status.success(),
        "a command that writes no brief must not exit 0"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Qwen3-1.7B-FP16.mlmodelc"),
        "must name the file it looked for: {stderr}"
    );
    assert!(
        stderr.contains("convert_brief_model.py"),
        "must say how to get one: {stderr}"
    );
    assert!(
        !tmp.path().join("brain.sqlite").exists(),
        "refusing early must not create a brain as a side effect"
    );
}

#[test]
fn the_disable_switch_exits_non_zero_and_names_itself() {
    let tmp = TempDir::new().expect("tempdir");

    let out = Command::new(agent_bin())
        .arg("brief")
        .arg("--db-path")
        .arg(tmp.path().join("brain.sqlite"))
        .arg("--model-dir")
        .arg(tmp.path())
        .env("HOME", tmp.path())
        .env("MCI_DB_KEY_HEX", "a".repeat(64))
        .env("MCI_BRIEFS_DISABLED", "1")
        .output()
        .expect("spawn mci-agent");

    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("MCI_BRIEFS_DISABLED"),
        "must name the variable that is switching it off: {stderr}"
    );
}

#[test]
fn a_date_that_is_not_a_date_is_rejected_before_anything_else() {
    let tmp = TempDir::new().expect("tempdir");

    let out = Command::new(agent_bin())
        .arg("brief")
        .arg("--date")
        .arg("2026-02-30")
        .arg("--db-path")
        .arg(tmp.path().join("brain.sqlite"))
        .arg("--model-dir")
        .arg(tmp.path())
        .env("HOME", tmp.path())
        .env("MCI_DB_KEY_HEX", "a".repeat(64))
        .output()
        .expect("spawn mci-agent");

    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("YYYY-MM-DD"),
        "must say what a date looks like: {stderr}"
    );
}

#[test]
fn help_lists_the_command_that_produces_a_brief() {
    let out = Command::new(agent_bin())
        .arg("--help")
        .output()
        .expect("spawn mci-agent");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("brief"), "help must list it: {stdout}");
    assert!(
        stdout.contains("--date YYYY-MM-DD"),
        "help must document --date: {stdout}"
    );
}
