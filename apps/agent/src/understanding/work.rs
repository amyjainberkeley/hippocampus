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
//! A seam for now: the answer is always empty, which the window shows as no
//! Working On items and Web Pages' fallback. The subject rules
//! (`mci_brain::subject`), membership, ranking and the item ids land with
//! Working On.

use std::collections::BTreeMap;

use mci_brain::subject::SubjectKind;
use serde::Serialize;

use super::{ReadCommand, ReadError};

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
    /// The bundle ids of the apps it was worked on in.
    pub apps: Vec<String>,
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

/// `mci-agent work`: the answer as JSON.
///
/// # Errors
/// [`ReadError::Usage`] for a malformed flag; never anything read.
pub fn run_cli(command: &ReadCommand<'_>) -> Result<serde_json::Value, ReadError> {
    WorkArgs::parse(command.args)?;
    let work = Work {
        generated_us: command.now_us,
        ..Work::default()
    };
    serde_json::to_value(work).map_err(|_| ReadError::Failed("work could not be written".into()))
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
        };
        let value = serde_json::to_value(&item).unwrap();
        assert_eq!(value["kind"], "code");
        assert_eq!(value["thumbnail_moment"], 4790);
        assert_eq!(value["files"][0]["moment"], 4790);
        assert_eq!(value["hidden_reason"], serde_json::Value::Null);
    }
}
