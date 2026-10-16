//! The built binaries end to end: `mci-seed-brain --demo-day` writes a
//! made-up workday into a temporary memory, and `mci-agent overview`,
//! `model --page` and `sessions` read it in the shapes the window is built
//! against (`overview.md`, `model-page.md`, `what-is-sent.md`).
//!
//! Every child runs with an explicitly constructed environment (AGENTS.md
//! test hygiene): no inherited keys, only PATH, HOME and the dev key gate.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const KEY_HEX: &str = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";

fn bin(name: &str) -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push(name);
    path
}

/// A whole-hour offset that puts now in the afternoon, so the made-up day
/// (which ends now and reaches back about six hours) is all on one date.
fn afternoon_offset_secs() -> i64 {
    let hour = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            / 3600
            % 24,
    )
    .unwrap();
    let mut offset = (14 - hour).rem_euclid(24);
    if offset > 14 {
        offset -= 24;
    }
    offset * 3600
}

fn command(name: &str, home: &Path, tz: i64) -> Command {
    let mut command = Command::new(bin(name));
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

fn json(command: &mut Command) -> serde_json::Value {
    let output = command.output().expect("spawn");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    serde_json::from_str(&text).expect("valid JSON")
}

/// Every `{name}` placeholder has a value and no clock time is written in.
fn check_template(t: &serde_json::Value) {
    let text = t["template"].as_str().expect("template");
    let names: Vec<&str> = text
        .split('{')
        .skip(1)
        .filter_map(|rest| rest.split_once('}').map(|(name, _)| name))
        .filter(|name| !name.is_empty() && name.chars().all(|c| c.is_ascii_lowercase() || c == '_'))
        .collect();
    for name in names {
        assert!(
            t["times"].get(name).is_some() || t["durations"].get(name).is_some(),
            "{name} in {text}"
        );
    }
    let chars: Vec<char> = text.chars().collect();
    assert!(
        !chars
            .windows(3)
            .any(|w| w[0].is_ascii_digit() && w[1] == ':' && w[2].is_ascii_digit()),
        "{text}"
    );
}

#[test]
#[allow(clippy::too_many_lines)] // one seeded day, checked the way the window reads it
fn a_seeded_day_reads_as_the_window_expects() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let db = dir.path().join("mci.sqlite");
    let tz = afternoon_offset_secs();
    // A session hook for Claude Code, so "Your AI already knows" applies.
    let hook = serde_json::json!({ "hooks": { "SessionStart": [{ "matcher": "startup|resume|clear|compact", "hooks": [{
        "type": "command", "timeout": 10,
        "command": format!("'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format claude-hook --db-path '{}'", db.display()),
    }]}]}});
    std::fs::write(home.join(".claude/settings.json"), hook.to_string()).unwrap();

    let seeded = command("mci-seed-brain", &home, tz)
        .arg("--db-path")
        .arg(&db)
        .arg("--demo-day")
        .output()
        .unwrap();
    assert!(
        seeded.status.success(),
        "{}",
        String::from_utf8_lossy(&seeded.stderr)
    );
    // Remembering right now: a fresh receipt naming no block and no skip.
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let stamp = mci_agent::wall_clock::format_unix_ms(now_ms);
    let receipt = serde_json::json!({ "schema_version": 1, "updated_at": stamp, "last_stored_frame_at": stamp,
        "stored_frame_count": 180, "stored_screenshot_count": 0, "suppression_reason": null, "blocked_reason": null });
    std::fs::write(dir.path().join("capture-status.json"), receipt.to_string()).unwrap();

    let tz_arg = tz.to_string();
    let overview = json(
        command("mci-agent", &home, tz)
            .args([
                "overview",
                "--tz-offset-secs",
                &tz_arg,
                "--json",
                "--db-path",
            ])
            .arg(&db),
    );
    let top: Vec<&str> = overview
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    for key in [
        "version",
        "date",
        "is_today",
        "now_us",
        "tz_offset_secs",
        "day_start_us",
        "day_end_us",
        "basis",
        "truncated",
        "model_status",
        "now",
        "strip",
        "blocks",
        "gaps",
        "kinds",
        "facts",
        "searches",
        "account",
        "ai_knows",
    ] {
        assert!(top.contains(&key), "missing {key}");
    }
    assert!(!top.contains(&"open_loops"));
    assert_eq!(overview["version"], 1);
    assert_eq!(overview["is_today"], true);
    assert_eq!(overview["model_status"]["state"], "available");
    let blocks = overview["blocks"].as_array().unwrap();
    assert_eq!(
        blocks.len(),
        8,
        "seven noted sessions and the one still going"
    );
    assert!(blocks[..7]
        .iter()
        .all(|b| b["provisional"] == false && b["in_progress"] == false));
    assert_eq!(
        (
            blocks[7]["provisional"].as_bool(),
            blocks[7]["in_progress"].as_bool()
        ),
        (Some(true), Some(true))
    );
    assert_eq!(
        blocks[2]["touches_previous"], true,
        "the 30-minute cap shows as touching"
    );
    assert_eq!(blocks[2]["written_by"], "measured");
    assert_eq!(overview["now"]["state"], "in_progress");
    assert_eq!(overview["now"]["block_id"], blocks[7]["id"]);
    let ids: Vec<&str> = overview["facts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["active", "longest", "returned", "searched"]);
    for fact in overview["facts"].as_array().unwrap() {
        check_template(fact);
    }
    for block in blocks {
        for sentence in block["sentences"].as_array().unwrap() {
            check_template(sentence);
        }
    }
    let legend: Vec<&str> = overview["kinds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["kind"].as_str().unwrap())
        .collect();
    for block in blocks {
        assert!(
            legend.contains(&block["kind"].as_str().unwrap()),
            "the legend comes from the sessions"
        );
    }
    assert!(overview["account"]["headline"]
        .as_str()
        .is_some_and(|h| !h.is_empty()));
    let knows = &overview["ai_knows"];
    assert_eq!(knows["hook_installed"], true);
    // Only what Sam confirmed, or what moments on two days or more show,
    // goes to an AI (`understanding::sending`).
    let sent: Vec<&str> = knows["about_you"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line["text"].as_str().unwrap())
        .collect();
    assert_eq!(
        sent[0], "Sam is redesigning the pricing page for Trailhead Bikes.",
        "confirmed, so the surest"
    );
    let mut rest = sent[1..].to_vec();
    rest.sort_unstable();
    assert_eq!(
        rest,
        [
            "Sam is fixing how the Trailhead checkout rounds sales tax.",
            "Sam writes Rust and runs tests from the terminal.",
        ]
    );
    let recent = knows["recent_work"].as_array().unwrap();
    assert_eq!(recent.len(), 4);
    recent.iter().for_each(check_template);
    let text = overview.to_string();
    for never in ["\u{1e}", "[app=", "keys", "clicks", "paus", "%"] {
        assert!(!text.contains(never), "{never} reached the overview");
    }

    let page = json(
        command("mci-agent", &home, tz)
            .args([
                "model",
                "--page",
                "--tz-offset-secs",
                &tz_arg,
                "--json",
                "--db-path",
            ])
            .arg(&db),
    );
    assert_eq!(
        page["recent_work"], knows["recent_work"],
        "the page shows the lines as sent"
    );
    let items = |list: &str| page[list].as_array().unwrap().clone();
    let shared: Vec<i64> = items("shared")
        .iter()
        .map(|i| i["id"].as_i64().unwrap())
        .collect();
    for line in knows["about_you"].as_array().unwrap() {
        assert!(
            shared.contains(&line["id"].as_i64().unwrap()),
            "what is sent is on the page"
        );
    }
    let all: Vec<serde_json::Value> = ["shared", "kept_back", "not_sent", "not_seen_lately"]
        .into_iter()
        .flat_map(items)
        .collect();
    assert!(
        all.iter().all(|i| i["kind"] != "state"),
        "state items are never on the page"
    );
    let texts: Vec<&str> = all.iter().map(|i| i["text"].as_str().unwrap()).collect();
    assert!(
        !texts
            .iter()
            .any(|t| t.contains("tax rounding tests passing")),
        "a struggle seen once is not shown"
    );
    assert!(items("kept_back")
        .iter()
        .any(|i| i["kind"] == "struggle" && i["basis"] == "seen_on_days"));
    let not_sent = items("not_sent");
    let waiting: Vec<&str> = not_sent
        .iter()
        .map(|i| i["text"].as_str().unwrap())
        .collect();
    for guess in [
        "Sam wants the new pricing page live before the October sale.",
        "Sam drafts copy in Notes before laying it out in Figma.",
        "Sam reviews pricing changes with the design team on Mondays.",
    ] {
        assert!(
            waiting.contains(&guess),
            "{guess} waits on You until it is corroborated or confirmed: {waiting:?}"
        );
        assert!(!sent.contains(&guess));
    }
    assert!(items("not_seen_lately")
        .iter()
        .any(|i| i["basis"] == "confirmed"));
    let page_text = page.to_string();
    assert!(!page_text.contains("confidence") && !page_text.contains('%'));

    let date = overview["date"].as_str().unwrap();
    let sessions = json(
        command("mci-agent", &home, tz)
            .args([
                "sessions",
                "--date",
                date,
                "--tz-offset-secs",
                &tz_arg,
                "--json",
                "--db-path",
            ])
            .arg(&db),
    );
    let sessions = sessions["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 7);
    assert!(sessions
        .iter()
        .all(|s| s["kind"].is_string() && s["kind_label"].is_string()));
    assert!(sessions.iter().all(|s| s["kind_label"] != "AI assistants"));
}
