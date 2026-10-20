use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write as _;

use sha2::Digest as _;

use super::story::{FOUNDER, PEOPLE};
use super::*;

/// Names from the maintainer's own life that must never appear in the made-up
/// world, kept as SHA-256 digests of the lowercased word so this public file
/// doesn't list them.
const PRIVATE_NAMES: [&str; 3] = [
    "ed6c58a3009a2b91b6b1374e3745762de7370bf1e40c1a6e66140d2942769da4",
    "cdf2e21fa04b3c5e4793783192eb1bebb4574064d2f43853535d7e765aa3e8c9",
    "d6c8dec6ccdd9eb13bc4f47d18b0c0b2c57dd96dbe51e913fe2030c024749f04",
];

/// Pacific daylight time.
const TZ: i32 = -7 * 3600;
/// Monday, October 19, 2026, 2:41 PM at `TZ`.
const MONDAY_AFTERNOON: u64 = 1_792_446_060_000_000;

fn at_local(now: u64, hour: u64, minute: u64) -> u64 {
    day_start(now, TZ, 0) + (hour * 60 + minute) * MIN
}

#[test]
fn local_time_reads_as_a_person_would() {
    let local = Local::of(MONDAY_AFTERNOON, TZ);
    assert_eq!(local.date_string(), "2026-10-19");
    assert_eq!(local.long_date(), "Monday, October 19");
    assert_eq!(local.short_date(), "Oct 19");
    assert_eq!(local.clock(), "2:41 PM");
    assert!(!local.is_weekend());
    assert_eq!(
        Local::of(at_local(MONDAY_AFTERNOON, 0, 5), TZ).clock(),
        "12:05 AM"
    );
    assert_eq!(
        Local::of(at_local(MONDAY_AFTERNOON, 12, 0), TZ).clock(),
        "12:00 PM"
    );
    let sunday = Local::of(MONDAY_AFTERNOON - DAY, TZ);
    assert_eq!(
        (sunday.weekday_name(), sunday.is_weekend()),
        ("Sunday", true)
    );
}

#[test]
fn the_same_clock_makes_the_same_week() {
    let first = world(MONDAY_AFTERNOON, TZ);
    let second = world(MONDAY_AFTERNOON, TZ);
    assert_eq!(first, second);
    assert_eq!(first.screens(), second.screens());
    assert_eq!(first.calendar_json(), second.calendar_json());
}

#[test]
fn the_week_moves_with_the_clock() {
    // A week later at the same time of day: the same week, a week later.
    let now = world(MONDAY_AFTERNOON, TZ);
    let later = world(MONDAY_AFTERNOON + 7 * DAY, TZ);
    let shift = |moments: Vec<(u64, &Win, bool)>| -> Vec<(u64, String, bool)> {
        moments
            .into_iter()
            .map(|(ts, win, keeps)| (ts, win.title.clone(), keeps))
            .collect()
    };
    let expected: Vec<(u64, String, bool)> = shift(now.moments())
        .into_iter()
        .map(|(ts, title, keeps)| (ts + 7 * DAY, title, keeps))
        .collect();
    assert_eq!(shift(later.moments()), expected);
    let events: Vec<(String, u64)> = now
        .calendar
        .iter()
        .map(|e| (e.title.clone(), e.start_us + 7 * DAY))
        .collect();
    let later_events: Vec<(String, u64)> = later
        .calendar
        .iter()
        .map(|e| (e.title.clone(), e.start_us))
        .collect();
    assert_eq!(later_events, events);
}

#[test]
fn every_moment_is_in_the_last_week_and_none_after_now() {
    for now in [
        MONDAY_AFTERNOON,
        at_local(MONDAY_AFTERNOON, 8, 0),
        at_local(MONDAY_AFTERNOON, 12, 40),
        at_local(MONDAY_AFTERNOON, 21, 30),
        MONDAY_AFTERNOON + 3 * DAY + 17 * MIN,
        MONDAY_AFTERNOON + 5 * DAY,
    ] {
        let week = world(now, TZ);
        let moments = week.moments();
        assert!(moments.len() > 150, "a busy week: {}", moments.len());
        let first = day_start(now, TZ, 6);
        for (ts, _, _) in &moments {
            assert!(*ts >= first, "inside the week");
            assert!(*ts + 30_000_000 <= now, "never after now");
        }
        let times: Vec<u64> = moments.iter().map(|(ts, _, _)| *ts).collect();
        let mut sorted = times.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(times, sorted, "one moment at a time, in order");
    }
}

#[test]
fn in_the_afternoon_the_newest_session_is_still_going() {
    let week = world(MONDAY_AFTERNOON, TZ);
    let today = week.days.last().unwrap();
    assert_eq!(today.back, 0);
    let (going, noted) = today.sessions.split_last().unwrap();
    assert!(
        going.note.is_none(),
        "the session under way has no note yet"
    );
    assert!(noted.iter().all(|s| s.note.is_some()));
    let newest = week.moments().last().unwrap().0;
    assert!(
        MONDAY_AFTERNOON - newest <= 90_000_000,
        "saved a moment ago"
    );
    // 2:41 PM is in the second of two code sessions, from 2:00 and 2:29.
    assert_eq!(going.start_us, at_local(MONDAY_AFTERNOON, 14, 29));
    assert!(going
        .holds
        .iter()
        .any(|h| h.win.title == "billing.ts \u{2014} pebblewick-app"));
}

#[test]
fn before_work_today_is_empty_and_yesterday_is_where_you_left_off() {
    let now = at_local(MONDAY_AFTERNOON, 8, 0);
    let week = world(now, TZ);
    assert!(week.days.last().unwrap().sessions.is_empty());
    let yesterday = &week.days[week.days.len() - 2];
    assert!(yesterday.sessions.iter().all(|s| s.note.is_some()));
    let newest = week.moments().last().unwrap().0;
    assert!(newest < day_start(now, TZ, 0));
}

#[test]
fn a_pause_between_sessions_stays_with_the_session_before() {
    // 12:40, over lunch: the Q4 update is still open from 11:44.
    let now = at_local(MONDAY_AFTERNOON, 12, 40);
    let week = world(now, TZ);
    let going = week.days.last().unwrap().sessions.last().unwrap();
    assert_eq!(going.start_us, at_local(MONDAY_AFTERNOON, 11, 44));
    assert!(going.note.is_none());
    let newest = week.moments().last().unwrap().0;
    assert_eq!(now - newest, 30_000_000, "still at it, a moment ago");
}

#[test]
fn after_work_every_session_has_its_note() {
    let week = world(at_local(MONDAY_AFTERNOON, 21, 30), TZ);
    let today = week.days.last().unwrap();
    assert!(today.sessions.len() >= 15);
    assert!(today.sessions.iter().all(|s| s.note.is_some()));
}

#[test]
fn sessions_never_overlap_and_stay_short() {
    let week = world(at_local(MONDAY_AFTERNOON, 21, 30), TZ);
    for day in &week.days {
        for pair in day.sessions.windows(2) {
            assert!(
                pair[0].end_us() <= pair[1].start_us,
                "one session at a time"
            );
        }
        for session in &day.sessions {
            assert!(
                session.end_us() - session.start_us <= 30 * MIN,
                "at most 30 minutes"
            );
        }
    }
}

#[test]
fn every_window_says_something_and_has_a_line() {
    let week = world(MONDAY_AFTERNOON, TZ);
    for (_, win, _) in week.moments() {
        assert!(!win.main.trim().is_empty(), "{}", win.title);
        assert!(!win.title.is_empty());
        let caption = win.caption.as_str();
        assert!(
            !caption.is_empty() && caption.chars().count() <= 200,
            "{caption}"
        );
        assert!(!caption.contains('!'), "{caption}");
        assert!(
            !caption.ends_with('.'),
            "a caption is a line, not a sentence: {caption}"
        );
    }
}

#[test]
fn each_screenshot_is_listed_once_with_its_drawing() {
    let week = world(MONDAY_AFTERNOON, TZ);
    let list = week.screen_list();
    let ids: Vec<&str> = list.iter().map(|(screen, _)| screen.id.as_str()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!(ids.len(), unique.len(), "each screen once");
    assert!(ids.len() >= 20, "{ids:?}");
    let templates = [
        "editor", "terminal", "browser", "slack", "zoom", "notion", "figma", "calendar",
    ];
    for (screen, win) in &list {
        assert!(templates.contains(&screen.template), "{}", screen.template);
        assert!(screen.meta.is_object(), "{}", screen.id);
        if screen.template == "browser" {
            assert!(win.url.is_some(), "{}", screen.id);
            assert!(screen.meta["page"].is_string(), "{}", screen.id);
        }
    }
    // Every moment that keeps a screenshot names one on the list.
    for (_, win, keeps) in week.moments() {
        if let (true, Some(screen)) = (keeps, win.screen.as_ref()) {
            assert!(unique.contains(screen.id.as_str()), "{}", screen.id);
        }
    }
    let json = week.screens();
    assert_eq!(json["version"], SCREENS_VERSION);
    assert_eq!(json["screens"].as_array().unwrap().len(), ids.len());
}

#[test]
fn a_screenshot_shows_the_same_window_wherever_it_is_used() {
    for now in [
        MONDAY_AFTERNOON,
        at_local(MONDAY_AFTERNOON, 21, 30),
        MONDAY_AFTERNOON + 3 * DAY + 17 * MIN,
    ] {
        let week = world(now, TZ);
        let mut seen: HashMap<String, Win> = HashMap::new();
        for (_, win, _) in week.moments() {
            let Some(screen) = win.screen.as_ref() else {
                continue;
            };
            if let Some(first) = seen.insert(screen.id.clone(), win.clone()) {
                assert_eq!(
                    &first, win,
                    "{} is drawn once for every moment that names it",
                    screen.id
                );
            }
        }
    }
}

#[test]
fn the_world_is_made_up() {
    let week = world(MONDAY_AFTERNOON, TZ);
    let mut corpus = String::new();
    for (_, win, _) in week.moments() {
        let _ = writeln!(
            corpus,
            "{} {:?} {} {} {}",
            win.title, win.url, win.main, win.rest, win.caption
        );
    }
    corpus.push_str(&week.screens().to_string());
    corpus.push_str(&week.calendar_json().to_string());
    for claim in &week.claims {
        corpus.push_str(&claim.text);
    }
    for never in [
        "Amy",
        "Jain",
        "amyjain",
        "Hippocampus",
        "Northwind",
        "Trailhead",
        "Sam ",
        "sk_live",
        "sk_test",
        "rk_live",
        "whsec_",
        "@gmail",
        "password",
    ] {
        assert!(!corpus.contains(never), "{never} is in the demo week");
    }
    for word in corpus.split(|c: char| !c.is_alphanumeric()) {
        let mut hex = String::with_capacity(64);
        for byte in sha2::Sha256::digest(word.to_lowercase().as_bytes()) {
            let _ = write!(hex, "{byte:02x}");
        }
        assert!(
            !PRIVATE_NAMES.contains(&hex.as_str()),
            "a private name is in the demo week"
        );
    }
    // Addresses are the real products' or `.example` ones.
    for (_, win, _) in week.moments() {
        if let Some(url) = &win.url {
            let host = mci_brain::apps::host_of(url).unwrap();
            assert!(
                host.ends_with(".example")
                    || ["stripe.com", "google.com", "claude.ai"]
                        .iter()
                        .any(|real| host == *real || host.ends_with(&format!(".{real}"))),
                "{host}"
            );
        }
    }
    // Everyone who writes in a chat is one of the week's people.
    for (screen, _) in week.screen_list() {
        if let Some(messages) = screen.meta.get("messages").and_then(Value::as_array) {
            for message in messages {
                let who = message[0].as_str().unwrap();
                assert!(
                    PEOPLE.contains(&who) || ["user", "assistant"].contains(&who),
                    "{who}"
                );
            }
        }
    }
    assert_eq!(FOUNDER, "Ren Alder");
}

/// What lane C's subject rules would call each window: a rough stand-in
/// for `mci_brain::subject`, enough to check the story's ranking.
fn item_of(win: &Win) -> Option<&'static str> {
    let title = win.title.as_str();
    if title.ends_with("\u{2014} pebblewick-app") || title.starts_with("pebblewick-app \u{2014}") {
        Some("pebblewick-app")
    } else if title.starts_with("Q4 investor update") {
        Some("Q4 investor update")
    } else if title.starts_with("2027 budget") {
        Some("2027 budget")
    } else if title == "Pricing page v2" {
        Some("Pricing page v2")
    } else if title == "October changelog" {
        Some("October changelog")
    } else if title == "Hiring plan" {
        Some("Hiring plan")
    } else {
        None
    }
}

#[test]
fn working_on_ranks_as_the_story_says_on_every_day_of_the_week() {
    for days in 0..7 {
        ranks_as_the_story_says(at_local(MONDAY_AFTERNOON, 21, 30) + days * DAY);
        ranks_as_the_story_says(at_local(MONDAY_AFTERNOON, 14, 41) + days * DAY);
    }
}

fn ranks_as_the_story_says(now: u64) {
    let week = world(now, TZ);
    let mut minutes: BTreeMap<&str, u64> = BTreeMap::new();
    for day in &week.days {
        for session in &day.sessions {
            let mut at = session.start_us;
            for hold in &session.holds {
                let held = hold.minutes.min(now.saturating_sub(at) / MIN);
                if let Some(item) = item_of(&hold.win) {
                    *minutes.entry(item).or_default() += held;
                }
                at += hold.minutes * MIN;
            }
        }
    }
    let mut ranked: Vec<(&str, u64)> = minutes.into_iter().collect();
    ranked.sort_by_key(|(_, minutes)| std::cmp::Reverse(*minutes));
    let names: Vec<&str> = ranked.iter().map(|(name, _)| *name).collect();
    assert_eq!(
        names,
        [
            "pebblewick-app",
            "Q4 investor update",
            "2027 budget",
            "Pricing page v2",
            "October changelog",
            "Hiring plan"
        ],
        "{} {ranked:?}",
        Local::of(now, TZ).long_date()
    );
    assert!(
        ranked[..5].iter().all(|(_, m)| *m >= 30),
        "the five in the sidebar each have 30 minutes or more: {ranked:?}"
    );
}

#[test]
fn the_calendar_follows_the_week() {
    let week = world(MONDAY_AFTERNOON, TZ);
    let today = day_start(MONDAY_AFTERNOON, TZ, 0);
    let sync = week
        .calendar
        .iter()
        .find(|e| e.title == "Team sync" && e.start_us >= today)
        .expect("a team sync today");
    assert_eq!(Local::of(sync.start_us, TZ).clock(), "10:00 AM");
    let investors = week
        .calendar
        .iter()
        .find(|e| e.title == "Investor update")
        .unwrap();
    assert_eq!(Local::of(investors.start_us, TZ).clock(), "4:00 PM");
    for event in &week.calendar {
        assert!(event.end_us > event.start_us);
        assert!(event.start_us + 7 * DAY >= today && event.start_us < today + 7 * DAY);
        assert_eq!(event.calendar, "Work");
    }
    let json = week.calendar_json();
    assert_eq!(json["version"], CALENDAR_VERSION);
    let first = &json["events"][0];
    for key in ["id", "title", "start_us", "end_us", "calendar", "location"] {
        assert!(first.get(key).is_some(), "{key}");
    }
    assert!(
        first.get("attendees").is_none(),
        "attendees are never read or stored"
    );
    // A meeting on the calendar is a call in the memory at the same time.
    let call_starts: HashSet<u64> = week
        .days
        .iter()
        .flat_map(|d| d.sessions.iter())
        .filter(|s| s.holds.iter().any(|h| h.win.app == "us.zoom.xos"))
        .map(|s| s.start_us)
        .collect();
    assert!(call_starts.contains(&sync.start_us));
}

#[test]
fn lines_about_ren_have_moments_that_show_them() {
    let week = world(MONDAY_AFTERNOON, TZ);
    assert!(week.claims.len() >= 10);
    assert!(week.claims.iter().any(|c| c.confirmed));
    // The lines an AI tool may be told need moments on two days or more.
    let days_of = |words: &[&str]| -> HashSet<String> {
        week.moments()
            .into_iter()
            .filter(|(_, win, _)| words.iter().any(|w| win.title.contains(w)))
            .map(|(ts, _, _)| Local::of(ts, TZ).date_string())
            .collect()
    };
    for claim in week
        .claims
        .iter()
        .filter(|c| c.days.is_empty() && !c.confirmed)
    {
        assert!(days_of(&claim.evidence).len() >= 2, "{}", claim.text);
    }
}

#[test]
fn the_drawing_tools_manifest_is_read_strictly() {
    let digest = "ab".repeat(32);
    let good = format!(r#"{{"version": 1, "screens": {{"code-billing-ts": "{digest}"}}}}"#);
    let read = read_manifest(&good).unwrap();
    assert_eq!(read.get("code-billing-ts"), Some(&digest));
    for bad in [
        r#"{"version": 2, "screens": {}}"#.to_owned(),
        r#"{"version": 1}"#.to_owned(),
        format!(
            r#"{{"version": 1, "screens": {{"a": "{}"}}}}"#,
            "AB".repeat(32)
        ),
        r#"{"version": 1, "screens": {"a": "abc"}}"#.to_owned(),
        r#"{"version": 1, "screens": {"a": 7}}"#.to_owned(),
        "not json".to_owned(),
    ] {
        assert!(read_manifest(&bad).is_err(), "{bad}");
    }
}

#[test]
fn the_week_is_written_and_read_back() {
    let dir = tempfile::tempdir().unwrap();
    let key = mci_core::crypto::DbKey::from_bytes([7; 32]);
    let store = SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &key).unwrap();
    require_empty(&store).unwrap();
    let week = world(MONDAY_AFTERNOON, TZ);
    let digests: HashMap<String, String> = week
        .screen_list()
        .iter()
        .map(|(screen, _)| (screen.id.clone(), "0f".repeat(32)))
        .collect();
    let written = seed(&store, &week, &digests).unwrap();
    assert_eq!(written.moments, week.moments().len());
    assert!(written.screenshots > 40, "{written:?}");
    assert_eq!(
        written.notes,
        week.days
            .iter()
            .flat_map(|d| &d.sessions)
            .filter(|s| s.note.is_some())
            .count()
    );
    assert_eq!(written.claims, week.claims.len());
    assert!(require_empty(&store).is_err(), "never written twice");
    let newest = store.recent_events(1).unwrap();
    assert_eq!(newest[0].ts_us, week.moments().last().unwrap().0);
    let reading = store.moment_reading(newest[0].id).unwrap().unwrap();
    assert_eq!(reading.version, READING_VERSION);
    assert!(reading.caption.is_some());
    let searches = store
        .search_queries_in_range(day_start(MONDAY_AFTERNOON, TZ, 6), MONDAY_AFTERNOON, 50)
        .unwrap();
    let queries: Vec<&str> = searches.iter().map(|s| s.query.as_str()).collect();
    assert!(
        queries.contains(&"stripe prorate monthly to yearly"),
        "{queries:?}"
    );
}
