//! Demo Memory's made-up week, end to end through the built binaries:
//! `mci-seed-brain --demo-week` writes it into a memory of its own, and
//! `mci-agent` reads it back in the shapes the window is built on (Today's
//! overview, the sessions, About You, Looked Up). Every child runs with an
//! explicitly built environment: no inherited keys, a temporary HOME, and
//! the development key gate. Nothing here opens a person's memory.

use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const KEY_HEX: &str = "3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c";
const SEEDER: &str = env!("CARGO_BIN_EXE_mci-seed-brain");
const AGENT: &str = env!("CARGO_BIN_EXE_mci-agent");

fn now_us() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap()
}

/// A whole-hour offset that puts now at 2 PM, so the week's afternoon is
/// under way: the session in progress is the one Today shows as Now.
fn afternoon_offset_secs() -> i64 {
    let hour = i64::try_from(now_us() / 3_600_000_000 % 24).unwrap();
    let mut offset = (14 - hour).rem_euclid(24);
    if offset > 14 {
        offset -= 24;
    }
    offset * 3600
}

fn command(binary: &str, home: &Path, tz: i64) -> Command {
    let mut command = Command::new(binary);
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", KEY_HEX)
        .env("MCI_BRIEF_TZ_OFFSET_SECONDS", tz.to_string())
        .env("MCI_UNDERSTANDING", "0")
        .stdin(Stdio::null());
    command
}

fn ok(output: &Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout.clone()).unwrap()
}

fn json(output: &Output) -> serde_json::Value {
    serde_json::from_str(ok(output).trim()).expect("one JSON value")
}

struct Seeded {
    _dir: tempfile::TempDir,
    home: PathBuf,
    db: PathBuf,
    tz: i64,
    summary: serde_json::Value,
}

fn seed(now: Option<u64>) -> Seeded {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.path().join("Demo Memory").join("mci.sqlite");
    let tz = afternoon_offset_secs();
    let mut seeder = command(SEEDER, &home, tz);
    seeder
        .arg("--demo-week")
        .arg("--db-path")
        .arg(&db)
        .arg("--tz-offset-secs")
        .arg(tz.to_string());
    if let Some(now) = now {
        seeder.arg("--now-us").arg(now.to_string());
    }
    let summary = json(&seeder.output().unwrap());
    Seeded {
        _dir: dir,
        home,
        db,
        tz,
        summary,
    }
}

fn receipt(db: &Path) {
    let ms = u128::from(now_us() / 1000);
    let stamp = mci_agent::wall_clock::format_unix_ms(ms);
    let receipt = serde_json::json!({ "schema_version": 1, "updated_at": stamp, "last_stored_frame_at": stamp,
        "stored_frame_count": 900, "stored_screenshot_count": 120, "suppression_reason": null, "blocked_reason": null });
    std::fs::write(
        db.with_file_name("capture-status.json"),
        receipt.to_string(),
    )
    .unwrap();
}

fn read(seeded: &Seeded, args: &[&str]) -> serde_json::Value {
    let tz = seeded.tz.to_string();
    json(
        &command(AGENT, &seeded.home, seeded.tz)
            .args(args)
            .args(["--tz-offset-secs", &tz, "--json", "--db-path"])
            .arg(&seeded.db)
            .output()
            .unwrap(),
    )
}

#[test]
fn the_screen_list_needs_no_key_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let output = Command::new(SEEDER)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.path())
        .args(["--demo-week", "--print-screens", "--tz-offset-secs", "0"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let list: serde_json::Value = serde_json::from_str(ok(&output).trim()).unwrap();
    assert_eq!(list["version"], 1);
    assert_eq!(list["tz_offset_secs"], 0);
    let screens = list["screens"].as_array().unwrap();
    assert!(screens.len() >= 15, "{}", screens.len());
    for screen in screens {
        for key in ["id", "template", "app", "title", "main", "rest", "meta"] {
            assert!(screen.get(key).is_some(), "{key}");
        }
    }
    assert_eq!(
        std::fs::read_dir(dir.path()).unwrap().count(),
        0,
        "nothing written"
    );
}

#[test]
fn the_week_reads_as_the_window_expects() {
    let seeded = seed(None);
    assert!(seeded.summary["moments"].as_u64().unwrap() > 600);
    assert!(
        seeded.summary["notes"].as_u64().unwrap() >= 30,
        "{}",
        seeded.summary
    );
    assert_eq!(seeded.summary["screenshots"], 0, "no screen list given");
    receipt(&seeded.db);

    let overview = read(&seeded, &["overview"]);
    assert_eq!(overview["is_today"], true);
    assert_eq!(overview["model_status"]["state"], "available");
    assert_eq!(
        overview["now"]["state"], "in_progress",
        "at 2 PM the week is under way: {}",
        overview["now"]
    );
    let blocks = overview["blocks"].as_array().unwrap();
    assert!(blocks.len() >= 9, "{}", blocks.len());
    let titles: Vec<&str> = blocks.iter().filter_map(|b| b["title"].as_str()).collect();
    assert!(titles.contains(&"Team sync"), "{titles:?}");
    assert!(titles.contains(&"Prorating yearly upgrades"), "{titles:?}");
    let searches: Vec<&str> = overview["searches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["query"].as_str().unwrap())
        .collect();
    assert!(
        searches.contains(&"stripe prorate monthly to yearly"),
        "{searches:?}"
    );
    assert!(overview["account"]["headline"]
        .as_str()
        .is_some_and(|h| h.contains("Q4 update")));
    // What a connected AI tool starts with: the confirmed line first.
    let about: Vec<&str> = overview["ai_knows"]["about_you"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line["text"].as_str().unwrap())
        .collect();
    assert_eq!(
        about.first(),
        Some(&"Ren is launching a Studio plan with yearly billing for Pebblewick.")
    );
    let text = overview.to_string();
    for never in ["[app=", "keys", "clicks", "%"] {
        assert!(!text.contains(never), "{never} reached the overview");
    }

    let date = overview["date"].as_str().unwrap().to_owned();
    let sessions = read(&seeded, &["sessions", "--date", &date]);
    assert!(sessions["sessions"].as_array().unwrap().len() >= 8);

    let page = read(&seeded, &["model", "--page"]);
    let shared: Vec<&str> = page["shared"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["text"].as_str().unwrap())
        .collect();
    assert!(
        shared.contains(&"Ren is hiring a finance lead."),
        "{shared:?}"
    );
    let all = page.to_string();
    assert!(
        !all.contains("busy with the Studio plan"),
        "a passing state is never on About You"
    );

    let looked_up = read(&seeded, &["searches", "--hours", "200"]);
    let queries: Vec<&str> = looked_up["searches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["query"].as_str().unwrap())
        .collect();
    // This morning's search and yesterday's; the afternoon's is still ahead.
    for query in [
        "stripe prorate monthly to yearly",
        "saas yearly plan discount",
    ] {
        assert!(queries.contains(&query), "{query} in {queries:?}");
    }
}

#[test]
fn the_calendar_is_written_beside_the_memory_for_this_user_only() {
    let seeded = seed(None);
    let path = seeded.db.with_file_name("demo-calendar.json");
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let calendar: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(calendar["version"], 1);
    let events = calendar["events"].as_array().unwrap();
    assert!(events.iter().any(|e| e["title"] == "Team sync"));
    assert!(events.iter().any(|e| e["title"] == "Investor update"));
    let now = now_us();
    for event in events {
        let start = event["start_us"].as_u64().unwrap();
        assert!(start + 8 * 86_400_000_000 > now && start < now + 8 * 86_400_000_000);
        assert!(event.get("attendees").is_none());
    }
}

#[test]
fn the_same_clock_writes_the_same_week() {
    let now = now_us();
    let first = seed(Some(now));
    let second = seed(Some(now));
    assert_eq!(first.summary, second.summary);
    let date = read(&first, &["overview"])["date"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        read(&first, &["sessions", "--date", &date]),
        read(&second, &["sessions", "--date", &date])
    );
    assert_eq!(
        std::fs::read(first.db.with_file_name("demo-calendar.json")).unwrap(),
        std::fs::read(second.db.with_file_name("demo-calendar.json")).unwrap()
    );
}

#[test]
fn it_never_writes_into_the_persons_own_memory() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let own = home.join("Library/Application Support/MCI");
    std::fs::create_dir_all(&own).unwrap();
    let output = command(SEEDER, &home, 0)
        .arg("--demo-week")
        .arg("--db-path")
        .arg(own.join("mci.sqlite"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(15));
    assert_eq!(
        std::fs::read_dir(&own).unwrap().count(),
        0,
        "nothing written there"
    );
    // A link to that folder is that folder.
    let link = dir.path().join("looks-like-demo");
    std::os::unix::fs::symlink(&own, &link).unwrap();
    let output = command(SEEDER, &home, 0)
        .arg("--demo-week")
        .arg("--db-path")
        .arg(link.join("mci.sqlite"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(15));
    assert_eq!(std::fs::read_dir(&own).unwrap().count(), 0);
    // Without a place of its own, it writes nowhere.
    let output = command(SEEDER, &home, 0)
        .env("MCI_DB_PATH", own.join("mci.sqlite"))
        .arg("--demo-week")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(std::fs::read_dir(&own).unwrap().count(), 0);
}

#[test]
fn it_writes_only_into_an_empty_memory() {
    let seeded = seed(None);
    let again = command(SEEDER, &seeded.home, seeded.tz)
        .arg("--demo-week")
        .arg("--db-path")
        .arg(&seeded.db)
        .output()
        .unwrap();
    assert_eq!(again.status.code(), Some(15));
    for flag in ["--force", "--demo-day"] {
        let output = command(SEEDER, &seeded.home, seeded.tz)
            .args(["--demo-week", flag, "--db-path"])
            .arg(seeded.db.with_file_name("other.sqlite"))
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{flag}");
    }
}

#[test]
fn the_key_can_come_on_standard_input_only() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("mci.sqlite");
    let mut child = Command::new(SEEDER)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.path())
        .args([
            "--demo-week",
            "--key-stdin",
            "--tz-offset-secs",
            "0",
            "--db-path",
        ])
        .arg(&db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("{KEY_HEX}\n").as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    ok(&output);
    // The same key opens it.
    let sessions = json(
        &command(AGENT, dir.path(), 0)
            .args(["sessions", "--tz-offset-secs", "0", "--json", "--db-path"])
            .arg(&db)
            .output()
            .unwrap(),
    );
    assert!(sessions["sessions"].is_array());
    // A key that isn't one is refused before anything is opened.
    let other = dir.path().join("other.sqlite");
    let mut child = Command::new(SEEDER)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.path())
        .args(["--demo-week", "--key-stdin", "--db-path"])
        .arg(&other)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"not a key\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(11));
    assert!(!other.exists());
    // Without the stdin flag or the development gate there is no key at all.
    let output = Command::new(SEEDER)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.path())
        .env("MCI_DB_KEY_HEX", KEY_HEX)
        .args(["--demo-week", "--db-path"])
        .arg(&other)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(9));
    assert!(!other.exists());
}

#[test]
fn the_drawing_tools_manifest_puts_screenshots_on_their_moments() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let now = now_us().to_string();
    let list: serde_json::Value = serde_json::from_str(
        ok(&command(SEEDER, &home, 0)
            .args([
                "--demo-week",
                "--print-screens",
                "--tz-offset-secs",
                "0",
                "--now-us",
                &now,
            ])
            .output()
            .unwrap())
        .trim(),
    )
    .unwrap();
    let digests: serde_json::Map<String, serde_json::Value> = list["screens"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
        .map(|(index, screen)| {
            (
                screen["id"].as_str().unwrap().to_owned(),
                serde_json::Value::String(format!("{index:064x}")),
            )
        })
        .collect();
    let manifest = dir.path().join("manifest.json");
    std::fs::write(
        &manifest,
        serde_json::json!({ "version": 1, "screens": digests }).to_string(),
    )
    .unwrap();
    let summary = json(
        &command(SEEDER, &home, 0)
            .args(["--demo-week", "--tz-offset-secs", "0", "--now-us", &now])
            .arg("--screens")
            .arg(&manifest)
            .arg("--db-path")
            .arg(dir.path().join("demo").join("mci.sqlite"))
            .output()
            .unwrap(),
    );
    assert!(summary["screenshots"].as_u64().unwrap() >= 100, "{summary}");
}
