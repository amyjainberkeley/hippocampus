use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use super::story::{FOUNDER, OLDEST_DAY_BACK, PEOPLE, PROJECT_FOLDER};
use super::*;

/// Names from the maintainers' own lives that must never appear in the
/// made-up world. They are kept outside the repository, one per line, in
/// this file under the home folder; the check runs only where it exists.
/// The repository holds neither the names nor anything that leads to them.
const PRIVATE_NAMES_FILE: &str = ".config/hippocampus-dev/private-names.txt";

/// The private names list at `path`, lowercased: one name per line, blank
/// lines and lines starting with `#` skipped. Empty when there is no file.
fn private_names_at(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .map(|text| {
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !line.starts_with('#'))
                .map(str::to_lowercase)
                .collect()
        })
        .unwrap_or_default()
}

/// The list under this user's home folder, if there is one.
fn private_names() -> Vec<String> {
    std::env::var_os("HOME")
        .map(|home| private_names_at(&PathBuf::from(home).join(PRIVATE_NAMES_FILE)))
        .unwrap_or_default()
}

/// The words in `text`, lowercased: its runs of letters and digits.
fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// Whether `text` holds `name`: its words, whole and in a row, whatever
/// the case and whatever stands between them.
fn holds_name(text: &str, name: &str) -> bool {
    let name = words(name);
    !name.is_empty()
        && words(text)
            .windows(name.len())
            .any(|run| run == name.as_slice())
}

/// The first place in `fields` that holds a name from `names`: only where it
/// is, never the name.
fn place_of_a_private_name<'a>(
    fields: &'a [(String, String)],
    names: &[String],
) -> Option<&'a str> {
    fields
        .iter()
        .find(|(_, text)| names.iter().any(|name| holds_name(text, name)))
        .map(|(place, _)| place.as_str())
}

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
fn every_moment_is_in_its_days_and_none_after_now() {
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
        let first = day_start(now, TZ, OLDEST_DAY_BACK);
        let week = day_start(now, TZ, 6);
        for (ts, win, _) in &moments {
            assert!(*ts >= first, "inside the days the memory holds");
            assert!(*ts + 30_000_000 <= now, "never after now");
            if *ts < week {
                assert_eq!(
                    win.title, "Waitlist launch plan",
                    "before the week, only last week's project"
                );
            }
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

/// Every piece of text the week writes, with where it is.
fn every_field(week: &World) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    for (index, (_, win, _)) in week.moments().into_iter().enumerate() {
        fields.push((format!("moment {index}'s title"), win.title.clone()));
        fields.push((
            format!("moment {index}'s address"),
            win.url.clone().unwrap_or_default(),
        ));
        fields.push((format!("moment {index}'s text"), win.main.clone()));
        fields.push((format!("moment {index}'s window parts"), win.rest.clone()));
        fields.push((format!("moment {index}'s caption"), win.caption.clone()));
    }
    fields.push(("the screen list".into(), week.screens().to_string()));
    fields.push(("the calendar".into(), week.calendar_json().to_string()));
    for (index, claim) in week.claims.iter().enumerate() {
        fields.push((format!("line {index} about Ren"), claim.text.clone()));
    }
    fields
}

#[test]
fn the_private_names_list_lives_outside_the_repository_and_never_says_a_name() {
    let dir = tempfile::tempdir().unwrap();
    assert!(
        private_names_at(&dir.path().join("none.txt")).is_empty(),
        "no file, no names: the check passes where there is no list"
    );
    let list = dir.path().join("private-names.txt");
    std::fs::write(
        &list,
        "# made up for this test\n\nZebulon\n  Quillfeather Works \n",
    )
    .unwrap();
    let names = private_names_at(&list);
    assert_eq!(names, ["zebulon", "quillfeather works"]);
    let fields = vec![
        (
            "moment 0's title".to_owned(),
            "Zebulonia - Google Docs".to_owned(),
        ),
        (
            "moment 1's caption".to_owned(),
            "Writing to QUILLFEATHER works".to_owned(),
        ),
        (
            "moment 2's text".to_owned(),
            "Lunch with zebulon".to_owned(),
        ),
    ];
    // A whole word or the words in a row; the place, never the name.
    assert_eq!(
        place_of_a_private_name(&fields, &names),
        Some("moment 1's caption")
    );
    assert_eq!(place_of_a_private_name(&fields[..1], &names), None);
    let wrapped = [(
        "moment 3's text".to_owned(),
        "Quillfeather\nworks".to_owned(),
    )];
    assert_eq!(
        place_of_a_private_name(&wrapped, &names),
        Some("moment 3's text")
    );
    assert!(PRIVATE_NAMES_FILE.starts_with(".config/"));
}

#[test]
fn the_world_is_made_up() {
    let week = world(MONDAY_AFTERNOON, TZ);
    let fields = every_field(&week);
    // The project's folder is inside Demo Memory's own folder, so Resume
    // has a real folder to reopen: the one place the product's name shows.
    let corpus = fields
        .iter()
        .map(|(_, text)| text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .replace(PROJECT_FOLDER, "pebblewick-app");
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
    // Names from the maintainers' own lives, from the list outside the
    // repository where there is one. A failure says where, never the name.
    if let Some(place) = place_of_a_private_name(&fields, &private_names()) {
        panic!("a private name is in {place}");
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
    if title.ends_with("\u{2014} pebblewick-app")
        || title.starts_with("pebblewick-app \u{2014}")
        || title.starts_with(&format!("{PROJECT_FOLDER} \u{2014}"))
    {
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
    } else if title == "Waitlist launch plan" {
        Some("Waitlist launch plan")
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
    // Minutes in front this week (the last seven days of use, each of the
    // week's days) and in all, as Working On counts them.
    let mut this_week: BTreeMap<&str, u64> = BTreeMap::new();
    let mut in_all: BTreeMap<&str, u64> = BTreeMap::new();
    for day in &week.days {
        for session in &day.sessions {
            let mut at = session.start_us;
            for hold in &session.holds {
                let held = hold.minutes.min(now.saturating_sub(at) / MIN);
                if let Some(item) = item_of(&hold.win) {
                    *in_all.entry(item).or_default() += held;
                    *this_week.entry(item).or_default() += if day.back <= 6 { held } else { 0 };
                }
                at += hold.minutes * MIN;
            }
        }
    }
    let mut ranked: Vec<(&str, u64)> = this_week.into_iter().collect();
    ranked.sort_by_key(|(_, minutes)| std::cmp::Reverse(*minutes));
    let names: Vec<&str> = ranked.iter().map(|(name, _)| *name).collect();
    let when = Local::of(now, TZ).long_date();
    assert_eq!(
        names,
        [
            "pebblewick-app",
            "Q4 investor update",
            "2027 budget",
            "Pricing page v2",
            "October changelog",
            "Hiring plan",
            "Waitlist launch plan"
        ],
        "{when} {ranked:?}"
    );
    assert!(
        ranked[..5].iter().all(|(_, m)| *m >= 30),
        "the five in the sidebar each have 30 minutes or more: {ranked:?}"
    );
    // The hiring plan is too short to be an item; last week's waitlist plan
    // is one, with nothing this week, so Show All lists it under Earlier.
    assert!(in_all["Hiring plan"] < 30, "{when} {in_all:?}");
    assert!(in_all["Waitlist launch plan"] >= 30, "{when} {in_all:?}");
    assert_eq!(ranked[6], ("Waitlist launch plan", 0), "{when}");
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

#[test]
fn the_terminal_shows_the_project_folder_demo_memory_makes() {
    // Demo Memory's folder, as the app makes it (`DemoMemoryFolder.standard`),
    // holds the project's folder, and a Terminal window names it, so Resume
    // finds a folder to reopen instead of "doesn't know where it is".
    assert_eq!(
        PROJECT_FOLDER,
        "~/Library/Application Support/Hippocampus/Demo Memory/pebblewick-app"
    );
    for now in [MONDAY_AFTERNOON, at_local(MONDAY_AFTERNOON, 21, 30)] {
        let week = world(now, TZ);
        let today = day_start(now, TZ, 0);
        let mut named_before_today = false;
        for (ts, win, _) in week.moments() {
            if win.app != "com.apple.Terminal" {
                continue;
            }
            let folder = mci_brain::subject::terminal_folder_at(&win.title, Some("sam"))
                .expect("the title names a folder");
            assert_eq!(folder.name, "pebblewick-app", "{}", win.title);
            if let Some(path) = folder.path.as_deref() {
                assert_eq!(path, PROJECT_FOLDER, "one folder, everywhere");
                assert!(ts < today, "today's windows keep Terminal's own title");
                named_before_today = true;
            }
            assert!(
                !win.main.contains("/Users/"),
                "no other folder: {}",
                win.main
            );
        }
        assert!(
            named_before_today,
            "a window the agent reads names the folder"
        );
    }
}

#[test]
fn the_project_folder_is_made_only_inside_demo_memorys_own_folder() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let demo = home
        .path()
        .join("Library/Application Support/Hippocampus/Demo Memory");
    std::fs::create_dir_all(&demo).unwrap();
    let made = make_project_folder(&demo, home.path()).unwrap();
    let project = demo.join("pebblewick-app");
    assert_eq!(made.as_deref(), Some(project.as_path()));
    assert!(project.is_dir());
    assert_eq!(
        std::fs::metadata(&project).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(std::fs::read_dir(&project).unwrap().count(), 0, "empty");
    // Again: the folder is kept as it is.
    assert_eq!(
        make_project_folder(&demo, home.path()).unwrap().as_deref(),
        Some(project.as_path())
    );

    // A store anywhere else makes nothing, in the home folder or beside it.
    let elsewhere = tempfile::tempdir().unwrap();
    let other_home = tempfile::tempdir().unwrap();
    assert_eq!(
        make_project_folder(elsewhere.path(), other_home.path()).unwrap(),
        None
    );
    assert_eq!(
        std::fs::read_dir(other_home.path()).unwrap().count(),
        0,
        "nothing made in a home whose Demo Memory isn't the store's folder"
    );
    assert_eq!(std::fs::read_dir(elsewhere.path()).unwrap().count(), 0);

    // Something that isn't a folder at its place is never touched.
    let third = tempfile::tempdir().unwrap();
    let demo = third
        .path()
        .join("Library/Application Support/Hippocampus/Demo Memory");
    std::fs::create_dir_all(&demo).unwrap();
    std::fs::write(demo.join("pebblewick-app"), b"kept").unwrap();
    assert!(make_project_folder(&demo, third.path()).is_err());
    assert_eq!(std::fs::read(demo.join("pebblewick-app")).unwrap(), b"kept");
}

#[test]
fn the_code_moments_read_the_part_of_the_file_on_screen() {
    // History's rows lead with what each moment read: billing.ts reads
    // differently as the day moves through the file.
    let week = world(at_local(MONDAY_AFTERNOON, 21, 30), TZ);
    let mut first_lines: HashMap<String, String> = HashMap::new();
    for (_, win, _) in week.moments() {
        if win.app != "com.microsoft.VSCode" {
            continue;
        }
        let screen = win.screen.as_ref().unwrap();
        assert!(
            win.main.lines().count() <= 36,
            "{} fits the window",
            screen.id
        );
        let first = screen.meta["first_line"].as_u64().unwrap();
        let cursor = screen.meta["cursor_line"].as_u64().unwrap();
        let shown = u64::try_from(win.main.lines().count()).unwrap();
        assert!(
            first <= cursor && cursor < first + shown,
            "{}: the cursor is on screen",
            screen.id
        );
        assert!(
            win.rest.contains(&format!("Ln {cursor},")),
            "{}: the status bar says the cursor's line",
            screen.id
        );
        if win.title.starts_with("billing.ts ") {
            first_lines.insert(
                screen.id.clone(),
                win.main.lines().next().unwrap().to_owned(),
            );
        }
    }
    let distinct: HashSet<&String> = first_lines.values().collect();
    assert_eq!(first_lines.len(), 3, "{first_lines:?}");
    assert_eq!(
        distinct.len(),
        3,
        "each place in billing.ts reads differently"
    );
    assert_eq!(
        first_lines["code-billing-ts-credit"],
        "// The credit for the days left this month, in cents."
    );
}
