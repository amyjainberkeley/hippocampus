use std::collections::HashSet;

use mci_brain::understanding::{
    DayReport, EventHead, InteractionCounts, NewProposition, PropositionKind, PropositionStatus, SessionNote,
};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn event(ts_us: u64, text: &str, url: Option<&str>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.google.Chrome".into()),
        window_title: Some("Window".into()),
        url: url.map(str::to_owned),
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

fn store() -> (tempfile::TempDir, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &DbKey::from_bytes([7; 32])).unwrap();
    (dir, store)
}

fn prop(text: &str, confidence: f64) -> NewProposition {
    NewProposition {
        text: text.into(),
        reasoning: "Seen in the observations.".into(),
        kind: PropositionKind::Project,
        confidence,
        decay: 0.3,
        model: "test".into(),
    }
}

/// A stored event's id, as propositions cite it.
fn put(store: &SqlCipherBrainStore, ts_us: u64, text: &str) -> i64 {
    store.put_event_with_source(&event(ts_us, text, None), EventSource::ScreenOcr).unwrap().0 as i64
}

/// A managed keyframe blob digest: 64 lowercase hex characters.
fn digest(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

fn ids_with_status(store: &SqlCipherBrainStore, status: PropositionStatus) -> Vec<i64> {
    store.propositions_with_status(status, 50).unwrap().into_iter().map(|p| p.id).collect()
}

fn head_ids(heads: &[EventHead]) -> Vec<i64> {
    heads.iter().map(|h| h.id).collect()
}

#[test]
fn searches_are_read_from_urls_and_listed_without_repeats() {
    let (_dir, store) = store();
    let url = "https://www.google.com/search?q=team+plan+pricing";
    let a = store.put_event_with_source(&event(1_000_000, "results", Some(url)), EventSource::BrowserPage).unwrap();
    let b = store.put_event_with_source(&event(2_000_000, "results again", Some(url)), EventSource::ScreenOcr).unwrap();
    store.put_event_with_source(&event(3_000_000, "docs", Some("https://stripe.com/docs")), EventSource::BrowserPage).unwrap();
    let (added, last) = store.backfill_search_queries(0, 100).unwrap();
    assert_eq!(added, 2);
    assert_eq!(store.backfill_search_queries(last, 100).unwrap(), (0, last), "the cursor moves past what was read");
    assert_eq!(store.backfill_search_queries(0, 100).unwrap().0, 2, "re-reading is harmless");
    let searches = store.search_queries_in_range(0, 10_000_000, 10).unwrap();
    assert_eq!(searches.len(), 1, "the same query a second later collapses");
    assert_eq!(searches[0].query, "team plan pricing");
    assert_eq!(searches[0].engine, "google");
    assert_eq!(searches[0].event_id, a.0 as i64);
    store.delete_event(a).unwrap();
    let left = store.search_queries_in_range(0, 10_000_000, 10).unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].event_id, b.0 as i64, "a search goes with its event");
}

#[test]
fn propositions_revise_search_and_vanish_with_any_evidence() {
    let (_dir, store) = store();
    let e1 = store.put_event_with_source(&event(1, "Launch plan: beta ships Oct 21", None), EventSource::ScreenOcr).unwrap();
    let e2 = store.put_event_with_source(&event(2, "Pricing chat: $18 a seat", None), EventSource::ScreenOcr).unwrap();
    let e3 = store.put_event_with_source(&event(3, "Unrelated", None), EventSource::ScreenOcr).unwrap();

    let first = store.insert_proposition(&prop("The user is preparing a beta launch", 0.6), &[e1.0 as i64], 10).unwrap();
    let revised = store
        .revise_proposition(first, &prop("The user is preparing a beta launch and its pricing", 0.8), &[e2.0 as i64], 20)
        .unwrap();
    let other = store.insert_proposition(&prop("The user reads unrelated pages", 0.4), &[e3.0 as i64], 30).unwrap();

    let active = store.propositions_with_status(PropositionStatus::Active, 10).unwrap();
    assert_eq!(active.iter().map(|p| p.id).collect::<Vec<_>>(), vec![other, revised]);
    let revision = active.iter().find(|p| p.id == revised).unwrap();
    assert_eq!(revision.evidence, vec![e1.0 as i64, e2.0 as i64], "a revision keeps both evidence sets");
    assert_eq!(revision.revised_from, Some(first));
    let retired = store.propositions_with_status(PropositionStatus::Retired, 10).unwrap();
    assert_eq!(retired.len(), 1);

    let found = store.search_propositions("launch pricing", 5).unwrap();
    assert!(found.iter().any(|(p, _)| p.id == revised));

    // Deleting one piece of evidence deletes every inference that cites it.
    store.delete_event(e1).unwrap();
    let ids: Vec<i64> = store
        .propositions_with_status(PropositionStatus::Active, 10)
        .unwrap()
        .into_iter()
        .chain(store.propositions_with_status(PropositionStatus::Retired, 10).unwrap())
        .map(|p| p.id)
        .collect();
    assert_eq!(ids, vec![other]);
    assert!(store.search_propositions("launch pricing", 5).unwrap().is_empty(), "FTS follows deletion");
}

#[test]
fn rejected_propositions_stay_rejected_and_can_be_forgotten() {
    let (_dir, store) = store();
    let e = store.put_event_with_source(&event(1, "text", None), EventSource::ScreenOcr).unwrap();
    let id = store.insert_proposition(&prop("The user dislikes meetings", 0.5), &[e.0 as i64], 1).unwrap();
    assert!(store.set_proposition_status(id, PropositionStatus::Rejected, 2).unwrap());
    assert!(store.propositions_with_status(PropositionStatus::Active, 10).unwrap().is_empty());
    assert_eq!(store.propositions_with_status(PropositionStatus::Rejected, 10).unwrap().len(), 1);
    assert!(store.delete_proposition(id).unwrap());
    assert!(store.propositions_with_status(PropositionStatus::Rejected, 10).unwrap().is_empty());
}

#[test]
fn session_notes_and_day_reports_go_with_their_events() {
    let (_dir, store) = store();
    let _e1 = store.put_event_with_source(&event(5_000_000, "a", None), EventSource::ScreenOcr).unwrap();
    let e2 = store.put_event_with_source(&event(9_000_000, "b", None), EventSource::ScreenOcr).unwrap();
    let _late = store.put_event_with_source(&event(50_000_000, "c", None), EventSource::ScreenOcr).unwrap();
    let note = |start_us, end_us, title: &str| SessionNote {
        start_us,
        end_us,
        title: title.into(),
        surface: "You read the pricing docs.".into(),
        beneath: "Nothing notable.".into(),
        signals: "{}".into(),
        event_count: 2,
        generated_us: 10,
        model: "test".into(),
    };
    store.put_session_note(&note(5_000_000, 9_000_000, "Pricing research")).unwrap();
    store.put_session_note(&note(50_000_000, 50_000_000, "Later")).unwrap();
    store
        .put_day_report(&DayReport {
            date_local: "2026-10-10".into(),
            start_us: 0,
            end_us: 20_000_000,
            generated_us: 11,
            model: "test".into(),
            body: "{}".into(),
        })
        .unwrap();
    assert_eq!(store.session_notes_in_range(0, 100_000_000).unwrap().len(), 2);
    store.delete_event(e2).unwrap();
    let left: Vec<String> = store.session_notes_in_range(0, 100_000_000).unwrap().into_iter().map(|n| n.title).collect();
    assert_eq!(left, vec!["Later".to_owned()], "only the note containing the deleted event goes");
    assert!(store.day_report("2026-10-10").unwrap().is_none());
    assert_eq!(store.delete_session_notes_in_range(40_000_000, 60_000_000).unwrap(), 1);
}

#[test]
fn interaction_counts_round_trip_and_follow_range_deletion_and_wipe() {
    let (_dir, store) = store();
    for i in 0..4u64 {
        let counts = InteractionCounts {
            start_us: 1_000_000 + i * 5_000_000,
            end_us: 6_000_000 + i * 5_000_000,
            keys: 10 * i as u32,
            clicks: 1,
            scrolls: 2,
            moves: 30,
        };
        assert!(store.append_interaction_counts(&counts).unwrap());
        assert!(!store.append_interaction_counts(&counts).unwrap(), "replays are ignored");
    }
    assert_eq!(store.interaction_counts_in_range(0, 100_000_000).unwrap().len(), 4);
    store.delete_events_in_range(6_000_000, 11_000_000).unwrap();
    let left: Vec<u64> = store
        .interaction_counts_in_range(0, 100_000_000)
        .unwrap()
        .into_iter()
        .map(|c| c.start_us)
        .collect();
    assert_eq!(left, vec![1_000_000, 16_000_000]);
    store.set_understanding_state("cursor", "42").unwrap();
    store.wipe_all().unwrap();
    assert!(store.interaction_counts_in_range(0, 100_000_000).unwrap().is_empty());
    assert_eq!(store.understanding_state("cursor").unwrap(), None);
}

#[test]
fn verdicts_survive_a_pipeline_reset() {
    let (_dir, store) = store();
    let e1 = put(&store, 1_000_000, "Launch plan");
    let e2 = put(&store, 2_000_000, "Team: $18 a seat");
    let e3 = put(&store, 3_000_000, "Calendar");
    let e4 = put(&store, 4_000_000, "Pull requests");
    let plain = store.insert_proposition(&prop("The user drafts the launch plan in Notes", 0.6), &[e1], 10).unwrap();
    let confirmed = store.insert_proposition(&prop("The user prices the Team plan per seat", 0.6), &[e2], 10).unwrap();
    assert!(store.confirm_proposition(confirmed, 11).unwrap());
    let rejected = store.insert_proposition(&prop("The user dislikes meetings on Fridays", 0.5), &[e3], 10).unwrap();
    assert!(store.set_proposition_status(rejected, PropositionStatus::Rejected, 11).unwrap());
    let first = store.insert_proposition(&prop("The user reviews pull requests", 0.5), &[e4], 10).unwrap();
    store.revise_proposition(first, &prop("The user reviews pull requests every morning", 0.7), &[e4], 12).unwrap();
    store
        .put_session_note(&SessionNote {
            start_us: 1_000_000,
            end_us: 4_000_000,
            title: "Pricing".into(),
            surface: String::new(),
            beneath: String::new(),
            signals: "{}".into(),
            event_count: 4,
            generated_us: 13,
            model: "test".into(),
        })
        .unwrap();
    store
        .put_day_report(&DayReport {
            date_local: "1970-01-01".into(),
            start_us: 0,
            end_us: 86_400_000_000,
            generated_us: 13,
            model: "test".into(),
            body: "{}".into(),
        })
        .unwrap();
    store.set_understanding_state("sessions_through_us", "4000001").unwrap();
    store.set_understanding_state("searches_through_event_id", "4").unwrap();

    store.reset_understanding().unwrap();

    assert_eq!(
        ids_with_status(&store, PropositionStatus::Active),
        vec![confirmed],
        "only the confirmed claim stays in use; the unjudged one (id {plain}) and the revision go"
    );
    assert_eq!(ids_with_status(&store, PropositionStatus::Rejected), vec![rejected]);
    assert!(ids_with_status(&store, PropositionStatus::Retired).is_empty());
    assert_eq!(store.confirmed_proposition_ids().unwrap(), HashSet::from([confirmed]));
    let kept = store.propositions_with_status(PropositionStatus::Active, 5).unwrap();
    assert_eq!(kept[0].evidence, vec![e2], "a kept proposition keeps its evidence");
    assert!((kept[0].confidence - 1.0).abs() < 1e-9);
    assert_eq!(store.propositions_with_status(PropositionStatus::Rejected, 5).unwrap()[0].evidence, vec![e3]);
    assert!(store.search_propositions("Team plan seat", 5).unwrap().iter().any(|(p, _)| p.id == confirmed));
    assert!(store.session_notes_in_range(0, 10_000_000).unwrap().is_empty());
    assert!(store.day_report("1970-01-01").unwrap().is_none());
    assert_eq!(store.understanding_state("sessions_through_us").unwrap(), None);
    assert_eq!(store.understanding_state("searches_through_event_id").unwrap().as_deref(), Some("4"));

    // What was kept still goes with the events it was learned from.
    store.delete_event(EventId(e2 as u64)).unwrap();
    assert!(ids_with_status(&store, PropositionStatus::Active).is_empty());
    assert!(store.confirmed_proposition_ids().unwrap().is_empty(), "the confirmation goes with it");
    store.delete_event(EventId(e3 as u64)).unwrap();
    assert!(ids_with_status(&store, PropositionStatus::Rejected).is_empty());
}

#[test]
fn a_confirmation_is_recorded_and_a_rejection_withdraws_it() {
    let (_dir, store) = store();
    let e = put(&store, 1_000_000, "Launch plan");
    let id = store.insert_proposition(&prop("The user is preparing a beta launch", 0.6), &[e], 1).unwrap();
    assert!(store.confirmed_proposition_ids().unwrap().is_empty());

    assert!(store.confirm_proposition(id, 5).unwrap());
    assert_eq!(store.confirmed_proposition_ids().unwrap(), HashSet::from([id]));
    let confirmed = &store.propositions_with_status(PropositionStatus::Active, 5).unwrap()[0];
    assert!((confirmed.confidence - 1.0).abs() < 1e-9);
    assert!(confirmed.decay <= 0.3);
    assert_eq!(confirmed.updated_us, 5);

    assert!(store.set_proposition_status(id, PropositionStatus::Rejected, 6).unwrap());
    assert!(store.confirmed_proposition_ids().unwrap().is_empty(), "a rejection removes the verdict row");
    assert_eq!(ids_with_status(&store, PropositionStatus::Rejected), vec![id]);

    // The person's latest word wins: confirming it again brings it back.
    assert!(store.confirm_proposition(id, 7).unwrap());
    assert_eq!(ids_with_status(&store, PropositionStatus::Active), vec![id]);
    assert_eq!(store.confirmed_proposition_ids().unwrap(), HashSet::from([id]));
    assert!(!store.confirm_proposition(4242, 8).unwrap(), "an unknown id confirms nothing");

    store.wipe_all().unwrap();
    assert!(store.confirmed_proposition_ids().unwrap().is_empty());
}

#[test]
fn a_confirm_never_reactivates_a_retired_proposition() {
    let (_dir, store) = store();
    let e = put(&store, 1_000_000, "Launch plan");
    let first = store.insert_proposition(&prop("The user is preparing a beta launch", 0.6), &[e], 1).unwrap();
    let revision = store
        .revise_proposition(first, &prop("The user is preparing a beta launch and its pricing", 0.7), &[e], 2)
        .unwrap();

    assert!(!store.confirm_proposition(first, 3).unwrap());
    assert_eq!(ids_with_status(&store, PropositionStatus::Retired), vec![first]);
    assert_eq!(ids_with_status(&store, PropositionStatus::Active), vec![revision], "no duplicate comes back");
    assert!(store.confirmed_proposition_ids().unwrap().is_empty());
    let retired = &store.propositions_with_status(PropositionStatus::Retired, 5).unwrap()[0];
    assert!((retired.confidence - 0.6).abs() < 1e-9, "a retired row is left as it was");
}

#[test]
fn the_newest_revision_is_found_through_revised_from() {
    let (_dir, store) = store();
    let e = put(&store, 1_000_000, "Launch plan");
    let one = store.insert_proposition(&prop("The user plans a beta launch", 0.6), &[e], 1).unwrap();
    let two = store.revise_proposition(one, &prop("The user plans a beta launch in October", 0.7), &[e], 2).unwrap();
    let three = store
        .revise_proposition(two, &prop("The user plans a beta launch on October 21", 0.8), &[e], 3)
        .unwrap();
    assert_eq!(store.newest_revision(one).unwrap(), Some(three));
    assert_eq!(store.newest_revision(two).unwrap(), Some(three));
    assert_eq!(store.newest_revision(three).unwrap(), Some(three));

    let lone = store.insert_proposition(&prop("The user writes Rust", 0.6), &[e], 4).unwrap();
    assert_eq!(store.newest_revision(lone).unwrap(), Some(lone));
    store.set_proposition_status(lone, PropositionStatus::Retired, 5).unwrap();
    assert_eq!(store.newest_revision(lone).unwrap(), Some(lone), "merged away, nothing revised it");
    assert_eq!(store.newest_revision(4242).unwrap(), None);

    // A row revised twice (an older brain could hold one): the newest revision
    // still in use wins over a newer one that was rejected.
    let base = store.insert_proposition(&prop("The user reviews pull requests", 0.6), &[e], 6).unwrap();
    let kept = store.revise_proposition(base, &prop("The user reviews pull requests daily", 0.7), &[e], 7).unwrap();
    let dropped = store
        .revise_proposition(base, &prop("The user reviews pull requests at night", 0.7), &[e], 8)
        .unwrap();
    assert_eq!(store.newest_revision(base).unwrap(), Some(dropped));
    store.set_proposition_status(dropped, PropositionStatus::Rejected, 9).unwrap();
    assert_eq!(store.newest_revision(base).unwrap(), Some(kept));
}

#[test]
fn added_evidence_is_linked_and_marks_the_proposition_seen() {
    let (_dir, store) = store();
    let e1 = put(&store, 1_000_000, "Launch plan");
    let e2 = put(&store, 2_000_000, "Launch plan, later");
    let e3 = put(&store, 3_000_000, "Launch plan, again");
    let id = store.insert_proposition(&prop("The user is preparing a beta launch", 0.6), &[e1], 10).unwrap();

    assert_eq!(store.add_proposition_evidence(id, &[e2, e2, 4242, e1], 50).unwrap(), 1, "only the new, existing event");
    let seen = &store.propositions_with_status(PropositionStatus::Active, 5).unwrap()[0];
    assert_eq!(seen.evidence, vec![e1, e2]);
    assert_eq!(seen.updated_us, 50);
    assert_eq!(store.add_proposition_evidence(id, &[e3], 40).unwrap(), 1);
    assert_eq!(store.propositions_with_status(PropositionStatus::Active, 5).unwrap()[0].updated_us, 50, "never moves back");
    assert_eq!(store.add_proposition_evidence(4242, &[e1], 60).unwrap(), 0, "an unknown proposition gains nothing");

    // Evidence added later holds the proposition like the first did.
    store.delete_event(EventId(e3 as u64)).unwrap();
    assert!(ids_with_status(&store, PropositionStatus::Active).is_empty());
}

#[test]
fn keyframes_near_a_time_are_ordered_by_distance() {
    let (_dir, store) = store();
    let s = 1_000_000u64;
    let put_frame = |ts_us: u64, keyframe: Option<String>| {
        let mut frame = event(ts_us, "on screen", None);
        frame.keyframe_blob = keyframe;
        store.put_event_with_source(&frame, EventSource::ScreenOcr).unwrap().0 as i64
    };
    let _before = put_frame(5 * s, Some(digest(1)));
    let at_start = put_frame(10 * s, Some(digest(2)));
    let just_before = put_frame(29 * s, Some(digest(3)));
    let _text_only = put_frame(30 * s, None);
    let _legacy_path = put_frame(30 * s, Some("abcdef0123456789/keyframe-0001.bin".into()));
    let _upper_case = put_frame(30 * s, Some("AB".repeat(32)));
    let just_after = put_frame(31 * s, Some(digest(4)));
    let later = put_frame(45 * s, Some(digest(5)));
    let at_end = put_frame(60 * s, Some(digest(6)));
    let _after = put_frame(70 * s, Some(digest(7)));

    let near = store.keyframe_events_near(10 * s, 60 * s, 30 * s, 10).unwrap();
    assert_eq!(
        head_ids(&near),
        vec![just_before, just_after, later, at_start, at_end],
        "nearest first, the earlier of a tie first, both ends included, only stored screenshots"
    );
    assert!(near.iter().all(|head| head.has_screenshot));
    assert_eq!(head_ids(&store.keyframe_events_near(10 * s, 60 * s, 30 * s, 2).unwrap()), vec![just_before, just_after]);
    assert_eq!(head_ids(&store.keyframe_events_near(10 * s, 60 * s, 60 * s, 1).unwrap()), vec![at_end]);
    assert!(store.keyframe_events_near(32 * s, 44 * s, 40 * s, 3).unwrap().is_empty());
    assert!(store.keyframe_events_near(10 * s, 60 * s, 30 * s, 0).unwrap().is_empty());
}

#[test]
fn event_heads_carry_no_text() {
    let (_dir, store) = store();
    let mut page = event(2_000_000, "BODY-TEXT one: the whole pricing page", Some("https://stripe.com/docs/billing"));
    page.window_title = Some("Billing | Stripe".into());
    page.keyframe_blob = Some(digest(9));
    let page_id = store.put_event_with_source(&page, EventSource::BrowserPage).unwrap().0 as i64;
    let mut note = event(1_000_000, "BODY-TEXT two: Team $18 a seat", None);
    note.app_bundle_id = Some("com.apple.Notes".into());
    note.window_title = Some("Launch plan".into());
    let note_id = store.put_event_with_source(&note, EventSource::ScreenOcr).unwrap().0 as i64;
    let later_id = store
        .put_event_with_source(&event(9_000_000, "BODY-TEXT three", None), EventSource::ScreenContext)
        .unwrap()
        .0 as i64;

    let heads = store.event_heads(&[page_id, note_id, page_id, 4242]).unwrap();
    assert_eq!(head_ids(&heads), vec![note_id, page_id], "oldest first, repeats once, unknown ids left out");
    assert_eq!(
        heads[1],
        EventHead {
            id: page_id,
            ts_us: 2_000_000,
            app_bundle_id: Some("com.google.Chrome".into()),
            window_title: Some("Billing | Stripe".into()),
            url: Some("https://stripe.com/docs/billing".into()),
            source: "browser_page".into(),
            has_screenshot: true,
        }
    );
    assert_eq!((heads[0].source.as_str(), heads[0].has_screenshot), ("screen_ocr", false));
    let json = serde_json::to_string(&heads).unwrap();
    assert!(!json.contains("BODY-TEXT"), "{json}");
    assert!(store.event_heads(&[]).unwrap().is_empty());

    let day = store.event_heads_in_range(0, 10_000_000, 10).unwrap();
    assert_eq!(head_ids(&day), vec![note_id, page_id, later_id]);
    assert!(!serde_json::to_string(&day).unwrap().contains("BODY-TEXT"));
    assert_eq!(
        head_ids(&store.event_heads_in_range(0, 10_000_000, 2).unwrap()),
        vec![page_id, later_id],
        "past the limit, the newest are kept"
    );
    assert_eq!(head_ids(&store.event_heads_in_range(1_000_000, 9_000_000, 10).unwrap()), vec![note_id, page_id]);
}

#[test]
fn a_reader_of_an_older_brain_sees_no_understanding_rather_than_an_error() {
    let (dir, store) = store();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([7; 32]);
    let mut frame = event(5_000_000, "Launch plan", None);
    frame.keyframe_blob = Some(digest(1));
    let e = store.put_event_with_source(&frame, EventSource::ScreenOcr).unwrap().0 as i64;
    let p = store.insert_proposition(&prop("The user is preparing a beta launch", 0.6), &[e], 1).unwrap();
    drop(store);
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert!(reader.confirmed_proposition_ids().unwrap().is_empty());
    drop(reader);

    // Written before confirmations were kept (migration 0014): nothing reads as
    // confirmed, and everything else still reads.
    mci_core::store::open(&path, &key).unwrap().conn().execute_batch("DROP TABLE proposition_verdicts;").unwrap();
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert!(reader.confirmed_proposition_ids().unwrap().is_empty());
    assert_eq!(ids_with_status(&reader, PropositionStatus::Active), vec![p]);
    assert_eq!(reader.newest_revision(p).unwrap(), Some(p));
    drop(reader);

    // Written before the understanding layer and event sources (0013, 0009).
    mci_core::store::open(&path, &key)
        .unwrap()
        .conn()
        .execute_batch(
            "DROP TABLE proposition_evidence;
             DROP TABLE propositions;
             DROP TABLE propositions_fts;
             DROP TABLE session_notes;
             DROP TABLE day_reports;
             DROP TABLE understanding_state;
             DROP TABLE search_queries;
             DROP TABLE interaction_counts;
             DROP TABLE event_sources;",
        )
        .unwrap();
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert!(reader.propositions_with_status(PropositionStatus::Active, 5).unwrap().is_empty());
    assert!(reader.search_propositions("beta launch", 5).unwrap().is_empty());
    assert!(reader.search_queries_in_range(0, 10, 5).unwrap().is_empty());
    assert!(reader.interaction_counts_in_range(0, 10).unwrap().is_empty());
    assert!(reader.session_notes_in_range(0, 10).unwrap().is_empty());
    assert!(reader.day_report("1970-01-01").unwrap().is_none());
    assert!(reader.understanding_state("sessions_through_us").unwrap().is_none());
    assert!(reader.confirmed_proposition_ids().unwrap().is_empty());
    assert_eq!(reader.newest_revision(p).unwrap(), None);
    // Events are in every brain; only their source is unknown.
    let heads = reader.event_heads(&[e]).unwrap();
    assert_eq!((heads.len(), heads[0].source.as_str(), heads[0].has_screenshot), (1, "unknown", true));
    assert_eq!(head_ids(&reader.event_heads_in_range(0, 10_000_000, 5).unwrap()), vec![e]);
    assert_eq!(head_ids(&reader.keyframe_events_near(0, 10_000_000, 5_000_000, 5).unwrap()), vec![e]);
    assert_eq!(reader.observed_events_in_range(0, 10_000_000, 5).unwrap().len(), 1);
}
