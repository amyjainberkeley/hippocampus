//! `mci-agent resume-plan --item <id> --json` (SPEC-DELTA 3): what the
//! Resume sheet lists for one Working On item, from its last session, in
//! the shape the window decodes. It opens nothing and sends nothing.
//!
//! End to end through the binary for its shape; in process at a fixed
//! "now" over made-up sessions for every kind of target and edge: the code
//! folder in its editor and a terminal, a folder that is gone or unknown,
//! web pages capped at ten ticked, pages without an address, documents
//! through their links or their apps, other apps, calls and searches never
//! offered, only the last session, and forgotten moments left out.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH, HOME and the development key gate.

#[path = "fixtures/work/mod.rs"]
mod fixture;

use std::path::{Path, PathBuf};

use fixture::{
    command, now_us, work, Memory, Window, CHROME, CLAUDE, FIGMA, HOUR_US, MINUTE_US, NOTES,
    NOW_US, NUMBERS, SAFARI, SLACK, TERMINAL, TZ, VS_CODE,
};
use mci_agent::understanding::resume::{plan, resume_url, PAGES_TICKED};
use mci_agent::understanding::work::Home;
use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

fn empty_memory(dir: &Path) -> PathBuf {
    let db = dir.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes([0x5a; 32])).expect("make the memory"));
    db
}

/// The plan for the item named `name`, at the fixtures' "now".
fn plan_for(memory: &Memory, name: &str) -> serde_json::Value {
    let value = work(memory, &[]);
    let id = value["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == name)
        .unwrap_or_else(|| panic!("no item {name}"))["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let home = Home::at(memory.dir.to_str().unwrap());
    serde_json::to_value(
        plan(
            &memory.store,
            &DbKey::from_bytes(fixture::KEY),
            &id,
            TZ,
            NOW_US,
            &home,
        )
        .unwrap(),
    )
    .unwrap()
}

fn targets(plan: &serde_json::Value) -> Vec<serde_json::Value> {
    plan["items"].as_array().unwrap().clone()
}

fn titles(plan: &serde_json::Value, kind: &str) -> Vec<String> {
    targets(plan)
        .iter()
        .filter(|t| t["kind"] == kind)
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

/// Ten in the morning today, in the fixtures' time zone.
fn morning() -> u64 {
    NOW_US - 4 * HOUR_US - 41 * MINUTE_US
}

#[test]
fn a_plan_lists_what_resume_would_open() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let output = command(dir.path())
        .args(["resume-plan", "--item", "w_9c41e2", "--json", "--db-path"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        value,
        serde_json::json!({"items": []}),
        "an unknown item has nothing to open"
    );
}

#[test]
fn a_plan_needs_an_items_id() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for extra in [&[][..], &["--item"][..], &["--item", "trailhead shop"][..]] {
        let output = command(dir.path())
            .arg("resume-plan")
            .args(extra)
            .args(["--json", "--db-path"])
            .arg(&db)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{extra:?}");
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("--item"), "{stderr}");
        assert!(!stderr.contains("trailhead"), "{stderr}");
    }
}

#[test]
fn a_real_plan_reads_end_to_end() {
    let memory = Memory::new();
    std::fs::create_dir_all(memory.dir.join("dev/trailhead-shop")).unwrap();
    let now = now_us();
    memory.session(
        now - 2 * HOUR_US,
        &[
            Window::new(
                VS_CODE,
                "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                30,
            ),
            Window::new("com.mitchellh.ghostty", "~/dev/trailhead-shop", 10),
        ],
    );
    let work = fixture::read(&memory, &["work"]);
    let id = work["items"][0]["id"].as_str().unwrap().to_owned();
    let value = fixture::read(&memory, &["resume-plan", "--item", &id]);
    assert_eq!(value["item"]["name"], "trailhead-shop");
    assert_eq!(value["item"]["kind"], "code");
    let folder = &value["items"][0];
    assert_eq!(folder["kind"], "folder");
    assert_eq!(folder["app"], VS_CODE);
    assert_eq!(folder["path"], "~/dev/trailhead-shop");
    assert_eq!(folder["checked"], true);
}

#[test]
fn a_code_project_opens_its_folder_in_its_editor_and_terminal() {
    let memory = Memory::new();
    std::fs::create_dir_all(memory.dir.join("dev/trailhead-shop")).unwrap();
    memory.session(
        morning(),
        &[
            Window::new(
                VS_CODE,
                "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                30,
            ),
            Window::new("com.mitchellh.ghostty", "~/dev/trailhead-shop", 10),
            Window::new(SLACK, "launch (Channel) - Northwind Studio - Slack", 3),
        ],
    );
    let plan = plan_for(&memory, "trailhead-shop");
    let all = targets(&plan);
    assert_eq!(all[0]["kind"], "folder");
    assert_eq!(all[0]["app"], VS_CODE);
    assert_eq!(all[0]["title"], "trailhead-shop");
    assert_eq!(all[0]["path"], "~/dev/trailhead-shop");
    assert_eq!(all[1]["kind"], "folder");
    assert_eq!(
        all[1]["app"], "com.mitchellh.ghostty",
        "a terminal in that folder, the one used"
    );
    assert_eq!(titles(&plan, "app"), vec!["Slack"], "other apps in use");
    assert!(all.iter().all(|t| t["checked"] == true));
    assert!(all.iter().all(|t| t.get("reason").is_none()));
    assert!(plan["session"]["start_us"].as_u64().unwrap() >= morning());
}

#[test]
fn a_folder_that_is_gone_says_so_and_isnt_ticked() {
    let memory = Memory::new();
    memory.session(
        morning(),
        &[
            Window::new(
                VS_CODE,
                "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                30,
            ),
            Window::new("com.mitchellh.ghostty", "~/dev/trailhead-shop", 10),
        ],
    );
    let plan = plan_for(&memory, "trailhead-shop");
    let folder = &targets(&plan)[0];
    assert_eq!(folder["reason"], "missing");
    assert_eq!(folder["checked"], false);
    assert_eq!(folder["path"], "~/dev/trailhead-shop");
}

#[test]
fn without_a_folder_the_editor_opens_alone() {
    let memory = Memory::new();
    memory.session(
        morning(),
        &[
            Window::new(
                VS_CODE,
                "tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                30,
            ),
            Window::new(
                TERMINAL,
                "trailhead-shop \u{2014} -zsh \u{2014} 80\u{00d7}24",
                10,
            ),
        ],
    );
    let plan = plan_for(&memory, "trailhead-shop");
    let all = targets(&plan);
    assert_eq!(all[0]["kind"], "app");
    assert_eq!(all[0]["app"], VS_CODE);
    assert_eq!(all[0]["reason"], "no_folder");
    assert_eq!(all[0]["checked"], true, "the editor still opens");
    assert_eq!(all[0]["path"], serde_json::Value::Null);
    assert_eq!(all[1]["app"], TERMINAL);
}

#[test]
fn web_pages_open_newest_first_with_the_newest_ten_ticked() {
    let memory = Memory::new();
    let mut windows = vec![Window::new(FIGMA, "Trailhead pricing v3", 31)];
    for n in 0..12 {
        windows.push(Window::page(
            CHROME,
            &format!("Pricing page example number {n}"),
            &format!("https://pricing{n}.example/plans?ref=newsletter#top"),
            1,
        ));
    }
    windows.push(Window::page(
        CHROME,
        "per seat vs tiered pricing - Google Search",
        "https://www.google.com/search?q=per+seat+vs+tiered+pricing",
        1,
    ));
    windows.push(Window::new(SAFARI, "A page read without its address", 1));
    memory.session(morning(), &windows);
    let plan = plan_for(&memory, "Trailhead pricing v3");
    let pages: Vec<serde_json::Value> = targets(&plan)
        .into_iter()
        .filter(|t| t["kind"] == "page")
        .collect();
    assert_eq!(
        pages.len(),
        13,
        "twelve pages and one without an address; never the search"
    );
    assert_eq!(pages[0]["title"], "A page read without its address");
    assert_eq!(pages[0]["reason"], "no_address");
    assert_eq!(pages[0]["checked"], false);
    assert_eq!(
        pages[1]["title"], "Pricing page example number 11",
        "newest first"
    );
    assert_eq!(
        pages[1]["url"], "https://pricing11.example/plans",
        "never the query or fragment"
    );
    assert_eq!(pages[1]["app"], CHROME, "in the browser it was read in");
    let ticked = pages.iter().filter(|p| p["checked"] == true).count();
    assert_eq!(ticked, PAGES_TICKED);
    assert_eq!(
        pages.last().unwrap()["title"],
        "Pricing page example number 0"
    );
    assert_eq!(pages.last().unwrap()["checked"], false, "past the ten");
}

#[test]
fn documents_open_through_their_links_or_their_apps() {
    let memory = Memory::new();
    memory.session(
        morning(),
        &[
            Window::page(
                CHROME,
                "Q4 planning - Google Docs",
                "https://docs.google.com/document/d/abc123/edit?tab=t.0",
                31,
            ),
            Window::new(NOTES, "Notes", 5).with_text("Launch checklist\nRounding fix merged"),
            Window::new(NUMBERS, "October invoices", 5),
            Window::new(CLAUDE, "Rounding modes for money", 2),
        ],
    );
    let plan = plan_for(&memory, "Q4 planning");
    let docs: Vec<serde_json::Value> = targets(&plan)
        .into_iter()
        .filter(|t| t["kind"] == "document")
        .collect();
    assert_eq!(docs[0]["title"], "Q4 planning", "the item's own first");
    assert_eq!(
        docs[0]["url"],
        "https://docs.google.com/document/d/abc123/edit"
    );
    assert_eq!(docs[0]["app"], CHROME);
    let notes = docs
        .iter()
        .find(|d| d["title"] == "Launch checklist")
        .unwrap();
    assert_eq!(notes["reason"], "single_note");
    assert_eq!(notes["app"], NOTES);
    assert_eq!(notes["checked"], true, "Notes still opens");
    let numbers = docs
        .iter()
        .find(|d| d["title"] == "October invoices")
        .unwrap();
    assert_eq!(numbers["reason"], "app_only");
    assert_eq!(titles(&plan, "app"), vec!["Claude"]);
}

#[test]
fn calls_finder_and_brief_glances_are_never_offered() {
    let memory = Memory::new();
    memory.session(
        morning(),
        &[
            Window::new(NUMBERS, "October invoices", 31),
            Window::new("us.zoom.xos", "Zoom Meeting", 10),
            Window::new("com.apple.finder", "Downloads", 3),
            Window::new("com.apple.systempreferences", "Wi-Fi", 3),
            Window::new("com.apple.MobileSMS", "Sam Lee", 1).with_moments(1),
        ],
    );
    let plan = plan_for(&memory, "October invoices");
    assert_eq!(titles(&plan, "app"), vec!["Messages"]);
    let short = Memory::new();
    short.session(
        morning(),
        &[
            Window::new(NUMBERS, "October invoices", 31),
            Window {
                minutes: 0,
                ..Window::new("com.apple.MobileSMS", "Sam Lee", 1)
            },
        ],
    );
    assert!(titles(&plan_for(&short, "October invoices"), "app").len() <= 1);
}

#[test]
fn only_the_last_session_is_offered() {
    let memory = Memory::new();
    memory.session(
        morning() - 26 * HOUR_US,
        &[
            Window::new(NUMBERS, "October invoices", 31),
            Window::page(
                CHROME,
                "Yesterday's page about invoices",
                "https://old.example/page",
                2,
            ),
        ],
    );
    memory.session(
        morning(),
        &[
            Window::new(NUMBERS, "October invoices", 5),
            Window::page(
                CHROME,
                "Today's page about invoices",
                "https://new.example/page",
                2,
            ),
        ],
    );
    let plan = plan_for(&memory, "October invoices");
    assert_eq!(titles(&plan, "page"), vec!["Today's page about invoices"]);
}

#[test]
fn forgotten_moments_are_never_offered() {
    let memory = Memory::new();
    // Forgetting a moment forgets its session's note; the moments left are
    // read again as the worker reads moments it hasn't noted.
    let ids = memory.session(
        NOW_US - 3 * HOUR_US,
        &[
            Window::new(NUMBERS, "October invoices", 40),
            Window::page(CHROME, "A page to forget", "https://forget.example/page", 1),
            Window::page(CHROME, "A page to keep", "https://keep.example/page", 2),
        ],
    );
    for id in &ids[1] {
        memory.forget(*id);
    }
    let plan = plan_for(&memory, "October invoices");
    assert_eq!(titles(&plan, "page"), vec!["A page to keep"]);
}

#[test]
fn an_item_with_nothing_left_has_nothing_to_open() {
    let memory = Memory::new();
    let ids = memory.session(morning(), &[Window::new(NUMBERS, "October invoices", 31)]);
    let id = work(&memory, &[])["items"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for moment in &ids[0] {
        memory.forget(*moment);
    }
    let home = Home::at(memory.dir.to_str().unwrap());
    let empty = plan(
        &memory.store,
        &DbKey::from_bytes(fixture::KEY),
        &id,
        TZ,
        NOW_US,
        &home,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(empty).unwrap(),
        serde_json::json!({"items": []})
    );
}

#[test]
fn addresses_never_carry_a_query() {
    assert_eq!(
        resume_url("https://app.example/projects/42?session=abc#x").as_deref(),
        Some("https://app.example/projects/42")
    );
}
