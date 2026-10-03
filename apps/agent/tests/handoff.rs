//! Handoff compiler and daily packet over a temp brain filled from the
//! synthetic fixture (two projects, three sessions, user/assistant/tool
//! roles, decision and avoid phrases, questions, two days).

mod handoff_fixture;

use std::process::Command;

use handoff_fixture::{clock, fixture_brain, key, put_screen, put_transcript, ts_us};
use mci_agent::handoff::{
    compile_handoff, fallback_envelope, hook_envelope, render_empty_handoff, token_estimate,
    HandoffReport, DISCLAIMER, NO_MEMORY_HOOK_TEXT,
};
use mci_agent::today::{compile_today, render_today, TodayReport};
use mci_brain::SqlCipherBrainStore;

/// 16 hours after the newest fixture event (2026-09-26 05:43Z).
fn now_us() -> u64 {
    ts_us("2026-09-26T05:43:00Z") + 16 * 3600 * 1_000_000
}

/// Every cited line ends with `(agent, YYYY-MM-DD HH:MM, event N)`.
fn ends_with_citation(line: &str) -> bool {
    let Some(open) = line.rfind('(') else {
        return false;
    };
    let inner = &line[open + 1..];
    let Some(inner) = inner.strip_suffix(')') else {
        return false;
    };
    let parts: Vec<&str> = inner.split(", ").collect();
    parts.len() == 3
        && matches!(parts[0], "claude-code" | "codex" | "screen")
        && parts[1].len() == 16
        && parts[1].as_bytes()[10] == b' '
        && parts[2]
            .strip_prefix("event ")
            .is_some_and(|n| n.parse::<u64>().is_ok())
}

fn section_index(text: &str, heading: &str) -> usize {
    text.find(&format!("\n{heading}\n"))
        .unwrap_or_else(|| panic!("missing section {heading} in:\n{text}"))
}

fn section_lines<'a>(text: &'a str, heading: &str) -> Vec<&'a str> {
    let start = section_index(text, heading) + 1 + heading.len() + 1;
    text[start..]
        .lines()
        .take_while(|line| !line.starts_with("## "))
        .filter(|line| !line.trim().is_empty())
        .collect()
}

#[test]
#[allow(clippy::too_many_lines)] // One walk through every section of one packet.
fn packet_sections_follow_contract_order_and_every_cited_line_is_checkable() {
    let (_dir, db, root, records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let packet = compile_handoff(&store, &root.join("hippocampus"), 600, &clock(now_us())).unwrap();
    let text = &packet.packet;
    println!("{text}");

    assert!(text.starts_with(&format!("{DISCLAIMER}\n\n# Handoff: hippocampus (")));
    assert!(text.contains("Last worked 2026-09-25 22:43 PDT by Codex, 16 hours ago."));
    assert!(text.contains("In memory: 2 sessions (Claude Code 1, Codex 1), 8 turns."));

    let order = [
        "## Where you stopped",
        "## Next step",
        "## Goal",
        "## Decisions",
        "## Avoid",
        "## Open questions",
        "## Files touched last session",
        "## Sources",
    ];
    let positions: Vec<usize> = order.iter().map(|h| section_index(text, h)).collect();
    assert!(
        positions.windows(2).all(|w| w[0] < w[1]),
        "section order {positions:?}"
    );
    assert!(
        !text.contains("## Git"),
        "the temp root is not a git repository"
    );

    let stopped = section_lines(text, "## Where you stopped");
    assert_eq!(stopped.len(), 1);
    assert!(stopped[0].starts_with("Extraction and rendering are in place"));
    let last = records.iter().rfind(|r| r.role == "assistant").unwrap();
    assert!(stopped[0].ends_with(&format!("(codex, 2026-09-25 22:43, event {})", last.id)));

    let next = section_lines(text, "## Next step");
    assert!(
        next[0].starts_with("Remaining: the migration is registered"),
        "{}",
        next[0]
    );

    let goals = section_lines(text, "## Goal");
    assert!(goals[0].starts_with("Now build the handoff packet compiler"));
    assert!(goals[1].starts_with("- Earlier: Build the transcript importer"));

    let decisions = section_lines(text, "## Decisions");
    let joined = decisions.join("\n");
    assert!(
        joined.contains("we'll always end every cited line"),
        "{joined}"
    );
    assert!(
        joined.contains("The plan is to extract sessions by header"),
        "{joined}"
    );
    assert!(
        joined.contains("Decision: we store only text blocks"),
        "{joined}"
    );
    assert!(decisions.len() <= 6);
    // Newest first: the codex session's lines precede the older claude-code ones.
    let codex_first = joined.find("(codex,").unwrap();
    let claude_first = joined.find("(claude-code,").unwrap();
    assert!(codex_first < claude_first);

    let avoid = section_lines(text, "## Avoid");
    let joined = avoid.join("\n");
    assert!(
        joined.contains("Do not use an LLM for extraction."),
        "{joined}"
    );
    assert!(
        joined.contains("never import the subagent transcripts"),
        "{joined}"
    );
    assert!(avoid.len() <= 4);

    let questions = section_lines(text, "## Open questions");
    assert!(questions[0].contains("Is the Sources section supposed to list uncited ids too?"));
    assert!(questions.len() <= 3);

    let files = section_lines(text, "## Files touched last session");
    assert_eq!(files[0], "- apps/agent/src/handoff.rs (3 edits)");
    assert_eq!(
        files[1],
        "- core/brain/migrations/0012_handoff_deliveries.sql (1 edit)"
    );

    for heading in [
        "## Where you stopped",
        "## Next step",
        "## Goal",
        "## Decisions",
        "## Avoid",
        "## Open questions",
    ] {
        for line in section_lines(text, heading) {
            assert!(
                ends_with_citation(line),
                "uncited line under {heading}: {line}"
            );
        }
    }

    // Sources lists exactly the cited ids, each with its transcript source.
    let sources = section_lines(text, "## Sources");
    let listed: Vec<u64> = sources
        .iter()
        .map(|line| {
            line.strip_prefix("event ")
                .and_then(|rest| rest.split_once(' '))
                .and_then(|(id, _)| id.parse().ok())
                .unwrap_or_else(|| panic!("bad source line {line}"))
        })
        .collect();
    let mut expected = packet.cited_event_ids.clone();
    expected.sort_unstable();
    assert_eq!(listed, expected);
    for line in &sources {
        assert!(line.contains(" → /Users/t/"), "{line}");
    }
    let body_before_sources = &text[..section_index(text, "## Sources")];
    for id in &listed {
        assert!(
            body_before_sources.contains(&format!("event {id})")),
            "{id} not cited"
        );
    }
    assert!(
        !text.contains("\u{2014}"),
        "no em dashes anywhere in the packet"
    );
}

#[test]
fn budget_is_respected_at_128_and_600_with_no_half_lines() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let cwd = root.join("hippocampus");
    let full = compile_handoff(&store, &cwd, 4096, &clock(now_us())).unwrap();
    let full_lines: Vec<&str> = full.packet.lines().collect();

    for budget in [128, 600] {
        let packet = compile_handoff(&store, &cwd, budget, &clock(now_us())).unwrap();
        let estimate = token_estimate(&packet.packet);
        assert!(estimate <= budget, "{estimate} tokens exceeds {budget}");
        assert_eq!(packet.token_estimate, estimate);
        assert!(
            packet.packet.contains("## Where you stopped"),
            "{}",
            packet.packet
        );
        for line in packet.packet.lines() {
            assert!(
                full_lines.contains(&line),
                "line at budget {budget} is not a whole line of the full packet: {line}"
            );
        }
        let sources = section_lines(&packet.packet, "## Sources");
        assert_eq!(sources.len(), packet.cited_event_ids.len());
        let before = &packet.packet[..section_index(&packet.packet, "## Sources")];
        for id in &packet.cited_event_ids {
            assert!(before.contains(&format!("event {id})")));
        }
    }
    let small = compile_handoff(&store, &cwd, 128, &clock(now_us())).unwrap();
    assert!(
        small.packet.len() < full.packet.len(),
        "128 tokens must drop later sections"
    );
}

#[test]
fn packet_is_deterministic() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let cwd = root.join("hippocampus");
    let a = compile_handoff(&store, &cwd, 600, &clock(now_us())).unwrap();
    let b = compile_handoff(&store, &cwd, 600, &clock(now_us())).unwrap();
    assert_eq!(a, b);
    assert_eq!(a.sha256(), b.sha256());
}

#[test]
fn empty_project_renders_the_contract_text_and_the_hook_fallback() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let packet =
        compile_handoff(&store, &root.join("nothing-here"), 600, &clock(now_us())).unwrap();
    assert!(!packet.has_memory());
    assert_eq!(packet.packet, render_empty_handoff("nothing-here"));
    assert_eq!(
        packet.packet,
        "# Handoff: nothing-here\nNo memory for this project yet. Hippocampus will have context after your first agent session here.\n"
    );
    assert!(packet.cited_event_ids.is_empty());
    assert!(fallback_envelope().contains(NO_MEMORY_HOOK_TEXT));
}

#[test]
fn a_project_whose_events_lack_session_fields_still_works() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("legacy");
    std::fs::create_dir_all(&root).unwrap();
    let db = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
    let cwd = root.display().to_string();
    put_transcript(
        &store,
        ts_us("2026-09-25T18:00:00Z"),
        "claude-code",
        "legacy",
        "user",
        &cwd,
        "main",
        None,
        None,
        "Fix the flaky login test and keep the retry logic simple.",
    );
    let last = put_transcript(
        &store,
        ts_us("2026-09-25T18:05:00Z"),
        "claude-code",
        "legacy",
        "assistant",
        &cwd,
        "main",
        None,
        None,
        "The test is stable now. Next, remove the retry helper once CI is green.",
    );
    let packet = compile_handoff(&store, &root, 600, &clock(now_us())).unwrap();
    println!("{}", packet.packet);
    assert!(packet.has_memory());
    assert_eq!(packet.state.sessions.len(), 1);
    assert_eq!(packet.state.sessions[0].id, format!("{cwd}@2026-09-25"));
    assert!(packet.packet.contains("The test is stable now."));
    assert!(packet
        .packet
        .contains(&format!("event {last} → (source path not recorded)")));
    // The message is one paragraph, so the whole paragraph is the next step.
    let next = section_lines(&packet.packet, "## Next step");
    assert!(
        next[0].contains("Next, remove the retry helper once CI is green."),
        "{}",
        next[0]
    );
}

#[test]
fn injected_and_pasted_user_turns_are_never_quoted_as_the_users_words() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("proj");
    std::fs::create_dir_all(&root).unwrap();
    let db = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
    let cwd = root.display().to_string();
    let put = |minute: u64, role: &str, body: &str| {
        put_transcript(
            &store,
            ts_us("2026-09-25T18:00:00Z") + minute * 60 * 1_000_000,
            "claude-code",
            "proj",
            role,
            &cwd,
            "main",
            Some("s1"),
            None,
            body,
        )
    };
    put(
        0,
        "user",
        "Base directory for this skill: /tmp/skills/design\n\nAlways use a two column layout. Never use templated designs.",
    );
    let skill_body = format!(
        "Approach this as the design lead. Keep flourishes tasteful and limited. {}",
        "x".repeat(5_000)
    );
    put(1, "user", &skill_body);
    put(2, "user", "<task-notification>done</task-notification>");
    put(
        3,
        "user",
        "Another Claude session sent a message: <agent-message>we'll always ship on Fridays</agent-message>",
    );
    let real = put(
        4,
        "user",
        "Please use sqlite for the cache and do not add a redis dependency.",
    );
    put(
        5,
        "assistant",
        "Done \u{2014} the cache uses sqlite now. Then I will remove the redis client.",
    );

    let packet = compile_handoff(&store, &root, 4096, &clock(now_us())).unwrap();
    println!("{}", packet.packet);
    assert_eq!(packet.state.goal.as_ref().unwrap().event_id, real);
    assert!(packet.state.earlier_goals.is_empty());
    for line in packet.state.decisions.iter().chain(&packet.state.avoid) {
        assert_eq!(
            line.event_id, real,
            "quoted an injected turn: {}",
            line.text
        );
    }
    assert!(!packet.packet.contains("two column layout"));
    assert!(!packet.packet.contains("flourishes"));
    assert!(!packet.packet.contains("Fridays"));
    assert!(
        !packet.packet.contains('\u{2014}'),
        "em dashes are scrubbed from quoted text"
    );
    assert!(packet.packet.contains("Done - the cache uses sqlite now."));
    let next = section_lines(&packet.packet, "## Next step");
    assert!(
        next[0].starts_with("Then I will remove the redis client."),
        "{}",
        next[0]
    );
}

#[test]
fn json_report_round_trips() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let packet = compile_handoff(&store, &root.join("hippocampus"), 600, &clock(now_us())).unwrap();
    let report = HandoffReport {
        client: "cli".into(),
        generated_at_us: now_us(),
        tz: clock(now_us()).tz,
        packet,
    };
    let json = serde_json::to_string_pretty(&report).unwrap();
    let back: HandoffReport = serde_json::from_str(&json).unwrap();
    assert_eq!(back, report);
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(value["client"], "cli");
    assert!(value["packet"].as_str().unwrap().starts_with(DISCLAIMER));
    assert_eq!(value["state"]["name"], "hippocampus");
}

#[test]
fn hook_envelopes_carry_the_packet_and_parse_as_json() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let packet = compile_handoff(&store, &root.join("hippocampus"), 600, &clock(now_us())).unwrap();
    for envelope in [hook_envelope(&packet.packet), fallback_envelope()] {
        assert_eq!(envelope.lines().count(), 1, "one line on stdout");
        let value: serde_json::Value = serde_json::from_str(&envelope).unwrap();
        assert_eq!(value["hookSpecificOutput"]["hookEventName"], "SessionStart");
        assert!(value["hookSpecificOutput"]["additionalContext"].is_string());
    }
    let value: serde_json::Value = serde_json::from_str(&hook_envelope(&packet.packet)).unwrap();
    assert_eq!(
        value["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap(),
        packet.packet
    );
}

#[test]
fn screen_events_naming_the_project_appear_under_also_seen() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
    let seen = put_screen(
        &store,
        ts_us("2026-09-26T05:35:00Z"),
        "com.microsoft.VSCode",
        "handoff.rs (hippocampus)",
        "fn render_handoff",
    );
    put_screen(
        &store,
        ts_us("2026-09-26T05:36:00Z"),
        "com.google.Chrome",
        "Unrelated tab",
        "news",
    );
    put_screen(
        &store,
        ts_us("2026-09-23T05:36:00Z"),
        "com.microsoft.VSCode",
        "hippocampus, but outside the latest session",
        "old",
    );
    let packet =
        compile_handoff(&store, &root.join("hippocampus"), 4096, &clock(now_us())).unwrap();
    let lines = section_lines(&packet.packet, "## Also seen");
    assert_eq!(lines.len(), 1, "{}", packet.packet);
    assert_eq!(
        lines[0],
        format!("- VS Code at 22:35 (screen, 2026-09-25 22:35, event {seen})")
    );
    assert!(packet.cited_event_ids.contains(&seen));
    assert!(!packet.packet.contains("Unrelated"));
    assert!(
        !packet.packet.contains("fn render_handoff"),
        "screen text is never quoted"
    );
}

#[test]
fn git_section_reports_branch_uncommitted_files_and_commits() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let git = |args: &[&str]| {
        let status = Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("HOME", dir.path())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .expect("run git");
        assert!(status.success(), "git {args:?}");
    };
    git(&["init", "-q", "-b", "feat/x"]);
    std::fs::write(repo.join("a.txt"), "a").unwrap();
    git(&["add", "a.txt"]);
    git(&["commit", "-q", "-m", "first commit"]);
    std::fs::write(repo.join("b.txt"), "b").unwrap();

    let db = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
    let sub = repo.join("src");
    std::fs::create_dir_all(&sub).unwrap();
    // The session ran in a subdirectory; the packet is for the repo root.
    put_transcript(
        &store,
        ts_us("2026-09-25T18:00:00Z"),
        "codex",
        "repo",
        "user",
        &repo.display().to_string(),
        "feat/x",
        Some("g1"),
        Some("/Users/t/.codex/sessions/g1.jsonl:1"),
        "Start the git evidence work in this repository please.",
    );
    let packet = compile_handoff(&store, &sub, 4096, &clock(now_us())).unwrap();
    println!("{}", packet.packet);
    assert!(packet.packet.contains("# Handoff: repo ("));
    let git_lines = section_lines(&packet.packet, "## Git");
    assert!(git_lines[0].starts_with("Branch feat/x, 1 file uncommitted. Last commits: "));
    assert!(git_lines[0].contains("\"first commit\""));
    assert_eq!(packet.state.git.as_ref().unwrap().commits.len(), 1);
}

fn day_report(store: &SqlCipherBrainStore, date: &str) -> TodayReport {
    compile_today(store, Some(date), &clock(now_us())).unwrap()
}

#[test]
fn today_groups_by_project_and_day() {
    let (_dir, db, root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();

    let sep25 = day_report(&store, "2026-09-25");
    let text = render_today(&sep25);
    println!("{text}");
    assert!(text.starts_with("# Today, 2026-09-25 (PDT)\n"));
    assert!(text.contains("Agents: 2 sessions (Claude Code 1, Codex 1), 13:00 to 22:43."));
    let names: Vec<&str> = sep25
        .projects
        .iter()
        .map(|p| p.state.name.as_str())
        .collect();
    assert_eq!(
        names,
        ["hippocampus", "onekit"],
        "most recently active first"
    );
    assert!(text.contains(&format!(
        "## hippocampus ({})",
        root.join("hippocampus").display()
    )));
    assert!(text.contains(&format!("## onekit ({})", root.join("onekit").display())));
    assert!(text.contains("- Goal: Now build the handoff packet compiler"));
    assert!(text.contains("- Stopped at: Extraction and rendering are in place"));
    assert!(text.contains("- Files: handoff.rs, 0012_handoff_deliveries.sql"));
    assert!(text.contains("- Files: sense.ts"));
    assert!(!text.contains("## Screen"));

    let sep24 = day_report(&store, "2026-09-24");
    let names: Vec<&str> = sep24
        .projects
        .iter()
        .map(|p| p.state.name.as_str())
        .collect();
    assert_eq!(names, ["hippocampus"]);
    assert_eq!(sep24.sessions, 1);
    let text = render_today(&sep24);
    assert!(text.contains("- Goal: Build the transcript importer"));
    assert!(text.contains("- Files: import_sessions.rs, import.rs"));

    let quiet = day_report(&store, "2026-09-01");
    let text = render_today(&quiet);
    assert!(text.contains("Agents: no sessions."));
    assert!(text.contains("Nothing recorded for this day."));

    assert!(compile_today(&store, Some("2026-02-30"), &clock(now_us())).is_err());
}

#[test]
fn today_totals_screen_time_per_app() {
    let (_dir, db, _root, _records) = fixture_brain();
    let store = SqlCipherBrainStore::new(&db, &key()).unwrap();
    for minute in 0..10 {
        put_screen(
            &store,
            ts_us("2026-09-25T17:00:00Z") + minute * 60 * 1_000_000,
            "com.microsoft.VSCode",
            "editor",
            "code",
        );
    }
    put_screen(
        &store,
        ts_us("2026-09-25T18:00:00Z"),
        "com.google.Chrome",
        "tab",
        "web",
    );
    let report = day_report(&store, "2026-09-25");
    let text = render_today(&report);
    println!("{text}");
    assert!(text.contains("Screen: 10m across 2 apps."), "{text}");
    assert!(
        text.contains("## Screen\n- VS Code 9m, Chrome <1m (from events)"),
        "{text}"
    );
    let json = serde_json::to_string(&report).unwrap();
    let back: TodayReport = serde_json::from_str(&json).unwrap();
    assert_eq!(back, report);
}
