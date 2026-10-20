//! `mci-agent resume-plan --item <id> --json`: what Resume would open again
//! for one Working On item, from what was open in its last session
//! (SPEC-DELTA 3): its web pages, documents, code folder and apps, each with
//! whether its checkbox starts ticked, and why not when it can't be opened.
//!
//! Resume sends nothing anywhere and this opens nothing: it only says what
//! the window's Resume sheet lists. The person ticks what to open and
//! clicks; only then does the window ask macOS to open each one.
//!
//! What the plan holds, in the sheet's order:
//! - **the code folder**, in the editor it was edited in, and a terminal in
//!   that folder when one was used (a folder no longer there can't open);
//! - **documents**: through their links on the web (Google Docs, Figma,
//!   Notion), or the app for local ones (Notes, Pages, Numbers, Preview),
//!   which opens the app, not one document;
//! - **web pages**, in the browser they were read in, newest first, the
//!   newest ten ticked; a page whose address isn't known can't open;
//! - **other apps** that were in front.
//!
//! Search result pages, calls and Hippocampus are never offered, and only
//! what is still in memory can be: forgotten moments take their sessions'
//! notes with them. Private windows and the apps and sites Hippocampus never
//! reads were never saved. What the person's own never-read list names today
//! (`denylist.toml` beside the memory: apps, addresses and window titles) is
//! left out here, as Ask {Tool}'s builder leaves it out, even when it was
//! remembered before the rule; the window leaves it out again, with the
//! built-in rules, and anything not installed.
//!
//! Every reason is a code (`reason`); the window says it in its own words.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use mci_brain::apps::{self, WorkKind};
use mci_brain::chrome::is_browser;
use mci_brain::reading::TERMINAL_APPS;
use mci_brain::subject::SubjectKind;
use mci_brain::{SqlCipherBrainStore, StoreError};
use mci_core::crypto::DbKey;
use serde::Serialize;

use super::work::read::{self, About, Held, ItemAcc};
use super::work::{is_item_id, Home};
use super::{ReadCommand, ReadError};
use crate::handoff_card::KeptOut;

/// How many web pages start ticked.
pub const PAGES_TICKED: usize = 10;
/// The most web pages a plan lists.
pub const MAX_PAGES: usize = 30;
/// An app counts as in use from this much time in front.
const APP_MIN_US: u64 = 30 * 1_000_000;

/// What Resume would open for one item, in the order the sheet lists it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ResumePlan {
    /// The item, when it is known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<ResumeItem>,
    /// Its last session's own time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<ResumeSession>,
    /// What was open in the item's last session.
    pub items: Vec<ResumeTarget>,
}

/// The item a plan is for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResumeItem {
    /// Its name, as its windows' titles write it.
    pub name: String,
    /// `code`, `document`, `design` or `spreadsheet`.
    pub kind: SubjectKind,
}

/// The session a plan comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ResumeSession {
    /// When it started, in microseconds since the epoch.
    pub start_us: u64,
    /// When its last moment was.
    pub end_us: u64,
}

/// One thing Resume could open again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResumeTarget {
    /// `"page"`, `"document"`, `"folder"` or `"app"`.
    pub kind: String,
    /// What the sheet calls it: the page's or document's title, the
    /// folder's name or the app's.
    pub title: String,
    /// The bundle id of the app that opens it.
    pub app: Option<String>,
    /// For a page or a linked document, its address without the query and
    /// fragment.
    pub url: Option<String>,
    /// For a local document or a folder, its path with `~` for home.
    pub path: Option<String>,
    /// Whether its checkbox starts ticked.
    pub checked: bool,
    /// Why it can't be opened again, when it can't (shown in place of a
    /// checkbox): "Couldn't find tax.rs".
    pub note: Option<String>,
    /// What about it the sheet explains, as a code the window words:
    /// `missing` (the folder or file is gone; it can't open), `no_address`
    /// (a page whose address isn't known; it can't open), `single_note`
    /// (Notes opens the app, never one note), `app_only` (the app opens,
    /// not this document) and `no_folder` (the editor opens without the
    /// folder).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl ResumeTarget {
    fn new(kind: &str, title: &str, app: &str) -> Self {
        Self {
            kind: kind.to_owned(),
            title: title.to_owned(),
            app: Some(app.to_owned()),
            url: None,
            path: None,
            checked: true,
            note: None,
            reason: None,
        }
    }

    fn because(mut self, reason: &str) -> Self {
        // Gone, or never known: nothing to open, so no tick.
        if matches!(reason, "missing" | "no_address") {
            self.checked = false;
        }
        self.reason = Some(reason.to_owned());
        self
    }
}

/// `mci-agent resume-plan`: the plan as JSON. `--item <id>` is required.
///
/// # Errors
/// [`ReadError::Usage`] without an item's id; [`ReadError::Failed`] when the
/// memory can't be read. Neither repeats what was given or anything read.
pub fn run_cli(command: &ReadCommand<'_>) -> Result<serde_json::Value, ReadError> {
    let item = item_of(command.args)?;
    let plan = plan_leaving_out(
        command.store,
        command.key,
        &item,
        command.tz_offset_secs,
        command.now_us,
        &Home::from_env(),
        &KeptOut::read(command.db_path),
    )
    .map_err(|_| ReadError::Failed("resume-plan could not be read from the memory".into()))?;
    serde_json::to_value(plan)
        .map_err(|_| ReadError::Failed("resume-plan could not be written".into()))
}

/// The item `--item` names. The error never repeats what was given.
///
/// # Errors
/// [`ReadError::Usage`] when `--item` is missing or not an item's id.
pub fn item_of(args: &[String]) -> Result<String, ReadError> {
    let at = args
        .iter()
        .position(|arg| arg == "--item")
        .ok_or_else(|| ReadError::Usage("resume-plan requires --item ID".into()))?;
    args.get(at + 1)
        .filter(|id| is_item_id(id))
        .cloned()
        .ok_or_else(|| ReadError::Usage("--item requires an item's id".into()))
}

/// What Resume would open for the item with `id`: empty for an item that
/// isn't there (forgotten, past retention, or never one).
///
/// # Errors
/// Store failures.
pub fn plan(
    store: &SqlCipherBrainStore,
    key: &DbKey,
    id: &str,
    tz: i32,
    now_us: u64,
    home: &Home,
) -> Result<ResumePlan, StoreError> {
    plan_leaving_out(store, key, id, tz, now_us, home, &KeptOut::default())
}

/// [`plan`], leaving out every window and target the person's never-read
/// list names: by app, by address or by a part of the window's title.
///
/// # Errors
/// Store failures.
pub fn plan_leaving_out(
    store: &SqlCipherBrainStore,
    key: &DbKey,
    id: &str,
    tz: i32,
    now_us: u64,
    home: &Home,
    kept_out: &KeptOut,
) -> Result<ResumePlan, StoreError> {
    let model = super::work::model(store, key, None, tz, now_us, home)?;
    let Some((_, acc)) = model.items.iter().find(|(item, _)| item == id) else {
        return Ok(ResumePlan::default());
    };
    let Some(&last) = acc.sessions.iter().next_back() else {
        return Ok(ResumePlan::default());
    };
    let session = &model.sessions[last];
    let about = &model.about[last];
    let kind = acc.kind.unwrap_or(SubjectKind::Document);
    let urls = addresses(store, &session.held)?;

    let mut targets = Vec::new();
    if kind == SubjectKind::Code {
        targets.extend(code_folder(store, acc, &session.held, about, home)?);
    }
    targets.extend(documents(acc, &session.held, about, &urls, kept_out));
    targets.extend(pages(&session.held, about, &urls, kept_out));
    targets.extend(other_apps(&session.held, about, &targets));
    leave_out(&mut targets, kept_out);
    Ok(ResumePlan {
        item: Some(ResumeItem {
            name: acc.name.clone(),
            kind,
        }),
        session: Some(ResumeSession {
            start_us: session.start_us,
            end_us: session.end_us,
        }),
        items: targets,
    })
}

/// Leaves out every target the never-read list names, by its app, its
/// address or its title, as the window does with the same list.
fn leave_out(targets: &mut Vec<ResumeTarget>, kept_out: &KeptOut) {
    targets.retain(|target| {
        !kept_out.keeps_out(
            target.app.as_deref(),
            target.url.as_deref(),
            Some(&target.title),
        )
    });
}

/// Whether the never-read list names a held window: its app, the address
/// its newest moment had, or a part of its title as it was on screen.
fn kept_out_window(window: &Held, urls: &HashMap<i64, String>, kept_out: &KeptOut) -> bool {
    let url = window.newest().and_then(|id| urls.get(&id));
    kept_out.keeps_out(
        Some(&window.app),
        url.map(String::as_str),
        window.title.as_deref(),
    )
}

/// The address each browser window's newest moment had.
fn addresses(
    store: &SqlCipherBrainStore,
    held: &[Held],
) -> Result<HashMap<i64, String>, StoreError> {
    let newest: Vec<i64> = held
        .iter()
        .filter(|held| is_browser(Some(&held.app)))
        .filter_map(Held::newest)
        .collect();
    let mut urls = HashMap::new();
    for batch in newest.chunks(500) {
        for head in store.event_heads(batch)? {
            if let Some(url) = head.url {
                urls.insert(head.id, url);
            }
        }
    }
    Ok(urls)
}

/// The project's folder in the editor it was edited in, and a terminal in
/// it when one was used. Without a folder, the editor alone.
fn code_folder(
    store: &SqlCipherBrainStore,
    acc: &ItemAcc,
    held: &[Held],
    about: &[About],
    home: &Home,
) -> Result<Vec<ResumeTarget>, StoreError> {
    let mut editors: HashMap<&str, u64> = HashMap::new();
    let mut terminals: HashMap<&str, u64> = HashMap::new();
    for (window, what) in held.iter().zip(about) {
        let About::Item { identity, .. } = what else {
            continue;
        };
        if *identity != acc.identity {
            continue;
        }
        let time = if TERMINAL_APPS.contains(&window.app.as_str()) {
            &mut terminals
        } else {
            &mut editors
        };
        *time.entry(window.app.as_str()).or_default() += window.held_us();
    }
    let longest = |time: &HashMap<&str, u64>| {
        time.iter()
            .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
            .map(|(app, _)| (*app).to_owned())
    };
    let folder = read::folder_guess(store, acc, home.path.as_deref())?;
    let missing = folder
        .as_deref()
        .is_some_and(|folder| !expand(folder, home).is_dir());
    let mut out = Vec::new();
    for app in [longest(&editors), longest(&terminals)]
        .into_iter()
        .flatten()
    {
        let mut target = ResumeTarget::new("folder", &acc.name, &app);
        target.path.clone_from(&folder);
        if folder.is_none() {
            target = target.because("no_folder");
            target.kind = "app".into();
        } else if missing {
            target = target.because("missing");
        }
        out.push(target);
    }
    Ok(out)
}

/// A path with `~` written out for the person's home folder.
fn expand(path: &str, home: &Home) -> std::path::PathBuf {
    match (path.strip_prefix('~'), home.path.as_deref()) {
        (Some(rest), Some(home)) => Path::new(home).join(rest.trim_start_matches('/')),
        _ => Path::new(path).to_path_buf(),
    }
}

/// The documents, designs and spreadsheets open in the session, the item's
/// own first: through their links on the web, or their app.
fn documents(
    acc: &ItemAcc,
    held: &[Held],
    about: &[About],
    urls: &HashMap<i64, String>,
    kept_out: &KeptOut,
) -> Vec<ResumeTarget> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut windows: Vec<(&Held, &str, &str)> = Vec::new();
    for (window, what) in held.iter().zip(about).rev() {
        let About::Item { identity, subject } = what else {
            continue;
        };
        if subject.kind == SubjectKind::Code
            || kept_out_window(window, urls, kept_out)
            || !seen.insert(identity.clone())
        {
            continue;
        }
        windows.push((window, identity, &subject.name));
    }
    windows.sort_by_key(|(_, identity, _)| *identity != acc.identity);
    windows
        .into_iter()
        .map(|(window, _, name)| {
            if is_browser(Some(&window.app)) {
                let url = window
                    .newest()
                    .and_then(|id| urls.get(&id))
                    .and_then(|url| resume_url(url));
                let mut target = ResumeTarget::new("document", name, &window.app);
                if url.is_none() {
                    return target.because("no_address");
                }
                target.url = url;
                target
            } else if window.app == "com.apple.Notes" {
                ResumeTarget::new("document", name, &window.app).because("single_note")
            } else {
                ResumeTarget::new("document", name, &window.app).because("app_only")
            }
        })
        .collect()
}

/// The web pages open in the session, newest first, one per address: the
/// newest ten ticked. A search's results are never offered.
fn pages(
    held: &[Held],
    about: &[About],
    urls: &HashMap<i64, String>,
    kept_out: &KeptOut,
) -> Vec<ResumeTarget> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out: Vec<ResumeTarget> = Vec::new();
    for (window, what) in held.iter().zip(about).rev() {
        let title = match what {
            About::Page { name, .. } => name.clone(),
            About::AiChat { title, .. } => title.clone(),
            _ => continue,
        };
        if !is_browser(Some(&window.app)) || kept_out_window(window, urls, kept_out) {
            continue;
        }
        let url = window
            .newest()
            .and_then(|id| urls.get(&id))
            .and_then(|url| resume_url(url));
        let key = url
            .clone()
            .unwrap_or_else(|| format!("{}|{title}", window.app));
        if !seen.insert(key) {
            continue;
        }
        let mut target = ResumeTarget::new("page", &title, &window.app);
        match url {
            Some(url) => target.url = Some(url),
            None => target = target.because("no_address"),
        }
        out.push(target);
        if out.len() == MAX_PAGES {
            break;
        }
    }
    let mut ticked = 0;
    for target in &mut out {
        if target.checked {
            ticked += 1;
            target.checked = ticked <= PAGES_TICKED;
        }
    }
    out
}

/// Other apps in front during the session: not a browser, not the item's
/// own editor or terminal, not a call, not Hippocampus, longest first.
fn other_apps(held: &[Held], about: &[About], already: &[ResumeTarget]) -> Vec<ResumeTarget> {
    let taken: HashSet<&str> = already.iter().filter_map(|t| t.app.as_deref()).collect();
    let mut time: HashMap<&str, u64> = HashMap::new();
    for (window, what) in held.iter().zip(about) {
        let app = window.app.as_str();
        let code = matches!(what, About::Item { subject, .. } if subject.kind == SubjectKind::Code);
        if is_browser(Some(app))
            || taken.contains(app)
            || code
            || TERMINAL_APPS.contains(&app)
            || apps::is_noise(app)
            || matches!(app, "com.apple.finder" | "com.apple.systempreferences")
            || apps::kind(app) == WorkKind::Meetings
        {
            continue;
        }
        *time.entry(app).or_default() += window.held_us();
    }
    let mut apps_in_use: Vec<(&str, u64)> = time
        .into_iter()
        .filter(|(_, held)| *held >= APP_MIN_US)
        .collect();
    apps_in_use.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    apps_in_use
        .into_iter()
        .map(|(app, _)| ResumeTarget::new("app", &apps::name(app), app))
        .collect()
}

/// A page's address as Resume opens it: the scheme, host and path, never
/// the query or fragment, which can carry sign-in tokens. A video keeps its
/// `v`, the one part of a query that names the page.
#[must_use]
pub fn resume_url(url: &str) -> Option<String> {
    let (scheme, rest) = url
        .split_once("://")
        .filter(|(scheme, _)| matches!(*scheme, "https" | "http"))?;
    let (place, query) = match rest.split_once('?') {
        Some((place, query)) => (place, Some(query.split('#').next().unwrap_or_default())),
        None => (rest.split('#').next().unwrap_or_default(), None),
    };
    let host = place.split('/').next().unwrap_or_default();
    if host.is_empty() || host.contains('@') {
        return None;
    }
    let mut out = format!("{scheme}://{place}");
    let bare_host = host.to_ascii_lowercase();
    let bare_host = bare_host.strip_prefix("www.").unwrap_or(&bare_host);
    if (bare_host == "youtube.com" || bare_host == "m.youtube.com") && place.ends_with("/watch") {
        if let Some(video) = query.and_then(|query| {
            query
                .split('&')
                .find_map(|pair| pair.strip_prefix("v="))
                .filter(|video| {
                    video
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
                })
        }) {
            out.push_str("?v=");
            out.push_str(video);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| (*arg).to_owned()).collect()
    }

    #[test]
    fn the_item_is_required_and_is_an_id() {
        assert_eq!(item_of(&args(&["--item", "w_9c41e2"])).unwrap(), "w_9c41e2");
        for list in [
            &[][..],
            &["--item"][..],
            &["--item", "--json"][..],
            &["--item", "trailhead shop"][..],
        ] {
            let error = item_of(&args(list)).unwrap_err();
            assert!(matches!(error, ReadError::Usage(_)), "{list:?}");
            assert!(error.to_string().contains("--item"), "{error}");
            assert!(!error.to_string().contains("trailhead"), "{error}");
        }
    }

    #[test]
    fn a_target_is_written_in_the_shape_the_window_reads() {
        let target = ResumeTarget {
            kind: "document".into(),
            title: "Launch checklist".into(),
            app: Some("com.apple.Notes".into()),
            url: None,
            path: None,
            checked: false,
            note: Some("Notes opens the app; Hippocampus can’t open a single note".into()),
            reason: None,
        };
        let value = serde_json::to_value(ResumePlan {
            items: vec![target],
            ..ResumePlan::default()
        })
        .unwrap();
        assert_eq!(value["items"][0]["kind"], "document");
        assert_eq!(value["items"][0]["checked"], false);
        assert!(value.get("item").is_none());
        assert_eq!(
            serde_json::to_value(ResumePlan::default()).unwrap(),
            serde_json::json!({"items": []})
        );
    }

    #[test]
    fn a_reason_that_means_it_cant_open_leaves_it_unticked() {
        let target = ResumeTarget::new("folder", "trailhead-shop", "com.microsoft.VSCode");
        assert!(!target.clone().because("missing").checked);
        assert!(!target.clone().because("no_address").checked);
        assert!(target.clone().because("single_note").checked);
        assert!(target.because("no_folder").checked);
    }

    fn window(app: &str, title: &str, event: i64) -> Held {
        Held {
            start_us: 0,
            end_us: 60_000_000,
            app: app.to_owned(),
            title: Some(title.to_owned()),
            host: None,
            events: vec![event],
            first_line: None,
        }
    }

    fn page(name: &str) -> About {
        About::Page {
            key: name.to_lowercase(),
            name: name.to_owned(),
        }
    }

    const NEVER_READ: &str =
        "[[denylist]]\nkind = \"windowTitleSubstring\"\npattern = \"Payroll\"\n\n\
        [[denylist]]\nkind = \"windowTitleSubstring\"\npattern = \"Google Sheets\"\n\n\
        [[denylist]]\nkind = \"urlPrefix\"\npattern = \"https://bank.example/\"\n\n\
        [[denylist]]\nkind = \"appBundle\"\npattern = \"com.example.Diary\"\n";

    #[test]
    fn a_page_the_never_read_list_names_is_never_offered() {
        let chrome = "com.google.Chrome";
        let windows = [
            window(chrome, "Payroll October", 1),
            window(chrome, "Statements", 2),
            window(chrome, "Headcount - Google Sheets", 3),
            window(chrome, "Rounding half to even", 4),
        ];
        let about = [
            page("Payroll October"),
            page("Statements"),
            page("Headcount"),
            page("Rounding half to even"),
        ];
        let urls = HashMap::from([
            (1, "https://payroll.example/october".to_owned()),
            (2, "https://bank.example/statements?month=10".to_owned()),
            (
                3,
                "https://docs.google.com/spreadsheets/d/heads/edit".to_owned(),
            ),
            (4, "https://devnotes.example/rounding".to_owned()),
        ]);
        let offered = |kept_out: &KeptOut| -> Vec<String> {
            pages(&windows, &about, &urls, kept_out)
                .into_iter()
                .map(|target| target.title)
                .collect()
        };
        // By a part of its title, its address, or its title as it was on
        // screen even when the page's own name doesn't hold the words.
        assert_eq!(
            offered(&KeptOut::parse(NEVER_READ)),
            ["Rounding half to even"]
        );
        assert_eq!(offered(&KeptOut::default()).len(), 4, "no list, no change");
    }

    #[test]
    fn every_target_the_never_read_list_names_is_left_out() {
        let mut targets = vec![
            ResumeTarget::new("folder", "payroll-tools", "com.microsoft.VSCode"),
            ResumeTarget::new("app", "Diary", "com.example.Diary"),
            ResumeTarget::new("document", "Payroll October", "com.apple.Notes"),
            ResumeTarget::new("app", "Slack", "com.tinyspeck.slackmacgap"),
        ];
        leave_out(&mut targets, &KeptOut::parse(NEVER_READ));
        let titles: Vec<&str> = targets.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(
            titles,
            ["payroll-tools", "Slack"],
            "titles match as written"
        );
    }

    #[test]
    fn resume_opens_an_address_without_its_query_or_fragment() {
        assert_eq!(
            resume_url("https://devnotes.example/rounding?utm=x&token=secret#top").as_deref(),
            Some("https://devnotes.example/rounding")
        );
        assert_eq!(
            resume_url("https://docs.google.com/document/d/abc123/edit?tab=t.0#heading=h.1")
                .as_deref(),
            Some("https://docs.google.com/document/d/abc123/edit")
        );
        assert_eq!(
            resume_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42").as_deref(),
            Some("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        );
        assert_eq!(
            resume_url("http://localhost:3000/").as_deref(),
            Some("http://localhost:3000/")
        );
        assert_eq!(resume_url("file:///Users/dev/notes.txt"), None);
        assert_eq!(resume_url("javascript:alert(1)"), None);
        assert_eq!(
            resume_url("https://user:pass@example.com/"),
            None,
            "never credentials"
        );
    }
}
