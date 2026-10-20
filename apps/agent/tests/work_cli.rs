//! `mci-agent work --json` (SPEC 3.12.2): the window's one read for Working
//! On and Web Pages. End to end through the binary for its shape, and in
//! process at a fixed "now" for what it says: membership at 30 minutes in
//! 14 days of use, days with nothing saved not counting, ranking, names that
//! look personal, deletes, paging an item's moments, which item a moment is
//! part of, files, Seen alongside, the folder guess and pages.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH, HOME and the development key gate.

#[path = "fixtures/work/mod.rs"]
mod fixture;

use std::path::{Path, PathBuf};
use std::process::Command;

use fixture::{
    coding, command, now_us, work, work_at, Memory, Window, CHROME, CLAUDE, DAY_US, FIGMA, HOUR_US,
    MINUTE_US, NOTES, NOW_US, NUMBERS, SAFARI, SLACK, TERMINAL, VS_CODE,
};
use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

const KEY: [u8; 32] = [0x5a; 32];

/// An empty memory, made the way the app makes one.
fn empty_memory(dir: &Path) -> PathBuf {
    let db = dir.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes(KEY)).expect("make the memory"));
    db
}

fn json(command: &mut Command) -> serde_json::Value {
    let output = command.output().expect("spawn mci-agent");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    serde_json::from_str(&text).expect("valid JSON")
}

fn assert_work_shape(value: &serde_json::Value) {
    assert!(value["generated_us"].as_u64().unwrap() > 0);
    assert!(value["items"].is_array());
    assert!(value["pages"].is_array());
    assert!(value["moment_items"].is_object());
}

fn names(value: &serde_json::Value) -> Vec<String> {
    value["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["name"].as_str().unwrap().to_owned())
        .collect()
}

fn item<'a>(value: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    value["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == name)
        .unwrap_or_else(|| panic!("no item {name} in {value}"))
}

/// The start of a day `days` before the fixtures' Monday, at `hour` local.
fn at(days: u64, hour: u64) -> u64 {
    // NOW_US is 2:41 PM local; 9 AM is 5 h 41 min before it.
    let nine = NOW_US - 5 * HOUR_US - 41 * MINUTE_US;
    nine - days * DAY_US + hour.saturating_sub(9) * HOUR_US
}

// ---------------------------------------------------------------------------
// The answer's shape, end to end
// ---------------------------------------------------------------------------

#[test]
fn work_answers_in_the_shape_the_window_reads() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let value = json(
        command(dir.path())
            .arg("work")
            .arg("--json")
            .arg("--db-path")
            .arg(&db),
    );
    assert_work_shape(&value);
    assert_eq!(value["items"], serde_json::json!([]));
    assert_eq!(value["pages"], serde_json::json!([]));
    assert_eq!(value["moment_items"], serde_json::json!({}));
}

#[test]
fn one_item_and_moment_lookups_answer_in_the_same_shape() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for extra in [
        &["--item", "w_9c41e2"][..],
        &["--item", "w_9c41e2", "--before", "1760304000000000"][..],
        &["--moments", "4812,4790"][..],
        &["--days", "14"][..],
        &["--some-future-flag"][..],
    ] {
        let value = json(
            command(dir.path())
                .arg("work")
                .args(extra)
                .arg("--json")
                .arg("--db-path")
                .arg(&db),
        );
        assert_work_shape(&value);
    }
}

#[test]
fn a_bad_flag_value_fails_without_repeating_it() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for (flag, value) in [
        ("--days", "private-words"),
        ("--item", "private words"),
        ("--moments", "1,private-words"),
    ] {
        let output = command(dir.path())
            .args(["work", "--json", flag, value, "--db-path"])
            .arg(&db)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{flag}");
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(flag), "{stderr}");
        assert!(!stderr.contains("private"), "{stderr}");
    }
}

#[test]
fn a_memory_that_cannot_be_opened_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("missing.sqlite");
    let output = command(dir.path())
        .args(["work", "--json", "--db-path"])
        .arg(&missing)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!missing.exists(), "a read never makes a memory");
}

#[test]
fn without_json_it_is_the_same_answer_indented() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let output = command(dir.path())
        .args(["work", "--db-path"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.trim_end().lines().count() > 1);
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_work_shape(&value);
}

#[test]
fn a_real_memory_reads_end_to_end_with_ids_never_names_in_links() {
    let memory = Memory::new();
    let now = now_us();
    memory.session(now - 3 * HOUR_US, &coding(40));
    let value = fixture::read(&memory, &["work"]);
    assert_work_shape(&value);
    let found = item(&value, "trailhead-shop");
    let id = found["id"].as_str().unwrap();
    assert!(id.starts_with("w_") && id.len() == 22, "{id}");
    assert!(!id.contains("trailhead"));
    assert_eq!(found["kind"], "code");
    // The same id on the next read: links and hides stay true.
    let again = fixture::read(&memory, &["work"]);
    assert_eq!(item(&again, "trailhead-shop")["id"], id);
    let one = fixture::read(&memory, &["work", "--item", id]);
    assert_eq!(names(&one), vec!["trailhead-shop"]);
}

// ---------------------------------------------------------------------------
// Membership and ranking
// ---------------------------------------------------------------------------

#[test]
fn an_item_is_made_at_thirty_minutes_in_front_in_all() {
    let memory = Memory::new();
    memory.session(at(0, 9), &[Window::new(NUMBERS, "October invoices", 25)]);
    memory.session(
        at(0, 10),
        &[Window::new(
            FIGMA,
            "Trailhead pricing v3 \u{2013} Figma",
            20,
        )],
    );
    memory.session(
        at(1, 10),
        &[Window::new(
            FIGMA,
            "Trailhead pricing v3 \u{2013} Figma",
            15,
        )],
    );
    let value = work(&memory, &[]);
    assert_eq!(
        names(&value),
        vec!["Trailhead pricing v3"],
        "25 minutes is not enough; 20 and 15 are"
    );
    let found = item(&value, "Trailhead pricing v3");
    assert_eq!(found["kind"], "design");
    assert_eq!(found["week_minutes"], 35);
    assert_eq!(found["days_this_week"], 2);
    assert_eq!(found["in_sidebar"], true);
    assert_eq!(found["apps"], serde_json::json!([FIGMA]));
    assert_eq!(found["hosts"], serde_json::json!([]));
}

#[test]
fn a_document_on_the_web_names_its_site() {
    let memory = Memory::new();
    memory.session(
        at(0, 10),
        &[Window::page(
            CHROME,
            "Q4 planning - Google Docs",
            "https://docs.google.com/document/d/abc/edit",
            35,
        )],
    );
    let value = work(&memory, &[]);
    let found = item(&value, "Q4 planning");
    assert_eq!(found["kind"], "document");
    assert_eq!(found["apps"], serde_json::json!([CHROME]));
    assert_eq!(found["hosts"], serde_json::json!(["docs.google.com"]));
}

#[test]
fn days_with_nothing_saved_dont_count_toward_two_weeks() {
    let memory = Memory::new();
    // Thirty days ago, then a month with only thirteen days of use: the
    // item is still within the last 14 days of use.
    memory.session(at(30, 10), &[Window::new(NUMBERS, "October invoices", 40)]);
    for day in 0..13 {
        memory.session(at(day, 9), &[Window::new(SAFARI, "Something to read", 5)]);
    }
    let value = work(&memory, &[]);
    assert_eq!(item(&value, "October invoices")["in_sidebar"], true);
    // One more day of use, and it has had 14 without it.
    memory.session(at(13, 9), &[Window::new(SAFARI, "Something to read", 5)]);
    let value = work(&memory, &[]);
    let found = item(&value, "October invoices");
    assert_eq!(found["in_sidebar"], false, "it leaves the sidebar");
    assert_eq!(found["week_minutes"], 0);
    assert_eq!(
        found["total_minutes"], 40,
        "and stays on the Working On page"
    );
}

#[test]
fn items_rank_by_time_in_the_last_seven_days_of_use_then_the_newest() {
    let memory = Memory::new();
    memory.session(at(2, 10), &[Window::new(FIGMA, "Trailhead pricing v3", 60)]);
    memory.session(at(3, 10), &[Window::new(NUMBERS, "October invoices", 90)]);
    memory.session(
        at(0, 10),
        &[Window::new(
            "com.apple.iWork.Pages",
            "Q4 planning.pages",
            60,
        )],
    );
    // Ten days of use ago: outside the week, inside the fortnight.
    for day in 4..12 {
        memory.session(at(day, 9), &[Window::new(SAFARI, "Something to read", 5)]);
    }
    memory.session(
        at(12, 10),
        &[Window::new(NOTES, "Notes", 120).with_text("Launch checklist\nRounding fix merged")],
    );
    let value = work(&memory, &[]);
    assert_eq!(
        names(&value),
        vec![
            "October invoices",
            "Q4 planning",
            "Trailhead pricing v3",
            "Launch checklist"
        ],
        "most time this week first, a tie to the newest, then the rest"
    );
    assert_eq!(item(&value, "Launch checklist")["week_minutes"], 0);
    assert_eq!(item(&value, "Launch checklist")["in_sidebar"], true);
}

#[test]
fn notes_items_are_named_by_their_first_line() {
    let memory = Memory::new();
    memory.session(
        at(0, 10),
        &[Window::new(NOTES, "Notes", 35)
            .with_text("Launch checklist\nRounding fix merged\nChangelog updated")],
    );
    memory.session(
        at(0, 11),
        &[Window::new(NOTES, "Notes", 10).with_text("New Note")],
    );
    let value = work(&memory, &[]);
    assert_eq!(names(&value), vec!["Launch checklist"]);
    assert_eq!(item(&value, "Launch checklist")["kind"], "document");
}

#[test]
fn a_name_that_looks_personal_stays_out_of_the_sidebar() {
    let memory = Memory::new();
    memory.session(at(0, 10), &[Window::new(NUMBERS, "Mortgage refinance", 45)]);
    let value = work(&memory, &[]);
    let found = item(&value, "Mortgage refinance");
    assert_eq!(found["in_sidebar"], false);
    assert_eq!(found["hidden_reason"], "personal");
}

#[test]
fn an_ai_tools_own_terminal_never_names_an_item() {
    let memory = Memory::new();
    memory.session(
        at(0, 10),
        &[
            Window::new(TERMINAL, "\u{2733} Claude Code", 40),
            Window::new(
                TERMINAL,
                "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{00d7}40",
                40,
            ),
            Window::new(TERMINAL, "codex", 40),
        ],
    );
    assert_eq!(names(&work(&memory, &[])), Vec::<String>::new());
}

#[test]
fn an_editor_and_its_terminal_are_one_project() {
    let memory = Memory::new();
    memory.session(
        at(0, 10),
        &[
            Window::new(
                VS_CODE,
                "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                20,
            ),
            Window::new("com.mitchellh.ghostty", "~/dev/trailhead-shop/apps/web", 15),
            Window::new("dev.warp.Warp-Stable", "trailhead-shop", 5),
        ],
    );
    let value = work(&memory, &[]);
    assert_eq!(names(&value), vec!["trailhead-shop"]);
    let found = item(&value, "trailhead-shop");
    assert_eq!(
        found["week_minutes"], 40,
        "the editor's, the folder inside it, and the bare name it uses"
    );
    assert_eq!(found["apps"][0], VS_CODE);
}

#[test]
fn the_session_running_now_counts_before_its_note() {
    let memory = Memory::new();
    memory.session(at(0, 9), &[Window::new(FIGMA, "Trailhead pricing v3", 20)]);
    memory.unnoted(
        NOW_US - 40 * MINUTE_US,
        &[Window::new(FIGMA, "Trailhead pricing v3", 15).with_moments(10)],
    );
    let value = work(&memory, &[]);
    // Without its note, the running session lasts to its newest moment.
    let minutes = item(&value, "Trailhead pricing v3")["week_minutes"]
        .as_u64()
        .unwrap();
    assert!((33..=35).contains(&minutes), "{minutes}");
}

#[test]
fn forgetting_an_items_last_moment_removes_it_on_the_next_read() {
    let memory = Memory::new();
    let ids = memory.session(at(0, 10), &[Window::new(NUMBERS, "October invoices", 45)]);
    assert_eq!(names(&work(&memory, &[])), vec!["October invoices"]);
    // Forgetting a moment forgets its session's note: the item rebuilds
    // from what is left, without the moment.
    memory.forget(ids[0][0]);
    let value = work(&memory, &[]);
    let moments = item(&value, "October invoices")["moments"]
        .as_array()
        .unwrap()
        .clone();
    assert!(!moments.contains(&serde_json::json!(ids[0][0])));
    for id in &ids[0][1..] {
        memory.forget(*id);
    }
    assert_eq!(
        names(&work(&memory, &[])),
        Vec::<String>::new(),
        "nothing of it is left"
    );
}

// ---------------------------------------------------------------------------
// One item: thumbnail, files, Seen alongside, conversations, folder
// ---------------------------------------------------------------------------

#[test]
fn an_item_carries_its_thumbnail_files_and_folder() {
    let memory = Memory::new();
    let ids = memory.session(
        at(0, 10),
        &[
            Window::new(
                VS_CODE,
                "cart.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                10,
            ),
            Window::new("com.mitchellh.ghostty", "~/dev/trailhead-shop", 10),
            Window::new(
                VS_CODE,
                "\u{25cf} tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                20,
            )
            .with_screenshot(),
            Window::new(
                VS_CODE,
                "Untitled-1 \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                2,
            ),
        ],
    );
    let value = work(&memory, &[]);
    let found = item(&value, "trailhead-shop");
    let files: Vec<&str> = found["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        files,
        vec!["tax.rs", "cart.rs"],
        "newest first; an unsaved file is none"
    );
    assert_eq!(found["files"][0]["moment"], *ids[2].last().unwrap());
    assert_eq!(
        found["thumbnail_moment"],
        *ids[2].last().unwrap(),
        "the newest moment that kept a screenshot"
    );
    assert_eq!(found["folder_guess"], "~/dev/trailhead-shop");
    let moments = found["moments"].as_array().unwrap();
    assert_eq!(moments[0], *ids[3].last().unwrap(), "newest first");
}

#[test]
fn a_document_without_a_screenshot_has_no_thumbnail() {
    let memory = Memory::new();
    memory.session(at(0, 10), &[Window::new(NUMBERS, "October invoices", 40)]);
    let value = work(&memory, &[]);
    let found = item(&value, "October invoices");
    assert_eq!(found["thumbnail_moment"], serde_json::Value::Null);
    assert_eq!(found["folder_guess"], serde_json::Value::Null);
    assert_eq!(found["files"], serde_json::json!([]));
}

#[test]
#[allow(clippy::too_many_lines)] // one memory and everything it should and shouldn't list
fn seen_alongside_ranks_by_lift_and_leaves_out_what_is_open_beside_everything() {
    let memory = Memory::new();
    let calendar = || {
        Window::page(
            CHROME,
            "Northwind \u{00b7} Week of October 12",
            "https://plans.example/week",
            1,
        )
    };
    let rounding = || {
        Window::page(
            CHROME,
            "Rounding half to even \u{00b7} Dev Notes",
            "https://devnotes.example/rounding?ref=x",
            4,
        )
    };
    let search = || {
        Window::page(
            CHROME,
            "rust round half to even - Google Search",
            "https://www.google.com/search?q=rust+round+half+to+even",
            1,
        )
    };
    let chat = || Window::new(CLAUDE, "Rounding modes for money", 4);
    let slack = || Window::new(SLACK, "launch (Channel) - Northwind Studio - Slack", 3);
    // The project's sessions, with what was read beside it.
    for day in 0..3 {
        memory.session(
            at(day, 10),
            &[
                coding(30)[0].clone(),
                rounding(),
                search(),
                chat(),
                slack(),
                calendar(),
            ],
        );
    }
    // Twelve other sessions with only the calendar open: it is open beside
    // everything.
    for day in 3..12 {
        memory.session(
            at(day, 9),
            &[Window::new(SAFARI, "Something else to read", 5), calendar()],
        );
        memory.session(
            at(day, 15),
            &[Window::new(SAFARI, "Something else again", 5)],
        );
    }
    let value = work(&memory, &[]);
    let found = item(&value, "trailhead-shop");
    let alongside: Vec<(String, String)> = found["alongside"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            (
                a["kind"].as_str().unwrap().to_owned(),
                a["title"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert!(
        alongside.contains(&("page".into(), "Rounding half to even".into())),
        "{alongside:?}"
    );
    assert!(
        alongside.contains(&("search".into(), "rust round half to even".into())),
        "{alongside:?}"
    );
    assert!(
        alongside
            .iter()
            .any(|(kind, title)| kind == "ai_chat" && title.contains("Rounding modes")),
        "{alongside:?}"
    );
    assert!(
        !alongside
            .iter()
            .any(|(_, title)| title.contains("Northwind")),
        "open beside everything: {alongside:?}"
    );
    assert!(
        !alongside.iter().any(|(_, title)| title.contains("launch")),
        "never a chat with people"
    );
    let page = found["alongside"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["kind"] == "page")
        .unwrap();
    assert_eq!(page["host"], "devnotes.example");
    assert_eq!(page["app"], CHROME);
    let conversations: Vec<&str> = found["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert_eq!(conversations, vec!["#launch"], "by name only");
}

#[test]
fn seen_alongside_keeps_at_most_two_pages_a_site_and_six_rows() {
    let memory = Memory::new();
    let mut windows = vec![coding(40)[0].clone()];
    for n in 0..5 {
        windows.push(Window::page(
            CHROME,
            &format!("Chapter {n} of the money guide \u{00b7} Dev Notes"),
            &format!("https://devnotes.example/money/{n}"),
            2,
        ));
    }
    for n in 0..6 {
        windows.push(Window::page(
            CHROME,
            &format!("Reading list entry number {n}"),
            &format!("https://site{n}.example/"),
            2,
        ));
    }
    memory.session(at(0, 10), &windows);
    let value = work(&memory, &[]);
    let alongside = item(&value, "trailhead-shop")["alongside"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(alongside.len(), 6);
    let dev_notes = alongside
        .iter()
        .filter(|a| a["host"] == "devnotes.example")
        .count();
    assert!(dev_notes <= 2, "{alongside:?}");
}

// ---------------------------------------------------------------------------
// One item's moments, page by page, and which item a moment is part of
// ---------------------------------------------------------------------------

#[test]
fn one_items_moments_come_two_hundred_at_a_time() {
    let memory = Memory::new();
    let ids = memory.session(
        at(0, 10),
        &[Window::new(NUMBERS, "October invoices", 40).with_moments(450)],
    );
    let value = work(&memory, &[]);
    let id = item(&value, "October invoices")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let first = work(&memory, &["--item", &id]);
    let page: Vec<i64> = first["items"][0]["moments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_i64().unwrap())
        .collect();
    assert_eq!(page.len(), 200);
    let mut newest_first = ids[0].clone();
    newest_first.reverse();
    assert_eq!(page, newest_first[..200].to_vec());
    assert_eq!(first["items"][0]["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(
        first["pages"],
        serde_json::json!([]),
        "one item, nothing else"
    );
    // The next page: older than the oldest shown.
    let oldest = memory.store.event_heads(&[*page.last().unwrap()]).unwrap()[0].ts_us;
    let second = work(&memory, &["--item", &id, "--before", &oldest.to_string()]);
    let next: Vec<i64> = second["items"][0]["moments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_i64().unwrap())
        .collect();
    assert_eq!(next, newest_first[200..400].to_vec());
    let unknown = work(&memory, &["--item", "w_0000000000"]);
    assert_eq!(unknown["items"], serde_json::json!([]));
}

#[test]
fn a_moment_is_part_of_its_own_item_or_its_sessions() {
    let memory = Memory::new();
    let ids = memory.session(
        at(0, 10),
        &[
            coding(40)[0].clone(),
            Window::page(
                CHROME,
                "Rounding half to even \u{00b7} Dev Notes",
                "https://devnotes.example/rounding",
                4,
            ),
            Window::new(SLACK, "launch (Channel) - Northwind Studio - Slack", 3),
        ],
    );
    let value = work(&memory, &[]);
    let id = item(&value, "trailhead-shop")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let asked = format!("{},{},{},999999", ids[0][0], ids[1][0], ids[2][0]);
    let lookup = work(&memory, &["--moments", &asked]);
    let map = lookup["moment_items"].as_object().unwrap();
    assert_eq!(
        map.get(&ids[0][0].to_string()).and_then(|v| v.as_str()),
        Some(id.as_str())
    );
    assert_eq!(
        map.get(&ids[1][0].to_string()).and_then(|v| v.as_str()),
        Some(id.as_str()),
        "a page read in its session"
    );
    assert!(
        map.get(&ids[2][0].to_string()).is_none(),
        "never a chat with people"
    );
    assert!(map.get("999999").is_none());
    assert_eq!(lookup["items"], serde_json::json!([]));
}

// ---------------------------------------------------------------------------
// Web Pages
// ---------------------------------------------------------------------------

#[test]
fn pages_are_one_row_per_address_across_days_newest_first() {
    let memory = Memory::new();
    memory.session(
        at(2, 10),
        &[Window::page(
            CHROME,
            "Rounding half to even \u{00b7} Dev Notes",
            "https://devnotes.example/rounding?utm=a",
            3,
        )],
    );
    memory.session(
        at(0, 11),
        &[
            Window::page(
                SAFARI,
                "Rounding half to even \u{00b7} Dev Notes",
                "https://www.devnotes.example/rounding#top",
                3,
            ),
            Window::page(
                CHROME,
                "per seat vs tiered pricing - Google Search",
                "https://www.google.com/search?q=per+seat",
                1,
            ),
            Window::page(
                CHROME,
                "Q4 planning - Google Docs",
                "https://docs.google.com/document/d/abc/edit",
                5,
            ),
            Window::page(
                CHROME,
                "Inbox (3) - sam@trailhead.example - Gmail",
                "https://mail.google.com/mail/u/0/#inbox",
                2,
            ),
            Window::new(SAFARI, "Plans and pricing \u{00b7} Spoke & Chain", 2),
        ],
    );
    let value = work(&memory, &[]);
    let pages = value["pages"].as_array().unwrap();
    let titles: Vec<&str> = pages.iter().map(|p| p["title"].as_str().unwrap()).collect();
    assert_eq!(
        titles,
        vec![
            "Plans and pricing \u{00b7} Spoke & Chain",
            "Rounding half to even"
        ]
    );
    let rounding = &pages[1];
    assert_eq!(rounding["host"], "devnotes.example");
    assert_eq!(rounding["path"], "/rounding", "never the query or fragment");
    assert_eq!(rounding["days"], 2);
    assert_eq!(rounding["app"], SAFARI, "the browser it was last read in");
    assert_eq!(rounding["moments"].as_array().unwrap().len(), 6);
    let spoke = &pages[0];
    assert_eq!(
        spoke["path"],
        serde_json::Value::Null,
        "no address: its title and browser"
    );
    assert_eq!(spoke["app"], SAFARI);
}

// ---------------------------------------------------------------------------
// Budget
// ---------------------------------------------------------------------------

/// Ninety days of a full working life: the read stays quick. The budget in
/// SPEC 8.2 is 300 ms for a release build; a debug build gets more room.
#[test]
fn ninety_days_read_quickly() {
    let memory = Memory::new();
    let pages = [
        (
            "Rounding half to even \u{00b7} Dev Notes",
            "https://devnotes.example/rounding",
        ),
        (
            "Seat-based pricing: the pros and cons",
            "https://saasguide.example/pricing/seats",
        ),
        (
            "Per-seat or tiered? How to price a team plan",
            "https://pricingnotes.example/team-plans",
        ),
    ];
    for day in 0..90 {
        for (session, hour) in [9u64, 10, 11, 13, 14, 15, 16].iter().enumerate() {
            let page = pages[(usize::try_from(day).unwrap() + session) % pages.len()];
            memory.session(
                at(day, *hour),
                &[
                    Window::new(
                        VS_CODE,
                        "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                        20,
                    )
                    .with_moments(40),
                    Window::page(CHROME, page.0, page.1, 5).with_moments(10),
                    Window::new(FIGMA, "Trailhead pricing v3", 5).with_moments(10),
                ],
            );
        }
    }
    let started = std::time::Instant::now();
    let value = work_at(&memory, &[], NOW_US);
    let took = started.elapsed();
    assert_eq!(
        names(&value),
        vec!["trailhead-shop", "Trailhead pricing v3"]
    );
    let budget = if cfg!(debug_assertions) { 4_000 } else { 300 };
    mci_agent::errln!("work read over 90 days: {} ms", took.as_millis());
    assert!(took.as_millis() < budget, "{} ms", took.as_millis());
}
