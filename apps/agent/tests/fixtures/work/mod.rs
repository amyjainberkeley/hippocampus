//! A made-up memory for the window's own reads (`work`, `resume-plan`):
//! sessions of windows held in front, written the way the capture helper
//! stores moments and the understanding worker writes its notes. Every name
//! is invented (persona Sam, Trailhead Bikes, Northwind Studio); nothing
//! here is anyone's screen.
//!
//! Shared by `work_cli.rs` and `resume_plan_cli.rs`.

#![allow(dead_code)] // each test file uses a different part

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use mci_brain::understanding::SessionNote;
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

/// The memory's key in every test.
pub const KEY: [u8; 32] = [0x5a; 32];
/// Monday, October 12, 2026, 2:41 PM at UTC−7: "now" for the fixtures.
pub const NOW_US: u64 = 1_791_841_260_000_000;
/// UTC−7, as the window passes it.
pub const TZ: i32 = -7 * 3600;
pub const MINUTE_US: u64 = 60_000_000;
pub const HOUR_US: u64 = 60 * MINUTE_US;
pub const DAY_US: u64 = 24 * HOUR_US;

pub const VS_CODE: &str = "com.microsoft.VSCode";
pub const TERMINAL: &str = "com.apple.Terminal";
pub const CHROME: &str = "com.google.Chrome";
pub const SAFARI: &str = "com.apple.Safari";
pub const NOTES: &str = "com.apple.Notes";
pub const FIGMA: &str = "com.figma.Desktop";
pub const NUMBERS: &str = "com.apple.iWork.Numbers";
pub const SLACK: &str = "com.tinyspeck.slackmacgap";
pub const CLAUDE: &str = "com.anthropic.claudefordesktop";
pub const MAIL: &str = "com.apple.mail";
pub const ONE_PASSWORD: &str = "com.1password.1password";

/// One window held in front for a while.
#[derive(Debug, Clone)]
pub struct Window {
    pub app: &'static str,
    pub title: String,
    pub url: Option<String>,
    /// How long it was in front.
    pub minutes: u64,
    /// How many moments it kept, spread over its time.
    pub moments: usize,
    /// What the moments said.
    pub text: String,
    /// Whether its moments kept a screenshot.
    pub screenshot: bool,
    pub source: EventSource,
}

impl Window {
    /// A window in front, its moments without a screenshot.
    pub fn new(app: &'static str, title: &str, minutes: u64) -> Self {
        Self {
            app,
            title: title.to_owned(),
            url: None,
            minutes,
            moments: usize::try_from(minutes.clamp(1, 12)).unwrap_or(1),
            text: format!("{title}\nSomething on screen."),
            screenshot: false,
            source: EventSource::ScreenOcr,
        }
    }

    /// A page with its address.
    pub fn page(app: &'static str, title: &str, url: &str, minutes: u64) -> Self {
        Self {
            url: Some(url.to_owned()),
            source: EventSource::BrowserPage,
            ..Self::new(app, title, minutes)
        }
    }

    #[must_use]
    pub fn with_screenshot(mut self) -> Self {
        self.screenshot = true;
        self
    }

    #[must_use]
    pub fn with_text(mut self, text: &str) -> Self {
        text.clone_into(&mut self.text);
        self
    }

    #[must_use]
    pub fn with_moments(mut self, moments: usize) -> Self {
        self.moments = moments.max(1);
        self
    }
}

/// A memory in a temporary folder, made the way the app makes one.
pub struct Memory {
    _dir: tempfile::TempDir,
    /// The folder, also the agent's HOME in the tests.
    pub dir: PathBuf,
    pub db: PathBuf,
    pub store: SqlCipherBrainStore,
    shots: std::cell::Cell<u64>,
}

impl Memory {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_path_buf();
        let db = path.join("mci.sqlite");
        let store =
            SqlCipherBrainStore::new(&db, &DbKey::from_bytes(KEY)).expect("make the memory");
        Self {
            _dir: dir,
            dir: path,
            db,
            store,
            shots: std::cell::Cell::new(1),
        }
    }

    /// One moment, as the capture helper stores it.
    pub fn moment(&self, ts_us: u64, window: &Window) -> i64 {
        let shot = window.screenshot.then(|| {
            let n = self.shots.get();
            self.shots.set(n + 1);
            format!("{n:064x}")
        });
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(window.app.to_owned()),
            window_title: Some(window.title.clone()),
            url: window.url.clone(),
            text: format!(
                "[app={} | title={} | url={} | ts=2026-10-12T14:00:00.000Z]\n{}",
                window.app,
                window.title,
                window.url.as_deref().unwrap_or("?"),
                window.text
            ),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: shot,
            tab_id: None,
            embedding: None,
        };
        let id = self
            .store
            .put_event_with_source(&event, window.source)
            .expect("store a moment");
        i64::try_from(id.0).expect("id fits")
    }

    /// The windows in turn from `start_us`, each's moments spread over its
    /// time. Returns each window's moments and where the stretch ended.
    fn windows(&self, start_us: u64, windows: &[Window]) -> (Vec<Vec<i64>>, Vec<(u64, u64)>, u64) {
        let mut at = start_us;
        let mut ids = Vec::new();
        let mut spans = Vec::new();
        for window in windows {
            let length = window.minutes * MINUTE_US;
            let step = length / window.moments.max(1) as u64;
            let mut mine = Vec::new();
            for n in 0..window.moments {
                mine.push(self.moment(at + step * n as u64 + 1, window));
            }
            spans.push((at, at + length));
            at += length;
            ids.push(mine);
        }
        (ids, spans, at)
    }

    /// One finished session: the windows, then the note the worker writes
    /// for it, with each window's moments.
    pub fn session(&self, start_us: u64, windows: &[Window]) -> Vec<Vec<i64>> {
        let (ids, spans, end) = self.windows(start_us, windows);
        let segments: Vec<serde_json::Value> = windows
            .iter()
            .zip(&ids)
            .zip(&spans)
            .map(|((window, events), (from, to))| {
                serde_json::json!({
                    "start_us": from, "end_us": to, "app": window.app, "title": window.title,
                    "host": window.url.as_deref().and_then(mci_brain::apps::host_of),
                    "events": events,
                })
            })
            .collect();
        let note = SessionNote {
            start_us,
            end_us: end,
            title: windows.first().map(|w| w.title.clone()).unwrap_or_default(),
            surface: String::new(),
            beneath: String::new(),
            signals: serde_json::json!({ "segments": segments, "signals": {} }).to_string(),
            event_count: u32::try_from(ids.iter().map(Vec::len).sum::<usize>()).unwrap_or(0),
            generated_us: end,
            model: "measured".into(),
        };
        self.store.put_session_note(&note).expect("write the note");
        ids
    }

    /// Moments the worker hasn't noted yet: the session running now.
    pub fn unnoted(&self, start_us: u64, windows: &[Window]) -> Vec<Vec<i64>> {
        self.windows(start_us, windows).0
    }

    /// Forget one moment, as Privacy's forget does.
    pub fn forget(&self, id: i64) {
        self.store
            .delete_event(EventId(u64::try_from(id).unwrap()))
            .expect("forget");
    }
}

/// The agent binary next to the test.
pub fn agent() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

/// The agent with an explicitly built environment (AGENTS.md test
/// hygiene): only PATH, HOME and the development key gate.
pub fn command(home: &Path) -> Command {
    let mut command = Command::new(agent());
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", "5a".repeat(32))
        .env("MCI_EMBEDDER_DISABLED", "1")
        .stdin(Stdio::null());
    command
}

/// This moment, as the agent reads it: the end-to-end tests write their
/// sessions back from it.
pub fn now_us() -> u64 {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap()
}

/// The `work` read in this process, at a fixed "now" ([`NOW_US`]), with
/// the memory's folder as the home folder.
pub fn work(memory: &Memory, args: &[&str]) -> serde_json::Value {
    work_at(memory, args, NOW_US)
}

/// The `work` read at `now_us`.
pub fn work_at(memory: &Memory, args: &[&str], now_us: u64) -> serde_json::Value {
    use mci_agent::understanding::work::{read_work, Home, WorkArgs};
    let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
    let parsed = WorkArgs::parse(&args).expect("flags");
    let home = Home::at(memory.dir.to_str().unwrap());
    let work = read_work(
        &memory.store,
        &DbKey::from_bytes(KEY),
        &parsed,
        TZ,
        now_us,
        &home,
    )
    .expect("read");
    serde_json::to_value(work).unwrap()
}

/// Runs `args` with `--json`, the memory and the time zone, and reads the
/// one line of JSON it prints.
pub fn read(memory: &Memory, args: &[&str]) -> serde_json::Value {
    let output = command(&memory.dir)
        .args(args)
        .args(["--json", "--tz-offset-secs", &TZ.to_string(), "--db-path"])
        .arg(&memory.db)
        .output()
        .expect("spawn mci-agent");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    serde_json::from_str(&text).expect("valid JSON")
}

/// Sam's code project, a week in: VS Code on tax.rs and a Terminal in the
/// same folder.
pub fn coding(minutes: u64) -> Vec<Window> {
    vec![
        Window::new(VS_CODE, "\u{25cf} tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code", minutes)
            .with_screenshot(),
        Window::new(TERMINAL, "trailhead-shop \u{2014} -zsh \u{2014} 160\u{00d7}40", minutes / 3)
            .with_text("dev@studio trailhead-shop % cargo test tax\nCompiling trailhead-shop v0.4.2 (/Users/dev/trailhead-shop)"),
    ]
}
