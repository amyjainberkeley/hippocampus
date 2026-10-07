//! Shared loader for `fixtures/handoff_events.jsonl`: writes the synthetic
//! transcript events into a temp brain in the contract header format.
#![allow(dead_code, clippy::too_many_arguments)]

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use mci_agent::handoff::{LocalTz, RenderClock};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

/// A fixed Pacific daylight zone so rendered times are stable.
pub const PDT_OFFSET: i32 = -25_200;
/// 64 hex chars for `MCI_DB_KEY_HEX`.
pub const KEY_HEX: &str = "0101010101010101010101010101010101010101010101010101010101010101";

pub fn key() -> DbKey {
    DbKey::from_bytes([1; 32])
}

pub fn clock(now_us: u64) -> RenderClock {
    RenderClock {
        now_us,
        tz: LocalTz::fixed(PDT_OFFSET, "PDT"),
    }
}

/// `YYYY-MM-DDTHH:MM:SSZ` to microseconds.
pub fn ts_us(rfc: &str) -> u64 {
    let num = |a: usize, z: usize| rfc[a..z].parse::<i64>().unwrap();
    let (y, mo, d) = (num(0, 4), num(5, 7), num(8, 10));
    let (h, mi, s) = (num(11, 13), num(14, 16), num(17, 19));
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + s).unwrap() * 1_000_000
}

/// One fixture record after `{ROOT}` substitution, with its stored id.
#[derive(Debug, Clone)]
pub struct Loaded {
    pub id: u64,
    pub ts_us: u64,
    pub role: String,
    pub session: Option<String>,
    pub src: Option<String>,
    pub cwd: String,
    pub body: String,
}

pub fn fixture_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/handoff_events.jsonl")
}

/// Build the contract header line for one record.
pub fn header(
    app: &str,
    project: &str,
    role: &str,
    cwd: &str,
    branch: &str,
    session: Option<&str>,
    src: Option<&str>,
) -> String {
    let mut line = format!("[app={app} | title={project} · {role} | url={cwd}#{branch}");
    if let Some(session) = session {
        let _ = write!(line, " | session={session}");
    }
    if let Some(src) = src {
        let _ = write!(line, " | src={src}");
    }
    line.push(']');
    line
}

pub fn bundle_for(app: &str) -> &'static str {
    match app {
        "codex" => "com.openai.codex",
        _ => "com.anthropic.claude-code",
    }
}

/// Insert one transcript event and return its id.
pub fn put_transcript(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    project: &str,
    role: &str,
    cwd: &str,
    branch: &str,
    session: Option<&str>,
    src: Option<&str>,
    body: &str,
) -> u64 {
    let head = header(app, project, role, cwd, branch, session, src);
    let event = Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(bundle_for(app).to_owned()),
        window_title: Some(format!("{project} · {role}")),
        url: Some(cwd.to_owned()),
        text: format!("{head}\n{body}"),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    };
    store
        .put_event_with_source(&event, EventSource::TranscriptImport)
        .expect("put transcript event")
        .0
}

/// Insert a screen OCR event.
pub fn put_screen(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    bundle: &str,
    title: &str,
    text: &str,
) -> u64 {
    let event = Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(bundle.to_owned()),
        window_title: Some(title.to_owned()),
        url: None,
        text: text.to_owned(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    };
    store
        .put_event_with_source(&event, EventSource::ScreenOcr)
        .expect("put screen event")
        .0
}

/// Load every fixture record into `store`, rooted at `root`.
pub fn load_fixture(store: &SqlCipherBrainStore, root: &Path) -> Vec<Loaded> {
    let raw = std::fs::read_to_string(fixture_path()).expect("read fixture");
    let root_str = root.display().to_string();
    let mut out = Vec::new();
    for line in raw.lines().filter(|l| !l.trim().is_empty()) {
        let line = line.replace("{ROOT}", &root_str);
        let rec: serde_json::Value = serde_json::from_str(&line).expect("fixture json");
        let s = |k: &str| rec[k].as_str().map(str::to_owned);
        let ts = ts_us(rec["ts"].as_str().unwrap());
        let app = s("app").unwrap();
        let project = s("project").unwrap();
        let role = s("role").unwrap();
        let cwd = s("cwd").unwrap();
        let branch = s("branch").unwrap_or_default();
        let session = s("session");
        let src = s("src");
        let body = s("body").unwrap();
        let id = put_transcript(
            store,
            ts,
            &app,
            &project,
            &role,
            &cwd,
            &branch,
            session.as_deref(),
            src.as_deref(),
            &body,
        );
        out.push(Loaded {
            id,
            ts_us: ts,
            role,
            session,
            src,
            cwd,
            body,
        });
    }
    out
}

/// A temp brain with the fixture loaded. Returns (dir, db path, root, records).
pub fn fixture_brain() -> (tempfile::TempDir, PathBuf, PathBuf, Vec<Loaded>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path().join("projects");
    std::fs::create_dir_all(root.join("hippocampus")).unwrap();
    std::fs::create_dir_all(root.join("onekit")).unwrap();
    let db = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&db, &key()).expect("open store");
    let records = load_fixture(&store, &root);
    drop(store);
    (dir, db, root, records)
}
