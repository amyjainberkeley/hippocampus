use mci_agent_handoff_eval::{collapse_ranked_sessions, parse_dataset_timestamp};

#[test]
fn parses_dataset_timestamps_in_utc_microseconds() {
    assert_eq!(
        parse_dataset_timestamp("1970/01/02 (Fri) 00:01").unwrap(),
        86_460_000_000
    );
}

#[test]
fn rejects_a_wrong_weekday_in_dataset_timestamp() {
    let error = parse_dataset_timestamp("2026/09/02 (Thu) 18:00").unwrap_err();
    assert!(error.contains("weekday"));
}

#[test]
fn ranked_sessions_keep_first_occurrence_and_skip_unknown_events() {
    let ranked_events = vec![30, 10, 20, 11, 999];
    let owners = [
        (10, "source://one".to_owned()),
        (11, "source://one".to_owned()),
        (20, "source://two".to_owned()),
        (30, "source://three".to_owned()),
    ]
    .into_iter()
    .collect();

    assert_eq!(
        collapse_ranked_sessions(&ranked_events, &owners),
        vec!["source://three", "source://one", "source://two"]
    );
}
