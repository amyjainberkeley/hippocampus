//! What a window is about: the code project, document, design,
//! spreadsheet, page or search its title names (SPEC 3.12.1).
//!
//! [`subject_of`] reads only what a caption reads: the app, the window's
//! title, the page's host and the first line of what was on screen. It shares
//! the caption rules' title cleaning (`caption.rs`: `title_segments`,
//! `TITLE_SUFFIXES`, `GENERIC`, `first_heading`), so a Working On name and a
//! History caption can never disagree. No model is asked anything, and when
//! unsure there is no subject.
//!
//! - **Code projects** come from editors' titles ("● tax.rs — trailhead-shop —
//!   Visual Studio Code" is trailhead-shop, file tax.rs) and from terminals,
//!   only through a folder ("trailhead-shop — -zsh — 160×40",
//!   "~/dev/trailhead-shop"). An AI tool's own terminal title ("✳ Claude
//!   Code", "claude", "codex", or anything while one runs) is never a name.
//! - **Documents** are docs, notes, slides and PDFs: the first part of the
//!   title without its extension, or for Notes, whose title is only "Notes",
//!   the note's first line.
//! - **Designs** and **spreadsheets** come from their apps and sites.
//! - **Pages** are other web pages (Web Pages lists them, Working On never
//!   does) and **searches** are result pages (Looked Up lists them).
//!
//! A name is never generic ("Untitled", "New Tab", "Inbox", a shell's name,
//! the home folder, "localhost"), never shorter than three letters, never a
//! line the secret check stops, and never one of Hippocampus's own windows.
//! Whether a name touches a sensitive area is the `work` read's question
//! ([`crate::sensitive::sensitive_area`]): such an item is kept out of the
//! sidebar, not out of memory.

use serde::{Deserialize, Serialize};

use crate::apps::{self, WorkKind};
use crate::caption::{
    first_heading, is_mailbox, is_slack_view, slack_place, title_segments, without_reply_marks,
    BLANK_PAGES, GENERIC, SEARCH_TITLE_ENDS, TITLE_SUFFIXES,
};
use crate::chrome::{is_browser, without_title_marks};
use crate::reading::TERMINAL_APPS;
use crate::redaction::ocr_secrets::contains_secret;
use crate::{SqlCipherBrainStore, StoreError};

/// What kind of thing a window is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubjectKind {
    /// A folder of code an editor or a terminal is open in.
    Code,
    /// Docs, notes, slides and PDFs.
    Document,
    /// A design.
    Design,
    /// A spreadsheet.
    Spreadsheet,
    /// A web page. Web Pages lists it; it is never a Working On item.
    Page,
    /// A search. Looked Up lists it.
    Search,
}

impl SubjectKind {
    /// The name in JSON (`code`, `document`, …).
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Code => "code",
            Self::Document => "document",
            Self::Design => "design",
            Self::Spreadsheet => "spreadsheet",
            Self::Page => "page",
            Self::Search => "search",
        }
    }

    /// Whether Working On can list it: code projects, documents, designs
    /// and spreadsheets. Pages and searches never are items.
    #[must_use]
    pub fn is_item(self) -> bool {
        matches!(
            self,
            Self::Code | Self::Document | Self::Design | Self::Spreadsheet
        )
    }
}

/// What a window is about: its kind, its name, and for code, the file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subject {
    /// What kind of thing it is.
    pub kind: SubjectKind,
    /// Its name as the title writes it: "trailhead-shop", "Q4 planning".
    pub name: String,
    /// The part of it the window shows: for code, the file ("tax.rs").
    pub part: Option<String>,
}

/// The fewest letters and digits a name has.
pub const MIN_NAME_CHARS: usize = 3;
/// The longest name kept, in characters: the window cuts what it shows.
pub const MAX_NAME_CHARS: usize = 200;

/// Editors whose title is "file — folder — App" (VS Code's own form).
const VS_CODE_FAMILY: &[&str] = &[
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.vscodium",
    "com.todesktop.230313mzl4w4u92", // Cursor
    "com.exafunction.windsurf",
];
const ZED: &str = "dev.zed.Zed";
const XCODE: &str = "com.apple.dt.Xcode";
const SUBLIME: &str = "com.sublimetext.4";
const ANDROID_STUDIO: &str = "com.google.android.studio";
const NOTES: &str = "com.apple.Notes";

/// Writing apps whose title names the document.
const DOCUMENT_APPS: &[&str] = &[
    "com.apple.iWork.Pages",
    "com.microsoft.Word",
    "com.apple.TextEdit",
    "md.obsidian",
    "notion.id",
    "net.shinyfrog.bear",
    "com.ulyssesapp.mac",
    "com.apple.iWork.Keynote",
    "com.microsoft.Powerpoint",
    "com.microsoft.onenote.mac",
];
/// PDF readers, whose title is the file name and the page.
const PDF_APPS: &[&str] = &[
    "com.apple.Preview",
    "com.readdle.PDFExpert-Mac",
    "com.adobe.Acrobat.Pro",
    "com.adobe.Reader",
];
/// Design apps.
const DESIGN_APPS: &[&str] = &[
    "com.figma.Desktop",
    "com.bohemiancoding.sketch3",
    "com.adobe.Photoshop",
    "com.adobe.illustrator",
    "com.canva.CanvaDesktop",
];
/// Spreadsheet apps.
const SPREADSHEET_APPS: &[&str] = &["com.apple.iWork.Numbers", "com.microsoft.Excel"];

/// Extensions a document's title may end with, and its name never keeps.
const EXTENSIONS: &[&str] = &[
    ".pages",
    ".docx",
    ".doc",
    ".rtf",
    ".rtfd",
    ".txt",
    ".md",
    ".markdown",
    ".key",
    ".pptx",
    ".ppt",
    ".numbers",
    ".xlsx",
    ".xls",
    ".csv",
    ".tsv",
    ".pdf",
    ".sketch",
    ".psd",
    ".ai",
    ".fig",
    ".odt",
    ".ods",
    ".odp",
];

/// Sites of documents, designs and spreadsheets, by host.
const DOCUMENT_HOSTS: &[&str] = &[
    "notion.so",
    "notion.site",
    "coda.io",
    "quip.com",
    "paper.dropbox.com",
];
const DESIGN_HOSTS: &[&str] = &["figma.com", "canva.com"];

/// Title endings that say what a page in a browser is, when the address
/// is not known.
const WEB_ENDINGS: &[(&str, SubjectKind)] = &[
    (" - Google Docs", SubjectKind::Document),
    (" - Google Slides", SubjectKind::Document),
    (" - Google Sheets", SubjectKind::Spreadsheet),
    (" \u{2013} Figma", SubjectKind::Design),
    (" - Figma", SubjectKind::Design),
    (" - Canva", SubjectKind::Design),
    (" | Notion", SubjectKind::Document),
    (" - Notion", SubjectKind::Document),
    (" - Coda", SubjectKind::Document),
    (" - Quip", SubjectKind::Document),
    (" - Dropbox Paper", SubjectKind::Document),
];

/// The names web apps end their titles with: mail, chat, calendars, calls,
/// AI chats and planning tools are never pages.
const WEB_APP_ENDINGS: &[&str] = &[
    "gmail",
    "outlook",
    "slack",
    "discord",
    "whatsapp",
    "messenger",
    "google calendar",
    "calendar",
    "google meet",
    "meet",
    "zoom",
    "microsoft teams",
    "teams",
    "claude",
    "chatgpt",
    "gemini",
    "perplexity",
    "linear",
    "asana",
    "trello",
    "jira",
];

/// Names that never name anything: blank documents and pages, places in an
/// app, folders every Mac has, shells, AI tools' own terminal titles and
/// Hippocampus. Compared in lower case.
const NEVER: &[&str] = &[
    "untitled",
    "untitled document",
    "untitled spreadsheet",
    "untitled presentation",
    "untitled folder",
    "new tab",
    "new window",
    "new document",
    "new note",
    "new page",
    "start page",
    "welcome",
    "get started",
    "getting started",
    "inbox",
    "home",
    "dashboard",
    "settings",
    "preferences",
    "downloads",
    "desktop",
    "documents",
    "applications",
    "library",
    "recents",
    "recent",
    "drafts",
    "favorites",
    "shared",
    "trash",
    "blank",
    "blank page",
    "quick note",
    "all icloud",
    "on my mac",
    "zsh",
    "-zsh",
    "bash",
    "-bash",
    "fish",
    "-fish",
    "sh",
    "-sh",
    "tmux",
    "localhost",
    "claude",
    "claude code",
    "codex",
    "hippocampus",
    "terminal",
    "finder",
    "community",
    "explore community",
    "workspace",
];

/// Processes whose own titles a terminal shows: AI tools, while they run.
const AI_PROCESSES: &[&str] = &["claude", "claude code", "codex", "aider", "gemini"];

/// Shells and processes that are a terminal's own, never a folder.
const SHELLS: &[&str] = &[
    "zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "login", "tmux", "screen",
];

/// What the window titled `title` in `app` (a bundle id) is about, with the
/// page's `host` and the `first_line` of its text when they are known.
/// `None` when unsure.
#[must_use]
pub fn subject_of(
    app: Option<&str>,
    title: Option<&str>,
    host: Option<&str>,
    first_line: Option<&str>,
) -> Option<Subject> {
    subject_of_at(app, title, host, first_line, home_folder_name())
}

/// [`subject_of`] for a person whose home folder is named `home` ("dev"
/// for /Users/dev): a terminal open there names no project. The `work`
/// read and tests name it; [`subject_of`] reads `HOME` once.
#[must_use]
pub fn subject_of_at(
    app: Option<&str>,
    title: Option<&str>,
    host: Option<&str>,
    first_line: Option<&str>,
    home: Option<&str>,
) -> Option<Subject> {
    let app = app?.trim();
    if app.is_empty() || is_hippocampus(app) || apps::is_noise(app) {
        return None;
    }
    let raw = without_title_marks(title.unwrap_or_default()).trim();
    let host = host.map(normalize_host).filter(|host| !host.is_empty());
    let subject = if is_browser(Some(app)) {
        web(raw, host.as_deref())
    } else if VS_CODE_FAMILY.contains(&app) {
        vs_code(raw, app)
    } else if app == ZED {
        zed(raw)
    } else if app.starts_with("com.jetbrains.") || app == ANDROID_STUDIO {
        jetbrains(raw, app)
    } else if app == XCODE {
        xcode(raw)
    } else if app == SUBLIME {
        sublime(raw)
    } else if TERMINAL_APPS.contains(&app) {
        terminal_folder_at(raw, home)
            .filter(|folder| folder.sure)
            .map(|folder| code(folder.name, None))
    } else if app == NOTES {
        first_line.and_then(first_heading).map(|name| Subject {
            kind: SubjectKind::Document,
            name,
            part: None,
        })
    } else if DOCUMENT_APPS.contains(&app) {
        named_first(raw, app, SubjectKind::Document)
    } else if PDF_APPS.contains(&app) {
        pdf(raw, app)
    } else if DESIGN_APPS.contains(&app) {
        design(raw, app)
    } else if SPREADSHEET_APPS.contains(&app) {
        named_first(raw, app, SubjectKind::Spreadsheet)
    } else {
        None
    };
    subject.and_then(|subject| accepted(subject, home))
}

/// One subject's identity across windows and days: its kind and its name in
/// lower case, its spaces collapsed and invisible marks left out. Two
/// windows with one identity are one item.
#[must_use]
pub fn identity(kind: SubjectKind, name: &str) -> String {
    format!("{}:{}", kind.as_str(), folded(name))
}

/// A name as identities compare it.
#[must_use]
pub fn folded(name: &str) -> String {
    name.chars()
        .filter(|ch| !is_invisible(*ch))
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether `name` could never name an item or a page: blank, generic, a
/// shell, an AI tool, the home folder, under three letters, or held back by
/// the secret check.
#[must_use]
pub fn is_never_a_name(name: &str) -> bool {
    is_never_a_name_at(name, home_folder_name())
}

/// [`is_never_a_name`] for a person whose home folder is named `home`.
#[must_use]
pub fn is_never_a_name_at(name: &str, home: Option<&str>) -> bool {
    let folded = folded(name);
    if folded.chars().filter(|ch| ch.is_alphanumeric()).count() < MIN_NAME_CHARS {
        return true;
    }
    let bare = folded.trim_matches(|ch: char| !ch.is_alphanumeric() && ch != '-');
    NEVER.contains(&bare)
        || NEVER.contains(&folded.as_str())
        || BLANK_PAGES.contains(&bare)
        || TITLE_SUFFIXES.contains(&bare)
        || GENERIC.contains(&bare)
        || is_untitled(bare)
        || is_default_document(bare)
        || home.is_some_and(|home| home.to_lowercase() == bare)
        || bare == "~"
        || folded.starts_with("welcome to ")
        || contains_secret(name)
}

/// A folder a terminal's title names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalFolder {
    /// Its path as the title writes it ("~/dev/trailhead-shop/apps/web"),
    /// when the title holds a path.
    pub path: Option<String>,
    /// The folder's own name: the path's last part, or the name Terminal's
    /// "folder — shell — size" title starts with.
    pub name: String,
    /// The title is surely a folder (a path, or Terminal's own form), not a
    /// command or a program's title. A bare word is never sure: it counts
    /// only as a name an editor already uses.
    pub sure: bool,
}

/// The folder a terminal's title names, if any. Never one while an AI tool
/// runs in it, and never a shell, a command or the home folder.
#[must_use]
pub fn terminal_folder(title: &str) -> Option<TerminalFolder> {
    terminal_folder_at(title, home_folder_name())
}

/// [`terminal_folder`] for a person whose home folder is named `home`.
#[must_use]
pub fn terminal_folder_at(title: &str, home: Option<&str>) -> Option<TerminalFolder> {
    let raw = without_title_marks(title).trim();
    if raw.is_empty() {
        return None;
    }
    let parts: Vec<&str> = split_title(raw);
    // Terminal's own form: "folder — process — 160×40", or "folder — process".
    if parts.len() >= 2 {
        let process = parts[1].trim().to_lowercase();
        let has_size = parts.last().is_some_and(|last| is_size(last));
        if AI_PROCESSES.contains(&process.as_str()) {
            return None;
        }
        if has_size || SHELLS.contains(&process.as_str()) {
            let first = parts[0].trim();
            if let Some(folder) = folder_from_path(first, home) {
                return Some(folder);
            }
            if is_folder_name(first) {
                return Some(TerminalFolder {
                    path: None,
                    name: first.to_owned(),
                    sure: true,
                })
                .filter(|folder| !is_never_a_name_at(&folder.name, home));
            }
            return None;
        }
    }
    let whole = raw.to_lowercase();
    if AI_PROCESSES.contains(&whole.as_str()) || SHELLS.contains(&whole.as_str()) {
        return None;
    }
    // "dev@studio: ~/dev/trailhead-shop", "~/dev/trailhead-shop (-zsh)".
    let mut text = raw;
    if let Some((before, after)) = text.split_once(':') {
        if before.contains('@') && !before.contains(' ') {
            text = after.trim();
        }
    }
    if let Some(open) = text.rfind(" (") {
        let inner = text[open + 2..].trim_end_matches(')').trim().to_lowercase();
        if SHELLS.contains(&inner.as_str()) || AI_PROCESSES.contains(&inner.as_str()) {
            if AI_PROCESSES.contains(&inner.as_str()) {
                return None;
            }
            text = text[..open].trim();
        }
    }
    if let Some(folder) = folder_from_path(text, home) {
        return Some(folder);
    }
    // A bare word: perhaps a folder, perhaps a command. Never sure.
    (is_folder_name(text) && !is_never_a_name_at(text, home)).then(|| TerminalFolder {
        path: None,
        name: text.to_owned(),
        sure: false,
    })
}

/// The name of the conversation a chat or mail window shows, and nothing it
/// says: "#launch" or "Jordan Lee" in Slack, the person in Messages, an
/// email's subject. A Working On page lists conversations by name only
/// (SPEC-DELTA 4). `None` for a list, an inbox, a search or anything unsure.
#[must_use]
pub fn conversation_of(
    app: Option<&str>,
    title: Option<&str>,
    host: Option<&str>,
) -> Option<String> {
    let app = app?.trim();
    let raw = without_title_marks(title.unwrap_or_default()).trim();
    if raw.is_empty() || is_hippocampus(app) {
        return None;
    }
    let host = host.map(normalize_host).unwrap_or_default();
    let name = if app == "com.tinyspeck.slackmacgap"
        || is_site(&host, "app.slack.com")
        || app == "com.hnc.Discord"
    {
        slack_place(raw).filter(|place| !is_slack_view(place))
    } else if MAIL_APPS.contains(&app)
        || is_site(&host, "mail.google.com")
        || host.starts_with("outlook.")
    {
        let parts = title_segments(raw, &apps::name(app));
        let subject = without_reply_marks(parts.first()?).trim().to_owned();
        (!subject.is_empty() && !is_mailbox(&subject) && !subject.contains('@')).then_some(subject)
    } else if app == "com.microsoft.teams2" || app == "com.microsoft.teams" {
        // "Chat | Sam Lee | Microsoft Teams".
        let parts: Vec<&str> = raw.split(" | ").map(str::trim).collect();
        (parts.len() >= 3 && parts[0].eq_ignore_ascii_case("chat")).then(|| parts[1].to_owned())
    } else if CHAT_APPS_BY_TITLE.contains(&app) {
        title_segments(raw, &apps::name(app)).first().cloned()
    } else {
        None
    }?;
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    let named = match name.strip_prefix('#') {
        // A channel's name may be short: "#qa".
        Some(channel) => channel.chars().filter(|ch| ch.is_alphanumeric()).count() >= 2,
        None => !is_never_a_name(&name),
    };
    (named && !contains_secret(&name) && name.chars().count() <= MAX_NAME_CHARS).then_some(name)
}

/// Mail apps, whose title is a message's subject.
const MAIL_APPS: &[&str] = &[
    "com.apple.mail",
    "com.microsoft.Outlook",
    "com.superhuman.electron",
    "com.readdle.smartemail-Mac",
];

/// Chat apps whose window title is the conversation's name.
const CHAT_APPS_BY_TITLE: &[&str] = &[
    "com.apple.MobileSMS",
    "net.whatsapp.WhatsApp",
    "desktop.WhatsApp",
    "ru.keepcoder.Telegram",
    "org.telegram.desktop",
    "org.whispersystems.signal-desktop",
];

impl SqlCipherBrainStore {
    /// The file paths the given moments showed, as Tier 1 read them off the
    /// screen (`file_path` entities), each with how many of the moments
    /// showed it, most shown first, at most `limit`: what a code project's
    /// folder is guessed from (SPEC 3.12.4). Never anything else a moment
    /// said.
    ///
    /// # Errors
    /// Database failures.
    pub fn file_paths_seen(
        &self,
        event_ids: &[i64],
        limit: usize,
    ) -> Result<Vec<(String, u32)>, StoreError> {
        let mut wanted = event_ids.to_vec();
        wanted.sort_unstable();
        wanted.dedup();
        if wanted.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }
        let backend = |context: &str, error: rusqlite::Error| {
            StoreError::Backend(format!("{context}: {error}"))
        };
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let conn = guard.conn();
        let has_entities: bool = conn
            .query_row(
                "SELECT COUNT(*) = 2 FROM sqlite_master WHERE type = 'table'
                 AND name IN ('entities', 'entity_mentions')",
                [],
                |row| row.get(0),
            )
            .map_err(|e| backend("probe entity tables", e))?;
        if !has_entities {
            return Ok(Vec::new());
        }
        let mut counts: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
        for batch in wanted.chunks(500) {
            let sql = format!(
                "SELECT en.canonical_name, COUNT(DISTINCT m.event_id)
                 FROM entity_mentions m JOIN entities en ON en.id = m.entity_id
                 WHERE en.kind = 'file_path' AND m.event_id IN ({})
                 GROUP BY en.canonical_name",
                vec!["?"; batch.len()].join(", ")
            );
            let mut statement = conn
                .prepare(&sql)
                .map_err(|e| backend("prepare file paths seen", e))?;
            let rows = statement
                .query_map(rusqlite::params_from_iter(batch), |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(|e| backend("query file paths seen", e))?;
            for row in rows {
                let (path, count) = row.map_err(|e| backend("read file paths seen", e))?;
                *counts.entry(path).or_default() += u32::try_from(count).unwrap_or(u32::MAX);
            }
        }
        let mut paths: Vec<(String, u32)> = counts.into_iter().collect();
        paths.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        paths.truncate(limit);
        Ok(paths)
    }
}

// ---------------------------------------------------------------------------
// Rules by app
// ---------------------------------------------------------------------------

fn code(name: String, part: Option<String>) -> Subject {
    Subject {
        kind: SubjectKind::Code,
        name,
        part,
    }
}

/// VS Code, Cursor, Windsurf and `VSCodium`: "● tax.rs — trailhead-shop —
/// Visual Studio Code". The folder is the last part left; the file the
/// first, when it is one.
fn vs_code(raw: &str, app: &str) -> Option<Subject> {
    let app_name = apps::name(app).to_lowercase();
    let mut parts = title_segments(raw, &app_name);
    // "… — Visual Studio Code - Insiders": the edition, then the app's name.
    while parts.len() > 1
        && parts.last().is_some_and(|last| {
            let last = last.to_lowercase();
            matches!(last.as_str(), "insiders" | "vscodium")
                || last == app_name
                || TITLE_SUFFIXES.contains(&last.as_str())
        })
    {
        parts.pop();
    }
    let folder = match parts.len() {
        0 => return None,
        1 if looks_like_file(&parts[0]) => return None,
        1 => parts[0].clone(),
        _ => parts.last().cloned().unwrap_or_default(),
    };
    let file = (parts.len() >= 2)
        .then(|| parts[0].clone())
        .filter(|first| looks_like_file(first));
    Some(code(without_workspace_marks(&folder), file))
}

/// Zed: "trailhead-shop — tax.rs".
fn zed(raw: &str) -> Option<Subject> {
    let parts = title_segments(raw, "Zed");
    match parts.as_slice() {
        [] => None,
        [one] => (!looks_like_file(one)).then(|| code(one.clone(), None)),
        [first, second, ..] if looks_like_file(first) && !looks_like_file(second) => {
            Some(code(second.clone(), Some(first.clone())))
        }
        [first, second, ..] => Some(code(
            first.clone(),
            Some(file_name(second)).filter(|file| looks_like_file(file)),
        )),
    }
}

/// The `JetBrains` editors: "trailhead-shop – src/tax.rs [trailhead-shop]"; the
/// bracketed project name wins when present.
fn jetbrains(raw: &str, app: &str) -> Option<Subject> {
    let parts = title_segments(raw, &apps::name(app));
    let file = parts
        .get(1)
        .map(|second| file_name(second.split(" [").next().unwrap_or(second)))
        .filter(|file| looks_like_file(file));
    if let Some(open) = raw.rfind('[') {
        let inner = raw[open + 1..].trim_end_matches(']').trim();
        let project = inner.split('.').next().unwrap_or(inner).trim();
        if !project.is_empty() && !project.contains(':') {
            return Some(code(project.to_owned(), file));
        }
    }
    let first = parts.first()?.split(" [").next()?.trim().to_owned();
    if looks_like_file(&first) {
        // "tax.rs – trailhead-shop": the file first, then the project.
        let second = parts.get(1)?.split(" [").next()?.trim().to_owned();
        return (!looks_like_file(&second)).then(|| code(second, Some(file_name(&first))));
    }
    Some(code(first, file))
}

/// Xcode: "trailhead-shop.xcodeproj — tax.swift".
fn xcode(raw: &str) -> Option<Subject> {
    let parts = title_segments(raw, "Xcode");
    let first = parts.first()?;
    let name = [".xcodeproj", ".xcworkspace", ".swiftpm"]
        .iter()
        .find_map(|ext| strip_suffix_ignoring_case(first, ext))
        .unwrap_or(first)
        .trim()
        .to_owned();
    if looks_like_file(&name) {
        return None;
    }
    let file = parts
        .get(1)
        .filter(|second| looks_like_file(second))
        .cloned();
    Some(code(name, file))
}

/// Sublime Text: "~/dev/trailhead-shop/src/tax.rs (trailhead-shop) -
/// Sublime Text". Only the project in parentheses names one.
fn sublime(raw: &str) -> Option<Subject> {
    let parts = title_segments(raw, "Sublime Text");
    let first = parts.first()?;
    let open = first.rfind(" (")?;
    let project = first[open + 2..].trim_end_matches(')').trim();
    let path = first[..open].trim();
    (!project.is_empty()).then(|| {
        code(
            project.to_owned(),
            Some(file_name(path)).filter(|file| looks_like_file(file)),
        )
    })
}

/// Pages, Word, Keynote, Numbers, Excel and the like: the first part of the
/// title without its extension ("Q4 planning.pages" is Q4 planning).
fn named_first(raw: &str, app: &str, kind: SubjectKind) -> Option<Subject> {
    let parts = title_segments(raw, &apps::name(app));
    let first = parts.first()?;
    Some(Subject {
        kind,
        name: without_extension(first),
        part: None,
    })
}

/// Preview, PDF Expert, Acrobat: "contract.pdf — Page 3 of 12" is contract.
fn pdf(raw: &str, app: &str) -> Option<Subject> {
    let parts = title_segments(raw, &apps::name(app));
    let first = parts.first()?;
    let first = match first.rfind(" (") {
        Some(open) if first[open..].to_lowercase().contains("page") => &first[..open],
        _ => first.as_str(),
    };
    Some(Subject {
        kind: SubjectKind::Document,
        name: without_extension(first),
        part: None,
    })
}

/// Figma, Sketch, Photoshop: "Trailhead pricing v3 – Figma"; Photoshop's
/// "hero.psd @ 66.7% (RGB/8)" is hero.
fn design(raw: &str, app: &str) -> Option<Subject> {
    let parts = title_segments(raw, &apps::name(app));
    let first = parts.first()?;
    let first = first.split(" @ ").next().unwrap_or(first);
    Some(Subject {
        kind: SubjectKind::Design,
        name: without_extension(first),
        part: None,
    })
}

/// A browser's window: a document, design or spreadsheet on the web, a
/// search, or another page. Mail, chat, calls, AI chats and planning tools
/// in a tab name nothing here.
fn web(raw: &str, host: Option<&str>) -> Option<Subject> {
    if raw.is_empty() {
        return None;
    }
    if let Some(query) = search_in_title(raw) {
        return Some(Subject {
            kind: SubjectKind::Search,
            name: query,
            part: None,
        });
    }
    for (ending, kind) in WEB_ENDINGS {
        if let Some(name) = strip_suffix_ignoring_case(raw, ending) {
            let name = name.trim();
            if host.is_none_or(|host| hosts_kind(host, *kind)) {
                return Some(Subject {
                    kind: *kind,
                    name: without_extension(name),
                    part: None,
                });
            }
        }
    }
    let Some(host) = host else {
        // No address: the title alone. A web app's title ends with its name.
        let last = split_title(raw).last().map(|last| last.to_lowercase());
        if last.is_some_and(|last| WEB_APP_ENDINGS.contains(&last.as_str())) {
            return None;
        }
        return page_name(raw, "").map(|name| Subject {
            kind: SubjectKind::Page,
            name,
            part: None,
        });
    };
    if host == "localhost" || host.starts_with("127.") || host.starts_with("[::1]") {
        return None;
    }
    if is_site(host, "docs.google.com") || is_site(host, "sheets.google.com") {
        let parts = title_segments(raw, "Google Docs");
        let kind = if is_site(host, "sheets.google.com") {
            SubjectKind::Spreadsheet
        } else {
            SubjectKind::Document
        };
        return parts.first().map(|first| Subject {
            kind,
            name: without_extension(first),
            part: None,
        });
    }
    if DOCUMENT_HOSTS.iter().any(|site| is_site(host, site)) {
        return title_segments(raw, "Notion").first().map(|first| Subject {
            kind: SubjectKind::Document,
            name: first.clone(),
            part: None,
        });
    }
    if DESIGN_HOSTS.iter().any(|site| is_site(host, site)) {
        return title_segments(raw, "Figma").first().map(|first| Subject {
            kind: SubjectKind::Design,
            name: first.clone(),
            part: None,
        });
    }
    match apps::kind_for_host("com.google.Chrome", Some(host)) {
        WorkKind::Communication
        | WorkKind::Meetings
        | WorkKind::Ai
        | WorkKind::Planning
        | WorkKind::Writing => None,
        _ => page_name(raw, host).map(|name| Subject {
            kind: SubjectKind::Page,
            name,
            part: None,
        }),
    }
}

/// A page's name: its title without the browser's and a site's name at the
/// end. When what is left is a short word or two ("Pricing", "Plans and
/// pricing"), the site's name stays beside it ("Pricing · Velo Cycles"),
/// since the word alone says nothing.
fn page_name(raw: &str, host: &str) -> Option<String> {
    let mut parts = title_segments(raw, "");
    // "Dev Notes · Rounding half to even": the site's name first.
    if parts.len() >= 2 && names_the_host(&parts[0], host) {
        parts.remove(0);
    }
    let first = parts.first()?.trim();
    if first.is_empty() {
        return None;
    }
    let second = parts.get(1).map(|second| second.trim());
    let short = first.split_whitespace().count() <= 3 && first.chars().count() <= 24;
    match second {
        Some(site) if short && !site.is_empty() && !names_the_host(first, host) => {
            Some(format!("{first} \u{00b7} {site}"))
        }
        _ => Some(first.to_owned()),
    }
}

/// A search result page's query, from its title.
fn search_in_title(raw: &str) -> Option<String> {
    SEARCH_TITLE_ENDS.iter().find_map(|end| {
        let query = raw.strip_suffix(end)?.trim();
        // Every video's title ends " - YouTube": only an address says that
        // one was a search.
        (*end != " - YouTube" && !query.is_empty()).then(|| query.to_owned())
    })
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

/// A subject whose name passes every rule, cleaned: spaces collapsed, cut
/// to [`MAX_NAME_CHARS`] by whole characters.
fn accepted(mut subject: Subject, home: Option<&str>) -> Option<Subject> {
    let name = subject
        .name
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let name = name
        .trim_matches(|ch: char| ch.is_whitespace() || ch == '\u{2014}' || ch == '\u{2013}')
        .to_owned();
    if is_never_a_name_at(&name, home) {
        return None;
    }
    subject.name = name.chars().take(MAX_NAME_CHARS).collect();
    subject.part = subject
        .part
        .map(|part| part.trim().to_owned())
        .filter(|part| !part.is_empty() && !contains_secret(part) && !is_untitled(&folded(part)));
    Some(subject)
}

fn is_hippocampus(app: &str) -> bool {
    let lower = app.to_ascii_lowercase();
    lower == "ai.hippocampus"
        || lower.starts_with("ai.hippocampus.")
        || lower == "recall-ui"
        || lower == "onboarding"
}

/// "Untitled", "Untitled-1", "Untitled 2", "untitled folder 3".
fn is_untitled(folded: &str) -> bool {
    let Some(rest) = folded.strip_prefix("untitled") else {
        return false;
    };
    let rest = rest.trim_start_matches([' ', '-', '_']);
    let rest = rest
        .strip_prefix("document")
        .or_else(|| rest.strip_prefix("spreadsheet"))
        .or_else(|| rest.strip_prefix("presentation"))
        .or_else(|| rest.strip_prefix("folder"))
        .unwrap_or(rest)
        .trim_start_matches([' ', '-', '_']);
    let rest = without_extension(rest);
    rest.is_empty() || rest.chars().all(|ch| ch.is_ascii_digit())
}

/// The names Word, Excel and `PowerPoint` give a document not yet saved:
/// "Document1", "Book1", "Presentation1".
fn is_default_document(folded: &str) -> bool {
    ["document", "book", "presentation", "workbook", "sheet"]
        .iter()
        .any(|word| {
            folded
                .strip_prefix(word)
                .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|ch| ch.is_ascii_digit()))
        })
}

/// The last part of the home folder's path ("dev" for /Users/dev), read
/// once: a terminal open there names no project.
fn home_folder_name() -> Option<&'static str> {
    static HOME: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    HOME.get_or_init(|| {
        let home = std::env::var_os("HOME")?;
        let home = std::path::Path::new(&home)
            .file_name()?
            .to_str()?
            .to_lowercase();
        (!home.is_empty()).then_some(home)
    })
    .as_deref()
}

fn is_invisible(ch: char) -> bool {
    matches!(
        ch,
        '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{2064}' | '\u{feff}'
    )
}

/// The title's parts at " — ", " – ", " - ", " | " and " · ", kept as
/// written.
fn split_title(raw: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut rest = raw;
    loop {
        let next = [" - ", " \u{2014} ", " \u{2013} ", " | ", " \u{00b7} "]
            .iter()
            .filter_map(|sep| rest.find(sep).map(|at| (at, sep.len())))
            .min();
        let Some((at, len)) = next else {
            parts.push(rest.trim());
            break;
        };
        parts.push(rest[..at].trim());
        rest = &rest[at + len..];
    }
    parts.retain(|part| !part.is_empty());
    parts
}

/// "160×40", "80x24".
fn is_size(part: &str) -> bool {
    let part = part.trim();
    let Some((cols, rows)) = part.split_once(['\u{00d7}', 'x']) else {
        return false;
    };
    !cols.is_empty()
        && !rows.is_empty()
        && cols.chars().all(|ch| ch.is_ascii_digit())
        && rows.chars().all(|ch| ch.is_ascii_digit())
}

/// A folder from a path a title holds: "~/dev/trailhead-shop/apps/web" is
/// web, at that path. The home folder and the root name nothing.
fn folder_from_path(text: &str, home: Option<&str>) -> Option<TerminalFolder> {
    let text = text.trim();
    if !(text.starts_with('~') || text.starts_with('/')) || text.contains("  ") {
        return None;
    }
    let path = text.trim_end_matches('/');
    let name = path.rsplit('/').next()?.trim();
    if name.is_empty() || name == "~" || !is_folder_name(name) || is_never_a_name_at(name, home) {
        return None;
    }
    Some(TerminalFolder {
        path: Some(path.to_owned()),
        name: name.to_owned(),
        sure: true,
    })
}

/// A folder's name has no spaces and is not a command line.
fn is_folder_name(name: &str) -> bool {
    !name.is_empty()
        && !name.chars().any(char::is_whitespace)
        && !name.starts_with('-')
        && !name.contains(['/', '\\', '$', '%', '>', '<', '|', '&', ';', '(', ')'])
}

/// Whether a part of a title is a file's name: it ends with a short
/// extension ("tax.rs", "Cargo.toml", ".env").
fn looks_like_file(part: &str) -> bool {
    let part = file_name(part);
    if part.chars().any(char::is_whitespace) {
        return false;
    }
    let Some((stem, extension)) = part.rsplit_once('.') else {
        return false;
    };
    (!stem.is_empty() || part.starts_with('.'))
        && (1..=10).contains(&extension.chars().count())
        && extension.chars().all(|ch| ch.is_ascii_alphanumeric())
        && extension.chars().any(|ch| ch.is_ascii_alphabetic())
}

/// The last part of a path ("src/tax.rs" is tax.rs).
fn file_name(part: &str) -> String {
    part.trim()
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// A name without the document extension its title shows.
fn without_extension(name: &str) -> String {
    let name = name.trim();
    EXTENSIONS
        .iter()
        .find_map(|ext| strip_suffix_ignoring_case(name, ext))
        .unwrap_or(name)
        .trim()
        .to_owned()
}

/// VS Code's remote and workspace marks: "trailhead-shop [SSH: devbox]",
/// "trailhead-shop (Workspace)".
fn without_workspace_marks(folder: &str) -> String {
    let mut name = folder.trim();
    if let Some(open) = name.rfind(" [") {
        if name.ends_with(']') {
            name = name[..open].trim();
        }
    }
    for mark in [" (Workspace)", " (workspace)"] {
        if let Some(stripped) = name.strip_suffix(mark) {
            name = stripped.trim();
        }
    }
    name.to_owned()
}

fn strip_suffix_ignoring_case<'a>(text: &'a str, suffix: &str) -> Option<&'a str> {
    let at = text.len().checked_sub(suffix.len())?;
    (text.is_char_boundary(at) && text[at..].eq_ignore_ascii_case(suffix)).then(|| &text[..at])
}

fn normalize_host(host: &str) -> String {
    let host = host.trim().to_ascii_lowercase();
    host.strip_prefix("www.").unwrap_or(&host).to_owned()
}

fn is_site(host: &str, site: &str) -> bool {
    host == site || host.ends_with(&format!(".{site}"))
}

/// Whether a host is the right site for a title's ending.
fn hosts_kind(host: &str, kind: SubjectKind) -> bool {
    match kind {
        SubjectKind::Spreadsheet => {
            is_site(host, "docs.google.com") || is_site(host, "sheets.google.com")
        }
        SubjectKind::Design => DESIGN_HOSTS.iter().any(|site| is_site(host, site)),
        _ => {
            is_site(host, "docs.google.com")
                || DOCUMENT_HOSTS.iter().any(|site| is_site(host, site))
        }
    }
}

/// Whether a title's first part is only the site's own name ("Dev Notes"
/// on devnotes.example).
fn names_the_host(part: &str, host: &str) -> bool {
    let letters = |text: &str| {
        text.to_lowercase()
            .replace('&', "and")
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .collect::<String>()
    };
    let label = host.split('.').next().unwrap_or(host);
    !label.is_empty() && letters(part) == letters(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_ignore_case_spacing_and_invisible_marks() {
        assert_eq!(
            identity(SubjectKind::Document, "Q4  Planning"),
            identity(SubjectKind::Document, "q4 planning\u{200b}")
        );
        assert_ne!(
            identity(SubjectKind::Document, "Q4 planning"),
            identity(SubjectKind::Design, "Q4 planning")
        );
    }

    #[test]
    fn untitled_and_default_names_are_never_names() {
        for name in [
            "Untitled",
            "Untitled-1",
            "Untitled 2",
            "untitled folder 3",
            "Untitled spreadsheet",
            "Document1",
            "Book12",
            "Presentation1",
        ] {
            assert!(is_never_a_name(name), "{name}");
        }
        for name in ["Untitled draft of the plan", "Bookings", "Documentation"] {
            assert!(!is_never_a_name(name), "{name}");
        }
    }

    #[test]
    fn sizes_and_files_read_as_written() {
        assert!(is_size("160\u{00d7}40"));
        assert!(is_size("80x24"));
        assert!(!is_size("x24"));
        assert!(looks_like_file("tax.rs"));
        assert!(looks_like_file(".env"));
        assert!(looks_like_file("src/tax.rs"));
        assert!(!looks_like_file("trailhead-shop"));
        assert!(!looks_like_file("v0.4"));
        assert!(!looks_like_file("Q4 planning.pages draft"));
    }
}
