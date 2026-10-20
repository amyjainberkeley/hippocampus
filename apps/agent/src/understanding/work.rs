//! `mci-agent work --json`: what the person is working on, made from the
//! window titles the session notes keep (SPEC 3.12.2).
//!
//! It answers three things for the window: which code projects, documents,
//! designs and spreadsheets Working On lists (`items`, each with its files,
//! what was open alongside it, a guess at its folder, its moments and the
//! moment whose screenshot is its thumbnail), which pages Web Pages lists
//! (`pages`), and, with `--moments`, which item each of those moments is part
//! of (`moment_items`). `--item <id>` reads one item, its moments 200 at a
//! time, older than `--before <ts_us>`. Nothing is written.
//!
//! Membership follows SPEC 2.3: a code project, document, design or
//! spreadsheet is an item once it was the window in front for 30 minutes in
//! all, and the sidebar lists it while it has 30 minutes within the last 14
//! days of use (a day of use is a day with anything saved). Items rank by
//! their time in the last 7 days of use, then by the newest. A name that
//! touches a sensitive area stays out of the sidebar (`hidden_reason`
//! "personal"); hides the person chose are the window's own.
//!
//! It reads the session notes the understanding worker writes, with or
//! without a model, and the moments after the last note, and only their
//! window titles, hosts and moment ids ([`read`]). Deleting a moment deletes
//! the notes around it, so an item rebuilds without it on the next read and
//! leaves when nothing of it is left.

pub(crate) mod read;

use std::collections::BTreeMap;
use std::path::Path;

use mci_brain::sensitive::sensitive_area;
use mci_brain::subject::SubjectKind;
use mci_brain::{SqlCipherBrainStore, StoreError};
use mci_core::crypto::DbKey;
use serde::Serialize;

use super::{ReadCommand, ReadError};
use read::{ItemAcc, Model, DAY_US, ITEM_US};

/// How many days back the read looks unless asked.
pub const DEFAULT_DAYS: u32 = 90;
/// The most days back it looks.
pub const MAX_DAYS: u32 = 400;
/// An item's moments per answer: the newest, and one page with `--item`.
pub const MOMENTS_PER_PAGE: usize = 200;
/// A page's moments per answer.
pub const PAGE_MOMENTS: usize = 50;
/// The most pages an answer lists.
pub const MAX_PAGES: usize = 1_000;
/// The most files a code project lists.
pub const MAX_FILES: usize = 30;
/// Seen alongside and conversations: six rows at most.
pub const MAX_ALONGSIDE: usize = 6;
/// An item's sessions listed with `--item`, newest first.
pub const MAX_SESSIONS: usize = 100;

/// The longest id an item can have. Ids are keyed hashes, so they are short.
pub const MAX_ITEM_ID_LEN: usize = 64;

/// The `work` read, as the window decodes it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Work {
    /// When this answer was made, in microseconds since the epoch.
    pub generated_us: u64,
    /// Working On's items, most time in the last 7 days of use first.
    pub items: Vec<WorkItem>,
    /// Web Pages' pages, newest first.
    pub pages: Vec<WorkPage>,
    /// For `--moments`: the item each moment is part of, by moment id.
    pub moment_items: BTreeMap<String, String>,
}

/// One project or document Working On lists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkItem {
    /// A keyed hash of its kind and name: stable on this Mac, meaningless on
    /// any other, so links carry ids and never names.
    pub id: String,
    /// What kind of thing it is: never a page or a search.
    pub kind: SubjectKind,
    /// Its name, as its windows' titles write it.
    pub name: String,
    /// The bundle ids of the apps it was worked on in, most time first.
    pub apps: Vec<String>,
    /// The sites it was worked on at, most time first: a document on the
    /// web ("docs.google.com"). Empty for one in its own app.
    pub hosts: Vec<String>,
    /// When it was last worked on.
    pub last_us: u64,
    /// Minutes in front in the last 7 days of use.
    pub week_minutes: u32,
    /// Days of the last 7 days of use it was worked on.
    pub days_this_week: u32,
    /// Whether the sidebar lists it.
    pub in_sidebar: bool,
    /// Why the sidebar does not, when it is the name's own: `"personal"`.
    pub hidden_reason: Option<String>,
    /// For code, the files its editors' titles named, newest first.
    pub files: Vec<WorkFile>,
    /// Pages, searches and AI chats open around the same time.
    pub alongside: Vec<WorkAlongside>,
    /// For code, the folder it seems to be in, with `~` for home.
    pub folder_guess: Option<String>,
    /// Its moment ids, newest first.
    pub moments: Vec<u64>,
    /// The moment whose kept screenshot is its thumbnail in the sidebar, its
    /// hover preview and Show All (SPEC-DELTA 2): its newest moment with a
    /// screenshot, when it has one.
    pub thumbnail_moment: Option<u64>,
    /// Minutes in front over everything read: what Show All says for an
    /// item from before this week.
    pub total_minutes: u32,
    /// Conversations open around the same time, by name only (SPEC-DELTA 4).
    pub conversations: Vec<WorkConversation>,
    /// With `--item`: its sessions' own times, newest first, so the window
    /// can list the meetings that overlapped them.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sessions: Vec<WorkSession>,
}

/// A conversation with people open around the same time as an item: its
/// name, never what was said.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkConversation {
    /// "#launch", "Jordan Lee", an email's subject.
    pub name: String,
    /// The bundle id of the app it was open in.
    pub app: String,
    /// Its newest moment.
    pub moment: u64,
    /// When it was last open.
    pub last_us: u64,
}

/// One of an item's sessions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct WorkSession {
    /// When it started, in microseconds since the epoch.
    pub start_us: u64,
    /// When its last moment was.
    pub end_us: u64,
}

/// A file a code project's editor titles named.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkFile {
    /// The file's name.
    pub name: String,
    /// When it was last in front.
    pub last_us: u64,
    /// Its newest moment.
    pub moment: u64,
}

/// A page, search or AI chat open around the same time as an item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkAlongside {
    /// `"page"`, `"search"` or `"ai_chat"`.
    pub kind: String,
    /// Its caption's subject: the page's or the chat's title, or the query.
    pub title: String,
    /// The page's host, when known.
    pub host: Option<String>,
    /// The bundle id of the app it was open in.
    pub app: String,
    /// Its newest moment.
    pub moment: u64,
    /// When it was last open.
    pub last_us: u64,
}

/// A page Web Pages lists: one row per address across days.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkPage {
    /// The page's title.
    pub title: String,
    /// Its host, when the address is known.
    pub host: Option<String>,
    /// Its path, without the query and fragment.
    pub path: Option<String>,
    /// The bundle id of the browser it was read in.
    pub app: String,
    /// On how many days it was read.
    pub days: u32,
    /// When it was last read.
    pub last_us: u64,
    /// Its moment ids, newest first.
    pub moments: Vec<u64>,
}

/// What `work` was asked: `--days N`, `--item ID` with `--before TS_US`,
/// and `--moments ID,ID`. Flags it doesn't know are left alone, as every
/// read of the window's does, since the window and the agent ship apart.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkArgs {
    /// How many days back to read; the default is 90.
    pub days: Option<u32>,
    /// One item, by id.
    pub item: Option<String>,
    /// For one item: only moments older than this, in microseconds.
    pub before_us: Option<u64>,
    /// Moments to say the items of.
    pub moments: Vec<u64>,
}

impl WorkArgs {
    /// Read `work`'s own flags out of `args`. A flag without a value, or
    /// with one that is not the right kind, is an error that names the flag
    /// and never repeats the value.
    ///
    /// # Errors
    /// [`ReadError::Usage`] for a missing or malformed value.
    pub fn parse(args: &[String]) -> Result<Self, ReadError> {
        let mut parsed = Self::default();
        let mut i = 0;
        while i < args.len() {
            let flag = args[i].as_str();
            if matches!(flag, "--days" | "--item" | "--before" | "--moments") {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| ReadError::Usage(format!("{flag} requires a value")))?;
                match flag {
                    "--days" => {
                        parsed.days = Some(value.parse().map_err(|_| {
                            ReadError::Usage("--days must be a number of days".into())
                        })?);
                    }
                    "--item" => {
                        if !is_item_id(value) {
                            return Err(ReadError::Usage(
                                "--item must be an item's id, as the work read gives it".into(),
                            ));
                        }
                        parsed.item = Some(value.clone());
                    }
                    "--before" => {
                        parsed.before_us = Some(value.parse().map_err(|_| {
                            ReadError::Usage("--before must be microseconds since the epoch".into())
                        })?);
                    }
                    _ => {
                        parsed.moments = value
                            .split(',')
                            .filter(|id| !id.trim().is_empty())
                            .map(|id| id.trim().parse::<u64>())
                            .collect::<Result<_, _>>()
                            .map_err(|_| {
                                ReadError::Usage("--moments must be moment ids, with commas".into())
                            })?;
                    }
                }
                i += 1;
            }
            i += 1;
        }
        Ok(parsed)
    }
}

/// Whether `id` has the shape of an item's id: 1 to [`MAX_ITEM_ID_LEN`]
/// ASCII letters, digits, `_` and `-`, not starting with `-`, so it never
/// reads as a flag. A name never passes, so a link or a request can never
/// carry one in an id's place.
#[must_use]
pub fn is_item_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ITEM_ID_LEN
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// Where the person's home folder is, for "~" in folder guesses and for the
/// subject rules (a terminal open there names nothing).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Home {
    /// The whole path: "/Users/dev".
    pub path: Option<String>,
    /// Its last part: "dev".
    pub name: Option<String>,
}

impl Home {
    /// This process's `HOME`.
    #[must_use]
    pub fn from_env() -> Self {
        std::env::var("HOME").map_or_else(|_| Self::default(), |path| Self::at(&path))
    }

    /// A home folder at `path`.
    #[must_use]
    pub fn at(path: &str) -> Self {
        let name = Path::new(path)
            .file_name()
            .and_then(|name| name.to_str())
            .map(str::to_lowercase)
            .filter(|name| !name.is_empty());
        Self {
            path: Some(path.to_owned()).filter(|path| !path.is_empty()),
            name,
        }
    }
}

/// `mci-agent work`: the answer as JSON.
///
/// # Errors
/// [`ReadError::Usage`] for a malformed flag, [`ReadError::Failed`] when the
/// memory can't be read; neither repeats a value or anything read.
pub fn run_cli(command: &ReadCommand<'_>) -> Result<serde_json::Value, ReadError> {
    let args = WorkArgs::parse(command.args)?;
    let work = read_work(
        command.store,
        command.key,
        &args,
        command.tz_offset_secs,
        command.now_us,
        &Home::from_env(),
    )
    .map_err(|_| ReadError::Failed("work could not be read from the memory".into()))?;
    serde_json::to_value(work).map_err(|_| ReadError::Failed("work could not be written".into()))
}

/// The `work` read: the whole answer, one item with a page of its moments
/// (`--item`, `--before`), or the items some moments are part of
/// (`--moments`).
///
/// # Errors
/// Store failures.
pub fn read_work(
    store: &SqlCipherBrainStore,
    key: &DbKey,
    args: &WorkArgs,
    tz: i32,
    now_us: u64,
    home: &Home,
) -> Result<Work, StoreError> {
    let model = model(store, key, args.days, tz, now_us, home)?;
    let mut work = Work {
        generated_us: now_us,
        ..Work::default()
    };
    if let Some(wanted) = &args.item {
        if let Some((id, acc)) = model.items.iter().find(|(id, _)| id == wanted) {
            let page = Moments::Page {
                before_us: args.before_us,
            };
            work.items.push(item(store, &model, id, acc, home, page)?);
        }
    } else if !args.moments.is_empty() {
        work.moment_items = read::moment_items(&model, &args.moments);
    } else {
        for (id, acc) in &model.items {
            work.items
                .push(item(store, &model, id, acc, home, Moments::Newest)?);
        }
        work.pages = read::pages(store, &model, tz, MAX_PAGES)?
            .into_iter()
            .map(|page| WorkPage {
                title: page.title,
                host: page.host,
                path: page.path,
                app: page.app,
                days: u32::try_from(page.days.len()).unwrap_or(u32::MAX),
                last_us: page.last_us,
                moments: page
                    .moments
                    .iter()
                    .take(PAGE_MOMENTS)
                    .filter_map(|moment| u64::try_from(moment.1).ok())
                    .collect(),
            })
            .collect();
    }
    Ok(work)
}

/// The sessions over `days` (90 unless asked) and what they were about.
pub(crate) fn model(
    store: &SqlCipherBrainStore,
    key: &DbKey,
    days: Option<u32>,
    tz: i32,
    now_us: u64,
    home: &Home,
) -> Result<Model, StoreError> {
    let days = u64::from(days.unwrap_or(DEFAULT_DAYS).clamp(1, MAX_DAYS));
    read::build(
        store,
        key,
        now_us.saturating_sub(days * DAY_US),
        now_us,
        tz,
        home.name.as_deref(),
    )
}

/// Whole minutes in `us`, rounded.
fn minutes(us: u64) -> u32 {
    u32::try_from((us + 30_000_000) / 60_000_000).unwrap_or(u32::MAX)
}

/// Which of an item's moments an answer carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Moments {
    /// Its newest, for Working On and the sidebar.
    Newest,
    /// One page of them for its own page: older than `before_us`, or the
    /// newest without it, with its sessions.
    Page { before_us: Option<u64> },
}

/// One item as the window reads it.
fn item(
    store: &SqlCipherBrainStore,
    model: &Model,
    id: &str,
    acc: &ItemAcc,
    home: &Home,
    paging: Moments,
) -> Result<WorkItem, StoreError> {
    let kind = acc.kind.unwrap_or(SubjectKind::Document);
    let newest: Vec<i64> = acc.moments.iter().map(|moment| moment.1).collect();
    let (thumbnail, newest_us) = read::newest_with_screenshot(store, &newest, 256)?;
    let mut apps: Vec<(&String, &u64)> = acc.apps.iter().collect();
    apps.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    let mut files: Vec<&(String, u64, i64)> = acc.files.values().collect();
    files.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let personal = sensitive_area(&acc.name).is_some();
    let moments: Vec<u64> = match paging {
        Moments::Newest => newest
            .iter()
            .take(MOMENTS_PER_PAGE)
            .filter_map(|id| u64::try_from(*id).ok())
            .collect(),
        Moments::Page { before_us } => {
            let mut heads = Vec::new();
            for batch in newest.chunks(500) {
                heads.extend(store.event_heads(batch)?);
            }
            heads.sort_by(|a, b| b.ts_us.cmp(&a.ts_us).then(b.id.cmp(&a.id)));
            heads
                .into_iter()
                .filter(|head| before_us.is_none_or(|before| head.ts_us < before))
                .take(MOMENTS_PER_PAGE)
                .filter_map(|head| u64::try_from(head.id).ok())
                .collect()
        }
    };
    let sessions = if paging == Moments::Newest {
        Vec::new()
    } else {
        acc.sessions
            .iter()
            .rev()
            .take(MAX_SESSIONS)
            .map(|index| WorkSession {
                start_us: model.sessions[*index].start_us,
                end_us: model.sessions[*index].end_us,
            })
            .collect()
    };
    Ok(WorkItem {
        id: id.to_owned(),
        kind,
        name: acc.name.clone(),
        apps: apps.into_iter().map(|(app, _)| app.clone()).collect(),
        hosts: {
            let mut hosts: Vec<(&String, &u64)> = acc.hosts.iter().collect();
            hosts.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
            hosts.into_iter().map(|(host, _)| host.clone()).collect()
        },
        last_us: newest_us.unwrap_or(acc.last_us),
        week_minutes: minutes(acc.week_us),
        days_this_week: u32::try_from(acc.week_days.len()).unwrap_or(u32::MAX),
        in_sidebar: !personal && acc.fortnight_us >= ITEM_US,
        hidden_reason: personal.then(|| "personal".to_owned()),
        files: files
            .into_iter()
            .take(MAX_FILES)
            .map(|(name, last_us, moment)| WorkFile {
                name: name.clone(),
                last_us: *last_us,
                moment: u64::try_from(*moment).unwrap_or(0),
            })
            .collect(),
        alongside: read::near(model, acc, false, MAX_ALONGSIDE)
            .into_iter()
            .map(|near| WorkAlongside {
                kind: near.kind.to_owned(),
                title: near.title,
                host: near.host,
                app: near.app,
                moment: u64::try_from(near.moment).unwrap_or(0),
                last_us: near.last_us,
            })
            .collect(),
        folder_guess: if kind == SubjectKind::Code {
            read::folder_guess(store, acc, home.path.as_deref())?
        } else {
            None
        },
        moments,
        thumbnail_moment: thumbnail.and_then(|id| u64::try_from(id).ok()),
        total_minutes: minutes(acc.total_us),
        conversations: read::near(model, acc, true, MAX_ALONGSIDE)
            .into_iter()
            .map(|near| WorkConversation {
                name: near.title,
                app: near.app,
                moment: u64::try_from(near.moment).unwrap_or(0),
                last_us: near.last_us,
            })
            .collect(),
        sessions,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| (*arg).to_owned()).collect()
    }

    #[test]
    fn the_flags_read_as_the_spec_writes_them() {
        let parsed = WorkArgs::parse(&args(&[
            "--days",
            "14",
            "--item",
            "w_9c41e2",
            "--before",
            "1760304000000000",
            "--moments",
            "4812,4790, 4777",
        ]))
        .unwrap();
        assert_eq!(
            parsed,
            WorkArgs {
                days: Some(14),
                item: Some("w_9c41e2".into()),
                before_us: Some(1_760_304_000_000_000),
                moments: vec![4812, 4790, 4777],
            }
        );
        assert_eq!(WorkArgs::parse(&args(&[])).unwrap(), WorkArgs::default());
        assert_eq!(
            WorkArgs::parse(&args(&["--some-future-flag"])).unwrap(),
            WorkArgs::default(),
            "flags it doesn't know are left alone"
        );
    }

    #[test]
    fn a_bad_value_names_the_flag_and_never_the_value() {
        for (list, flag) in [
            (&["--days"][..], "--days"),
            (&["--days", "secret-words"][..], "--days"),
            (&["--before", "secret-words"][..], "--before"),
            (&["--moments", "1,secret-words"][..], "--moments"),
            (&["--item", "secret words"][..], "--item"),
        ] {
            let error = WorkArgs::parse(&args(list)).unwrap_err();
            assert!(matches!(error, ReadError::Usage(_)), "{error}");
            let words = error.to_string();
            assert!(words.contains(flag), "{words}");
            assert!(!words.contains("secret"), "{words}");
        }
    }

    #[test]
    fn only_an_id_can_name_an_item() {
        for id in ["w_9c41e2", "W-1", "a", &"a".repeat(MAX_ITEM_ID_LEN)] {
            assert!(is_item_id(id), "{id}");
        }
        for id in [
            "",
            "--json",
            "-w1",
            "trailhead shop",
            "a/b",
            "../x",
            "é",
            "a.b",
            &"a".repeat(MAX_ITEM_ID_LEN + 1),
        ] {
            assert!(!is_item_id(id), "{id}");
        }
    }

    #[test]
    fn an_item_is_written_in_the_shape_the_window_reads() {
        let item = WorkItem {
            id: "w_9c41e2".into(),
            kind: SubjectKind::Code,
            name: "trailhead-shop".into(),
            apps: vec!["com.microsoft.VSCode".into()],
            hosts: Vec::new(),
            last_us: 1_760_304_000_000_000,
            week_minutes: 160,
            days_this_week: 3,
            in_sidebar: true,
            hidden_reason: None,
            files: vec![WorkFile {
                name: "tax.rs".into(),
                last_us: 1_760_304_000_000_000,
                moment: 4790,
            }],
            alongside: Vec::new(),
            folder_guess: Some("~/dev/trailhead-shop".into()),
            moments: vec![4812, 4790],
            thumbnail_moment: Some(4790),
            total_minutes: 160,
            conversations: Vec::new(),
            sessions: Vec::new(),
        };
        let value = serde_json::to_value(&item).unwrap();
        assert_eq!(value["kind"], "code");
        assert_eq!(value["thumbnail_moment"], 4790);
        assert_eq!(value["files"][0]["moment"], 4790);
        assert_eq!(value["hidden_reason"], serde_json::Value::Null);
        assert!(value.get("sessions").is_none(), "only with --item");
        assert_eq!(value["conversations"], serde_json::json!([]));
    }

    #[test]
    fn a_home_names_its_last_part() {
        assert_eq!(Home::at("/Users/Dev").name.as_deref(), Some("dev"));
        assert_eq!(Home::at("/Users/Dev").path.as_deref(), Some("/Users/Dev"));
        assert_eq!(Home::at(""), Home::default());
    }
}
