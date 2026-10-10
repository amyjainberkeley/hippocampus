use mci_brain::episode_segmenter::EpisodeWriter;
use mci_brain::understanding::{
    DayReport, EpisodeNote, InteractionCounts, NewProposition, PropositionKind, PropositionStatus,
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

#[test]
fn searches_are_read_from_urls_and_listed_without_repeats() {
    let (_dir, store) = store();
    let url = "https://www.google.com/search?q=team+plan+pricing";
    let a = store.put_event_with_source(&event(1_000_000, "results", Some(url)), EventSource::BrowserPage).unwrap();
    let b = store.put_event_with_source(&event(2_000_000, "results again", Some(url)), EventSource::ScreenOcr).unwrap();
    store.put_event_with_source(&event(3_000_000, "docs", Some("https://stripe.com/docs")), EventSource::BrowserPage).unwrap();
    assert_eq!(store.backfill_search_queries().unwrap(), 2);
    assert_eq!(store.backfill_search_queries().unwrap(), 0, "backfill is repeat-safe");
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
fn episode_notes_and_day_reports_go_with_their_events() {
    let (_dir, store) = store();
    let e1 = store.put_event_with_source(&event(5_000_000, "a", None), EventSource::ScreenOcr).unwrap();
    let e2 = store.put_event_with_source(&event(9_000_000, "b", None), EventSource::ScreenOcr).unwrap();
    let episode = store.create_episode(5_000_000, 9_000_000, Some("com.google.Chrome")).unwrap();
    store.set_event_episode(e1, episode).unwrap();
    store.set_event_episode(e2, episode).unwrap();
    store
        .put_episode_note(&EpisodeNote {
            episode_id: episode.0 as i64,
            title: "Pricing research".into(),
            summary: "Read the pricing docs.".into(),
            signals: "{}".into(),
            through_event_id: e2.0 as i64,
            generated_us: 10,
            model: "test".into(),
        })
        .unwrap();
    store
        .put_day_report(&DayReport {
            date_local: "2026-10-10".into(),
            start_us: 0,
            end_us: 86_400_000_000,
            generated_us: 11,
            model: "test".into(),
            body: "{}".into(),
        })
        .unwrap();
    assert_eq!(store.episode_notes_in_range(0, 20_000_000).unwrap().len(), 1);
    store.delete_event(e2).unwrap();
    assert!(store.episode_note(episode.0 as i64).unwrap().is_none());
    assert!(store.day_report("2026-10-10").unwrap().is_none());
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
fn a_reader_of_an_older_brain_sees_no_understanding_rather_than_an_error() {
    let (dir, store) = store();
    drop(store);
    let reader =
        SqlCipherBrainStore::open_readonly(&dir.path().join("brain.sqlite"), &DbKey::from_bytes([7; 32])).unwrap();
    assert!(reader.propositions_with_status(PropositionStatus::Active, 5).unwrap().is_empty());
    assert!(reader.search_queries_in_range(0, 10, 5).unwrap().is_empty());
}
