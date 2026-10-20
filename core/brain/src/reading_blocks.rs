//! A reading's text as typed blocks (SPEC 4.2): what was read, in order, as
//! headings, paragraphs, lists, code, terminal output, tables, chat turns,
//! quotes and mail's header lines.
//!
//! Nothing is invented: every block holds only text of `main`, as read, and
//! a block's kind changes only how it is drawn. Blocks only split `main`:
//! they never put two pieces side by side that the reading kept apart (the
//! reader, [`crate::reading`], is what joins wrapped lines). Blocks are made
//! when a reading is shown, from the stored or the live `main`, so a change
//! to these rules needs no re-clean. The window gets them with the FFI's
//! reading of a moment, an AI tool gets [`markdown`] of them, and Copy Text
//! copies [`plain_text`].
//!
//! # Rules by kind of window (SPEC 4.4)
//!
//! `main` is read in runs of lines between blank lines.
//!
//! - **Pages, documents, notes, PDFs, AI chats.** A run with tab-separated
//!   cells is a `table`; a run that reads like code as a whole is `code`; a
//!   run of rows that carry numbers is table-like `lines`. Otherwise, line by
//!   line: two or more lines in a row that read like code are `code`; a line
//!   that starts with a list marker starts a `list` item, and the indented
//!   lines under it belong to it; the line that names the window (the first
//!   part of its title) is the level-1 heading, once; a line within three
//!   lines after it that holds a date or "min read" is a `byline`; a short
//!   line in capitals right before a heading is a `label`; a heading-shaped
//!   line is a level-2 heading when it stands alone in its run, comes right
//!   after a label, or comes right before a line of 60 characters or more or
//!   a list. The other lines are paragraphs, one each, except a group of
//!   short lines (an address, a menu, a sign-off), which stays one `lines`.
//!   No speaker is ever inferred in an AI chat.
//! - **Mail.** The subject is the level-1 heading when it names the window;
//!   the header lines after it (the sender, "To:", "to me", the date) are
//!   `meta`. "On … wrote:" and everything after it, and lines that start
//!   with ">", are a `quote`; a signature after "--", and "Sent from my …",
//!   are `meta`. The body follows the document rules.
//! - **Chats with people.** A line that is a name and a time ("Jordan Lee
//!   2:14 PM") starts a `turn`, whose body is the lines up to the next such
//!   line. With no such line (as in Messages), every line is its own
//!   paragraph: nothing is attributed to anyone, and alignment, colour or
//!   "you" are never guessed.
//! - **Terminals.** One `terminal` block, byte for byte, its prompt lines
//!   marked.
//! - **Code editors.** Code is one `code` block, lines as read, blank lines
//!   and all; the rest of the window (an assistant's panel) follows the
//!   document rules.
//! - **Spreadsheets.** Rows with tab-separated cells are a `table`; others
//!   are table-like `lines`.
//!
//! Code, terminal output, tables and `lines` keep their text byte for byte.
//! A reading has at most [`MAX_ELEMENTS`] blocks, items, rows, cells, lines
//! and marked prompts together; past that, the rest of `main` is one
//! paragraph, as read. So the blocks' JSON is never more than the text's
//! own escaped length and [`MAX_STRUCTURE_BYTES`].

use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::apps;
use crate::chrome;
use crate::reading::{is_preformatted, starts_with_prompt, TERMINAL_APPS};
use crate::EventSource;

/// The most blocks, list items, table rows and cells, `lines` entries and
/// marked prompts one reading is split into. Past it the rest of `main` is
/// one paragraph, and a terminal marks no more prompts.
pub const MAX_ELEMENTS: usize = 2_000;

/// The most bytes of JSON the blocks of one reading add around the text they
/// hold: no element costs more than 64 bytes of structure.
pub const MAX_STRUCTURE_BYTES: usize = MAX_ELEMENTS * 64 + 1024;

/// The window a reading came from, as the rules by kind of window read it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Window<'a> {
    /// The app's bundle id.
    pub app: Option<&'a str>,
    /// The window's title.
    pub title: Option<&'a str>,
    /// The page's address, when known.
    pub url: Option<&'a str>,
}

/// One block of a reading, in the order it was read. Serialized with its
/// kind as `"kind"`: `{"kind": "paragraph", "text": "…"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Block {
    /// A short line in capitals before a heading ("MONEY & ROUNDING").
    Label {
        /// The line, as read.
        text: String,
    },
    /// A short title line: level 1 names the window (at most once), level 2
    /// is a section's.
    Heading {
        /// 1 or 2.
        level: u8,
        /// The line, as read.
        text: String,
    },
    /// A short line with a date or "min read" near the top ("Priya Raman ·
    /// Oct 12, 2026 · 6 min read").
    Byline {
        /// The line, as read.
        text: String,
    },
    /// Prose: one line of `main`, whose wrapped lines the reader joined.
    Paragraph {
        /// The text, as read.
        text: String,
    },
    /// Items with the markers that were read.
    List {
        /// The items, in order.
        items: Vec<Item>,
    },
    /// Lines that read like code, byte for byte.
    Code {
        /// The lines, as read, with their indents.
        text: String,
    },
    /// A terminal's lines, byte for byte.
    Terminal {
        /// The lines, as read.
        text: String,
        /// Which lines (counted from 0) start with a shell prompt.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        prompts: Vec<u32>,
    },
    /// Rows whose cells are known: they were read with a tab between them.
    Table {
        /// The rows, each its cells as read.
        rows: Vec<Vec<String>>,
        /// For each column, whether its cells below the first row are
        /// numbers (drawn right-aligned).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        numeric: Vec<bool>,
    },
    /// Short lines that stay apart: an address, a menu, a sign-off, a table
    /// whose cells are not known.
    Lines {
        /// The lines, as read.
        lines: Vec<String>,
        /// The lines are a table's rows, drawn with hairlines between them.
        #[serde(default, skip_serializing_if = "is_false")]
        table: bool,
    },
    /// A chat message: the speaker and the time as read, then what was said.
    Turn {
        /// The name, as read.
        speaker: String,
        /// The time, as read ("2:14 PM", "Today at 2:15 PM").
        time: String,
        /// The message's lines, as read; empty when none were read.
        text: String,
    },
    /// Quoted mail: "On … wrote:" and what follows it, or lines that start
    /// with ">".
    Quote {
        /// The lines, as read.
        text: String,
    },
    /// Mail's header lines and signature, and a chat's day divider.
    Meta {
        /// The line or lines, as read.
        text: String,
    },
}

/// One list item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    /// The marker as read: "•", "-", "1.", "a)", "☐", "[x]" …
    pub marker: String,
    /// What follows the marker, with any lines under it, as read.
    pub text: String,
    /// 0, or 1 for an item indented under another.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub depth: u8,
    /// For a checkbox: whether it was ticked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
}

// serde's skip_serializing_if takes a reference.
#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_false(value: &bool) -> bool {
    !*value
}

#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_zero(value: &u8) -> bool {
    *value == 0
}

impl Block {
    /// The block as plain text, its lines as read: what Copy Text copies of
    /// it. A list item reads as its marker, a space and its text; a table
    /// row as its cells with a tab between them; a turn as the speaker and
    /// the time, then the message.
    #[must_use]
    pub fn plain(&self) -> String {
        match self {
            Self::Label { text }
            | Self::Heading { text, .. }
            | Self::Byline { text }
            | Self::Paragraph { text }
            | Self::Code { text }
            | Self::Terminal { text, .. }
            | Self::Quote { text }
            | Self::Meta { text } => text.clone(),
            Self::List { items } => items
                .iter()
                .map(|item| {
                    format!(
                        "{}{} {}",
                        "  ".repeat(usize::from(item.depth)),
                        item.marker,
                        item.text
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
            Self::Table { rows, .. } => rows
                .iter()
                .map(|row| row.join("\t"))
                .collect::<Vec<_>>()
                .join("\n"),
            Self::Lines { lines, .. } => lines.join("\n"),
            Self::Turn {
                speaker,
                time,
                text,
            } => {
                if text.is_empty() {
                    format!("{speaker} {time}")
                } else {
                    format!("{speaker} {time}\n{text}")
                }
            }
        }
    }

    /// The block as Markdown, for an AI tool (SPEC 4.7): headings with `#`
    /// and `##`, list items as read, code and terminal output fenced, a
    /// turn's speaker in bold, quotes with `>`, a table with pipes. A label
    /// is left out: the heading after it says what the page is.
    #[must_use]
    pub fn markdown(&self) -> Option<String> {
        Some(match self {
            Self::Label { .. } => return None,
            Self::Heading { level, text } => {
                format!("{} {text}", if *level == 1 { "#" } else { "##" })
            }
            Self::Byline { text } | Self::Paragraph { text } | Self::Meta { text } => escaped(text),
            Self::Lines { lines, .. } => escaped(&lines.join("\n")),
            Self::List { .. } => self.plain(),
            Self::Code { text } | Self::Terminal { text, .. } => {
                let fence = "`".repeat(longest_backtick_run(text).max(2) + 1);
                format!("{fence}\n{text}\n{fence}")
            }
            Self::Table { rows, numeric } => table_markdown(rows, numeric),
            Self::Turn {
                speaker,
                time,
                text,
            } => {
                if text.is_empty() {
                    format!("**{speaker}** {time}")
                } else {
                    format!("**{speaker}** {time}\n{text}")
                }
            }
            Self::Quote { text } => text
                .split('\n')
                .map(|line| {
                    if line.trim_start().starts_with('>') {
                        line.to_owned()
                    } else if line.trim().is_empty() {
                        ">".to_owned()
                    } else {
                        format!("> {line}")
                    }
                })
                .collect::<Vec<_>>()
                .join("\n"),
        })
    }

    /// How many elements the block counts toward [`MAX_ELEMENTS`].
    fn elements(&self) -> usize {
        1 + match self {
            Self::List { items } => items.len(),
            Self::Terminal { prompts, .. } => prompts.len(),
            Self::Table { rows, numeric } => {
                rows.len() + rows.iter().map(Vec::len).sum::<usize>() + numeric.len()
            }
            Self::Lines { lines, .. } => lines.len(),
            _ => 0,
        }
    }
}

/// `text` with a backslash before a "#" or ">" that starts one of its
/// lines, so a line that was read so ("# launch-plan") is not taken for a
/// heading or a quote.
fn escaped(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let body = line.trim_start();
            if body.starts_with(['#', '>']) {
                format!("{}\\{body}", &line[..line.len() - body.len()])
            } else {
                line.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The longest run of backticks in `text`.
fn longest_backtick_run(text: &str) -> usize {
    let mut longest = 0;
    let mut run = 0;
    for ch in text.chars() {
        if ch == '`' {
            run += 1;
            longest = longest.max(run);
        } else {
            run = 0;
        }
    }
    longest
}

fn table_markdown(rows: &[Vec<String>], numeric: &[bool]) -> String {
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let row = |cells: &[String]| {
        let mut out = String::from("|");
        for column in 0..columns {
            let cell = cells.get(column).map_or("", String::as_str);
            out.push(' ');
            out.push_str(&cell.replace('|', "\\|"));
            out.push_str(" |");
        }
        out
    };
    let mut lines = Vec::with_capacity(rows.len() + 1);
    if let Some(first) = rows.first() {
        lines.push(row(first));
        let rule: String = (0..columns)
            .map(|column| {
                if numeric.get(column).copied().unwrap_or(false) {
                    " ---: |"
                } else {
                    " --- |"
                }
            })
            .collect();
        lines.push(format!("|{rule}"));
    }
    lines.extend(rows.iter().skip(1).map(|cells| row(cells)));
    lines.join("\n")
}

/// Whether `block` stays on the line after `previous`, with no blank line
/// between them: a label over its heading, and a level-1 heading with the
/// line under it and its byline or header lines. Everything else is set
/// apart by a blank line. `group` says the previous block was in such a run.
fn stays_close(previous: &Block, block: &Block, group: bool) -> bool {
    match (previous, block) {
        (Block::Label { .. }, Block::Heading { .. })
        | (
            Block::Heading { level: 1, .. },
            Block::Paragraph { .. } | Block::Byline { .. } | Block::Meta { .. },
        )
        | (Block::Byline { .. } | Block::Meta { .. }, Block::Byline { .. } | Block::Meta { .. }) => {
            true
        }
        (Block::Paragraph { .. }, Block::Byline { .. } | Block::Meta { .. }) => group,
        _ => false,
    }
}

/// `pieces` (each block's text, or none to leave it out) joined: a blank
/// line between blocks, a line break inside a heading's run ([`stays_close`]).
fn joined(blocks: &[Block], piece: impl Fn(&Block) -> Option<String>) -> String {
    let mut out = String::new();
    let mut previous: Option<&Block> = None;
    let mut group = false;
    for block in blocks {
        let Some(text) = piece(block) else {
            continue;
        };
        let close = previous.is_some_and(|previous| stays_close(previous, block, group));
        group = matches!(block, Block::Heading { level: 1, .. })
            || (close && group)
            || (close && matches!(previous, Some(Block::Heading { level: 1, .. })));
        if !out.is_empty() {
            out.push_str(if close { "\n" } else { "\n\n" });
        }
        out.push_str(&text);
        previous = Some(block);
    }
    out
}

/// The blocks as plain text, with the structure kept: what Copy Text copies
/// (SPEC 4.7). Blocks are set apart by a blank line, list markers and code
/// lines are as read, and no Markdown symbol is added.
#[must_use]
pub fn plain_text(blocks: &[Block]) -> String {
    joined(blocks, |block| Some(block.plain()))
}

/// The blocks as Markdown, for an AI tool (SPEC 4.7): see [`Block::markdown`].
/// The caller puts the whole inside an outer fence one backtick longer than
/// any run of backticks in it, so the moment stays marked as data.
#[must_use]
pub fn markdown(blocks: &[Block]) -> String {
    joined(blocks, Block::markdown)
}

// ---------------------------------------------------------------------------
// Kinds of window
// ---------------------------------------------------------------------------

/// The kind of window a reading came from, as the rules read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    /// Pages, documents, notes, PDFs and every other window.
    Document,
    /// A mail app, or a mail site in a browser.
    Mail,
    /// A chat with people: Slack, Messages, Telegram, Signal, Teams,
    /// Discord, Messenger and the rest, in their apps or a browser.
    People,
    /// An AI chat: `OpenAI`'s and Anthropic's chat apps, and their sites.
    AiChat,
    /// A terminal.
    Terminal,
    /// A code editor.
    Editor,
    /// A spreadsheet: Numbers, Excel, Google Sheets.
    Sheet,
}

/// Chat apps whose windows are what people said.
const PEOPLE_APPS: [&str; 11] = [
    "com.tinyspeck.slackmacgap",
    "com.apple.MobileSMS",
    "com.hnc.Discord",
    "net.whatsapp.WhatsApp",
    "desktop.WhatsApp",
    "ru.keepcoder.Telegram",
    "org.telegram.desktop",
    "org.whispersystems.signal-desktop",
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "com.facebook.archon",
];

/// The same chats in a browser.
const PEOPLE_HOSTS: [&str; 8] = [
    "app.slack.com",
    "discord.com",
    "web.whatsapp.com",
    "web.telegram.org",
    "teams.microsoft.com",
    "messenger.com",
    "messages.google.com",
    "chat.google.com",
];

/// AI chat apps: what they show is prose.
const AI_CHAT_APPS: [&str; 2] = ["com.openai.chat", "com.anthropic.claudefordesktop"];

/// AI chats in a browser.
const AI_CHAT_HOSTS: [&str; 5] = [
    "chatgpt.com",
    "chat.openai.com",
    "claude.ai",
    "gemini.google.com",
    "perplexity.ai",
];

const MAIL_APPS: [&str; 6] = [
    "com.apple.mail",
    "com.microsoft.Outlook",
    "com.readdle.smartemail-Mac",
    "com.superhuman.electron",
    "com.mimestream.Mimestream",
    "it.bloop.airmail2",
];

const MAIL_HOSTS: [&str; 7] = [
    "mail.google.com",
    "outlook.live.com",
    "outlook.office.com",
    "outlook.office365.com",
    "mail.yahoo.com",
    "app.fastmail.com",
    "mail.proton.me",
];

const SHEET_APPS: [&str; 2] = ["com.apple.iWork.Numbers", "com.microsoft.Excel"];

/// The kind of window `app`, with its title and page address, is.
pub(crate) fn kind_of(app: Option<&str>, title: Option<&str>, url: Option<&str>) -> Kind {
    if let Some(app) = app {
        if TERMINAL_APPS.contains(&app) {
            return Kind::Terminal;
        }
        if chrome::is_editor(Some(app)) || app == "com.apple.dt.Xcode" {
            return Kind::Editor;
        }
        if PEOPLE_APPS.contains(&app) {
            return Kind::People;
        }
        if AI_CHAT_APPS.contains(&app) {
            return Kind::AiChat;
        }
        if MAIL_APPS.contains(&app) {
            return Kind::Mail;
        }
        if SHEET_APPS.contains(&app) {
            return Kind::Sheet;
        }
    }
    if let Some(url) = url {
        if let Some(host) = apps::host_of(url) {
            let is = |site: &str| host == site || host.ends_with(&format!(".{site}"));
            if PEOPLE_HOSTS.iter().any(|site| is(site)) {
                return Kind::People;
            }
            if AI_CHAT_HOSTS.iter().any(|site| is(site)) {
                return Kind::AiChat;
            }
            if MAIL_HOSTS.iter().any(|site| is(site)) {
                return Kind::Mail;
            }
            if is("sheets.google.com") || (is("docs.google.com") && url.contains("/spreadsheets/"))
            {
                return Kind::Sheet;
            }
        }
    }
    if chrome::is_browser(app) && title.is_some_and(|title| title.trim_end().ends_with(" - Gmail"))
    {
        return Kind::Mail;
    }
    Kind::Document
}

fn kind_of_window(window: &Window<'_>, source: EventSource) -> Kind {
    match kind_of(window.app, window.title, window.url) {
        // A conversation imported from a transcript reads as an AI chat.
        Kind::Document if source == EventSource::TranscriptImport => Kind::AiChat,
        kind => kind,
    }
}

// ---------------------------------------------------------------------------
// Lines
// ---------------------------------------------------------------------------

/// The words that join a wrapped line to the next when it ends on one (the
/// reader's rule J2).
pub(crate) const JOINING_WORDS: [&str; 26] = [
    "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "from",
    "by", "as", "that", "which", "who", "than", "into", "about", "via", "&", "nor", "onto",
];

/// Whether `line` ends on a joining word ([`JOINING_WORDS`]).
pub(crate) fn ends_on_joining_word(line: &str) -> bool {
    line.split_whitespace().next_back().is_some_and(|word| {
        JOINING_WORDS
            .iter()
            .any(|joining| word.eq_ignore_ascii_case(joining))
    })
}

/// The lines an AI chat or an assistant's panel puts over each message:
/// never a heading, and never taken for a speaker.
const ASSISTANT_LABELS: [&str; 11] = [
    "You",
    "Me",
    "User",
    "Assistant",
    "ChatGPT",
    "Claude",
    "Copilot",
    "Gemini",
    "Perplexity",
    "Cursor",
    "Codex",
];

/// A list item: its indent in characters, its marker and what follows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Marked<'l> {
    /// Leading whitespace, in characters.
    pub indent: usize,
    /// The marker, as read.
    pub marker: &'l str,
    /// What follows the marker and the space after it.
    pub text: &'l str,
    /// For a checkbox, whether it is ticked.
    pub checked: Option<bool>,
}

/// Markers that need no space after them, with what they say of a checkbox.
const GLYPH_MARKERS: [(&str, Option<bool>); 10] = [
    ("\u{2022}", None),        // •
    ("\u{2023}", None),        // ‣
    ("\u{2043}", None),        // ⁃
    ("\u{00B7}", None),        // ·
    ("\u{2610}", Some(false)), // ☐
    ("\u{2611}", Some(true)),  // ☑
    ("\u{2612}", Some(true)),  // ☒
    ("\u{2713}", Some(true)),  // ✓
    ("\u{2714}", Some(true)),  // ✔
    ("\u{2013}", None),        // –
];

/// The list item `line` starts, if it starts with a list marker followed by
/// text: •, ‣, ·, -, *, –, "1.", "1)", "a)", "(a)", ☐, ☑, "[ ]", "[x]", and
/// Markdown's "- [ ]" and "- [x]".
pub(crate) fn list_item(line: &str) -> Option<Marked<'_>> {
    let rest = line.trim_start();
    let indent = line[..line.len() - rest.len()].chars().count();
    let (marker_len, checked, needs_space) = marker_at(rest)?;
    let after = &rest[marker_len..];
    if needs_space && !after.starts_with([' ', '\u{00A0}']) {
        return None;
    }
    let text = after.trim_start();
    if !text.chars().any(char::is_alphanumeric) {
        return None;
    }
    Some(Marked {
        indent,
        marker: &rest[..marker_len],
        text,
        checked,
    })
}

/// The byte length of the marker `text` starts with, what it says of a
/// checkbox, and whether a space must follow it.
fn marker_at(text: &str) -> Option<(usize, Option<bool>, bool)> {
    for task in ["- [ ]", "* [ ]", "- [x]", "* [x]", "- [X]", "* [X]"] {
        if text.starts_with(task) {
            return Some((task.len(), Some(!task.ends_with("[ ]")), true));
        }
    }
    for (box_marker, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
        if text.starts_with(box_marker) {
            return Some((box_marker.len(), Some(checked), true));
        }
    }
    for (glyph, checked) in GLYPH_MARKERS {
        if text.starts_with(glyph) {
            // The en dash and the middle dot are words' punctuation too: a
            // space must follow them.
            let spaced = matches!(glyph, "\u{2013}" | "\u{00B7}");
            return Some((glyph.len(), checked, spaced));
        }
    }
    let bytes = text.as_bytes();
    match bytes.first()? {
        b'-' | b'*' => Some((1, None, true)),
        b'0'..=b'9' => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            (digits <= 3 && matches!(bytes.get(digits), Some(b'.' | b')'))).then_some((
                digits + 1,
                None,
                true,
            ))
        }
        b'a'..=b'z' if bytes.get(1) == Some(&b')') => Some((2, None, true)),
        b'(' => {
            let inner = bytes[1..]
                .iter()
                .take_while(|b| b.is_ascii_alphanumeric())
                .count();
            ((1..=3).contains(&inner) && bytes.get(1 + inner) == Some(&b')')).then_some((
                inner + 2,
                None,
                true,
            ))
        }
        _ => None,
    }
}

/// A chat's speaker line: a name of one to four words in any script, then a
/// time as read ("Jordan Lee 2:14 PM", "Priya Raman Today at 2:15 PM").
/// Gives the name and the time.
pub(crate) fn speaker_line(line: &str) -> Option<(&str, &str)> {
    static SPEAKER: OnceLock<Regex> = OnceLock::new();
    let line = line.trim();
    if line.len() > 80 || !line.contains(':') {
        return None;
    }
    let found = SPEAKER
        .get_or_init(|| {
            Regex::new(concat!(
                r"^(\p{L}[\p{L}\p{M}'\x{2019}.\-]*(?:[ \x{A0}]+\p{L}[\p{L}\p{M}'\x{2019}.\-]*){0,3}?)",
                r"[ \x{A0}]+",
                r"((?:(?:Today|Yesterday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?[ \x{A0}]+at[ \x{A0}]+)?",
                r"\d{1,2}:\d{2}(?:[ \x{A0}\x{202F}]?[AaPp]\.?[Mm]\.?)?)$"
            ))
            .expect("the speaker pattern compiles")
        })
        .captures(line)?;
    let name = found.get(1)?.as_str();
    let first = name.split_whitespace().next()?;
    if ["Today", "Yesterday", "at"].contains(&first) || is_month(first) || is_weekday(first) {
        return None;
    }
    Some((name, found.get(2)?.as_str()))
}

const MONTHS: [&str; 12] = [
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
];

const WEEKDAYS: [&str; 7] = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
];

/// A word with any punctuation around it removed.
fn bare(word: &str) -> &str {
    word.trim_matches(|ch: char| !ch.is_alphanumeric())
}

/// Whether `word`, in any case, is one of `names` or, three or four letters
/// long, the start of one ("Oct", "Sept", "Mon").
fn names_one_of(word: &str, names: &[&str]) -> bool {
    let word = bare(word);
    word.len() >= 3
        && word.is_ascii()
        && names.iter().any(|name| {
            name.eq_ignore_ascii_case(word)
                || (word.len() <= 4
                    && name.len() > word.len()
                    && name[..word.len()].eq_ignore_ascii_case(word))
        })
}

/// A month's name or its short form ("Oct", "Sept").
fn is_month(word: &str) -> bool {
    names_one_of(word, &MONTHS)
}

fn is_weekday(word: &str) -> bool {
    names_one_of(word, &WEEKDAYS)
}

/// A day of the month as read: "12", "3rd", "12th".
fn is_day_number(word: &str) -> bool {
    let word = bare(word);
    let digits = word.bytes().take_while(u8::is_ascii_digit).count();
    (1..=2).contains(&digits)
        && ["", "st", "nd", "rd", "th"]
            .iter()
            .any(|ending| word[digits..].eq_ignore_ascii_case(ending))
        && word[..digits]
            .parse::<u8>()
            .is_ok_and(|day| (1..=31).contains(&day))
}

/// A clock time as read: "2:31", "14:05".
fn is_clock(word: &str) -> bool {
    let word = word.trim_matches(|ch: char| !ch.is_ascii_digit());
    word.split_once(':').is_some_and(|(hours, minutes)| {
        (1..=2).contains(&hours.len())
            && minutes.len() == 2
            && hours.bytes().all(|b| b.is_ascii_digit())
            && minutes.bytes().all(|b| b.is_ascii_digit())
    })
}

/// A date written with digits: "2026-10-12", "10/12/2026".
fn is_digit_date(word: &str) -> bool {
    let digits = bare(word);
    let mut parts = digits.split(['-', '/']);
    let (Some(first), Some(second), Some(third), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    let numbers = [first, second, third]
        .iter()
        .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()));
    let iso = first.len() == 4 && second.len() == 2 && third.len() == 2;
    let slashed = digits.contains('/') && first.len() <= 2 && second.len() <= 2;
    numbers && (iso || slashed)
}

/// Whether `line` holds a date ("Oct 12", "12 October", "2026-10-12",
/// "10/12/2026") or says how long it takes to read ("6 min read").
pub(crate) fn has_date(line: &str) -> bool {
    if line
        .as_bytes()
        .windows(8)
        .any(|window| window.eq_ignore_ascii_case(b"min read"))
    {
        return true;
    }
    if !line.bytes().any(|b| b.is_ascii_digit()) {
        return false;
    }
    let mut before: Option<&str> = None;
    let mut words = line.split_whitespace().peekable();
    while let Some(word) = words.next() {
        if is_month(word)
            && (words.peek().is_some_and(|next| is_day_number(next))
                || before.is_some_and(is_day_number))
        {
            return true;
        }
        if is_digit_date(word) {
            return true;
        }
        before = Some(word);
    }
    false
}

/// Whether every word of `line` is about when: a date, a weekday, a time,
/// "Today", "at" ("October 12, 2026 at 2:31 PM", "Yesterday", "Monday,
/// October 12th"). A chat's day divider, a note's time stamp.
pub(crate) fn date_only(line: &str) -> bool {
    let mut telling = false;
    for (count, word) in line.split_whitespace().enumerate() {
        if count >= 8 {
            return false;
        }
        let lower = bare(word);
        if lower.is_empty() {
            continue;
        }
        let is = |names: &[&str]| names.iter().any(|name| lower.eq_ignore_ascii_case(name));
        if is_month(word)
            || is_weekday(word)
            || is_clock(word)
            || is(&["today", "yesterday", "tomorrow"])
        {
            telling = true;
        } else if !(is_day_number(word)
            || (lower.len() == 4 && lower.bytes().all(|b| b.is_ascii_digit()))
            || is(&["at", "am", "pm", "a.m", "p.m"]))
        {
            return false;
        }
    }
    telling
}

/// A line with a date or "min read", short enough to be a byline.
pub(crate) fn byline_like(line: &str) -> bool {
    line.trim().chars().count() <= 100 && has_date(line)
}

/// Whether `line` is shaped like a heading: at most 80 characters and 12
/// words, starting with a capital or a digit (or a letter of a script with
/// no capitals), with two letters or more, not ending in a full stop, a
/// comma, a semicolon, a colon or "!", and not a list item, a speaker line,
/// a date or a line of code.
pub(crate) fn heading_shaped(line: &str) -> bool {
    heading_shape(line) && list_item(line).is_none() && !code_line(line)
}

/// [`heading_shaped`] but for being a list item or code, which the caller
/// knows.
fn heading_shape(line: &str) -> bool {
    let text = line.trim();
    let Some(first) = text.chars().next() else {
        return false;
    };
    let caseless = first.is_alphabetic() && !first.is_lowercase() && !first.is_uppercase();
    text.len() <= 320
        && text.chars().count() <= 80
        && text.split_whitespace().count() <= 12
        && (first.is_uppercase() || first.is_ascii_digit() || caseless)
        && !text.ends_with(['.', ',', ';', ':', '!', '\u{3002}'])
        && text.chars().filter(|ch| ch.is_alphabetic()).take(2).count() == 2
        && !ASSISTANT_LABELS.contains(&text)
        && speaker_line(text).is_none()
        && !date_only(text)
}

/// Whether `next`, with `after` the line after it, is a heading the line
/// before it must not run into: it names the window, or it is shaped like a
/// heading and comes right before a line of 60 characters or more or a list
/// item.
pub(crate) fn heading_follows(next: &str, after: Option<&str>, lead: Option<&str>) -> bool {
    names_window(next, lead)
        || (heading_shaped(next)
            && after.is_some_and(|after| {
                after.trim_end().chars().count() >= 60 || list_item(after).is_some()
            }))
}

/// A short line in capitals: at most 40 characters and five words, with
/// capital letters and no small ones ("MONEY & ROUNDING").
fn label_shaped(line: &str) -> bool {
    let text = line.trim();
    text.chars().count() <= 40
        && text.split_whitespace().count() <= 5
        && text.chars().filter(|ch| ch.is_alphabetic()).take(2).count() == 2
        && text.chars().any(char::is_uppercase)
        && !text.chars().any(char::is_lowercase)
}

/// Whether one line reads like code: it calls something (`round(2.5)`),
/// indexes something, assigns, compares or points (`=`, `==`, `->`, `=>`,
/// `::`, `&&`), opens or closes a block (`{`, `}`), ends in `;`, is a
/// comment or an attribute, or starts with a keyword that only code starts
/// with. A sentence with a word in parentheses, a sentence's semicolon and a
/// line that ends in a colon or a comma are prose.
pub(crate) fn code_line(line: &str) -> bool {
    let text = line.trim();
    !text.is_empty() && (code_mark(text) || (code_signal(text) && !sentence_like(text)))
}

/// A comment or an attribute: only code starts a line so, however much the
/// rest reads like a sentence.
fn code_mark(text: &str) -> bool {
    const MARKS: [&str; 8] = [
        "//", "/*", "*/", "#!", "#[", "#include", "#define", "#import",
    ];
    MARKS.iter().any(|mark| text.starts_with(mark))
}

fn code_signal(text: &str) -> bool {
    /// "::", "->", "=>", "==", "!=", "<=", ">=", "+=", "-=", "&&", "||",
    /// ":=", "</" and "/>": two ASCII bytes each, found in one pass.
    fn operator(pair: &[u8]) -> bool {
        matches!(
            pair,
            b"::"
                | b"->"
                | b"=>"
                | b"=="
                | b"!="
                | b"<="
                | b">="
                | b"+="
                | b"-="
                | b"&&"
                | b"||"
                | b":="
                | b"</"
                | b"/>"
        )
    }
    /// Words code starts a line with, and prose too ("let me know", "use the
    /// form"): they count only with code's punctuation on the line.
    const KEYWORDS: [&str; 22] = [
        "let ", "fn ", "pub ", "def ", "func ", "var ", "const ", "import ", "export ", "return ",
        "class ", "struct ", "impl ", "use ", "enum ", "if (", "for (", "while (", "} else",
        "elif ", "from ", "async ",
    ];
    if KEYWORDS.iter().any(|keyword| text.starts_with(keyword)) {
        return text.contains(['(', ')', '=', ':', '{', ';', '<', '[', '\'', '"']);
    }
    if text.ends_with(['{', '}', ';']) || text == ")" || text == "]" {
        return true;
    }
    let bytes = text.as_bytes();
    if bytes.windows(2).any(operator) {
        return true;
    }
    for (at, &byte) in bytes.iter().enumerate() {
        match byte {
            // A call or an index: a name right before the bracket.
            b'(' | b'[' if at > 0 => {
                let before = bytes[at - 1];
                if before.is_ascii_alphanumeric()
                    || before == b'_'
                    || before == b'!'
                    || before == b'&'
                {
                    return true;
                }
            }
            // An assignment: a name, then " = ".
            b'=' if at > 1 && bytes[at - 1] == b' ' && bytes.get(at + 1) == Some(&b' ') => {
                let name = text[..at - 1]
                    .split_whitespace()
                    .next_back()
                    .unwrap_or_default();
                if !name.is_empty()
                    && name.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'[' | b']')
                    })
                {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

/// Prose: six words or more, three quarters of what is not a space letters,
/// no brace and no semicolon at the end. A wrapped line of a sentence counts,
/// wherever it ends.
fn sentence_like(text: &str) -> bool {
    let (mut words, mut shown, mut letters, mut space) = (0usize, 0usize, 0usize, true);
    for ch in text.chars() {
        if ch.is_whitespace() {
            space = true;
            continue;
        }
        if space {
            words += 1;
            space = false;
        }
        if matches!(ch, '{' | '}') {
            return false;
        }
        shown += 1;
        letters += usize::from(ch.is_alphabetic());
    }
    words >= 6 && letters * 4 >= shown * 3 && !text.ends_with(';')
}

/// The first part of a window's title, which names what the window shows:
/// before " - ", " — ", " – ", " | " or " · ", without the marks an app
/// puts before a title or a document's file extension ("Pricing
/// study.pdf"). None when it only names the app or says nothing
/// ("Notes", "New Tab", "Untitled").
pub(crate) fn title_lead<'t>(title: &'t str, app: Option<&str>) -> Option<&'t str> {
    const SEPARATORS: [&str; 5] = [" - ", " \u{2014} ", " \u{2013} ", " | ", " \u{00B7} "];
    const GENERIC: [&str; 8] = [
        "new tab",
        "untitled",
        "home",
        "inbox",
        "notes",
        "new message",
        "new chat",
        "start page",
    ];
    /// A document's file name ends so; its heading does not.
    const DOCUMENT_EXTENSIONS: [&str; 10] = [
        ".pdf", ".docx", ".doc", ".pages", ".key", ".numbers", ".xlsx", ".rtf", ".txt", ".md",
    ];
    let title = chrome::without_title_marks(title).trim();
    let lead = SEPARATORS
        .iter()
        .filter_map(|separator| title.find(separator))
        .min()
        .map_or(title, |at| title[..at].trim());
    let lead = DOCUMENT_EXTENSIONS
        .iter()
        .find_map(|extension| lead.strip_suffix(extension))
        .map_or(lead, str::trim_end);
    let lower = lead.to_lowercase();
    let app_name = app.and_then(apps::known_name).map(str::to_lowercase);
    (!lead.is_empty()
        && !GENERIC.contains(&lower.as_str())
        && app_name.as_deref() != Some(lower.as_str()))
    .then_some(lead)
}

/// Whether `line` names the window: it is the first part of its title, by
/// its words, in any case, with quotes around them or not.
fn names_window(line: &str, lead: Option<&str>) -> bool {
    let Some(lead) = lead else {
        return false;
    };
    let line = line.trim();
    if line.is_empty() || line.len() > lead.len() * 2 + 8 || line.chars().count() > 120 {
        return false;
    }
    let quote = |ch: char| matches!(ch, '"' | '\u{201C}' | '\u{201D}');
    let mut ours = line
        .split_whitespace()
        .map(|word| word.trim_matches(quote))
        .filter(|word| !word.is_empty());
    let mut theirs = lead
        .split_whitespace()
        .map(|word| word.trim_matches(quote))
        .filter(|word| !word.is_empty());
    loop {
        match (ours.next(), theirs.next()) {
            (None, None) => return true,
            (Some(a), Some(b)) => {
                let same = if a.is_ascii() && b.is_ascii() {
                    a.eq_ignore_ascii_case(b)
                } else {
                    a.chars()
                        .flat_map(char::to_lowercase)
                        .eq(b.chars().flat_map(char::to_lowercase))
                };
                if !same {
                    return false;
                }
            }
            _ => return false,
        }
    }
}

/// Whether a run's lines are a table whose cells are known: two rows or
/// more, each with a tab, and most with the same number of cells.
fn is_table(lines: &[&str]) -> bool {
    if lines.len() < 2 || !lines.iter().all(|line| line.contains('\t')) {
        return false;
    }
    let cells: Vec<usize> = lines.iter().map(|line| line.split('\t').count()).collect();
    let first = cells[0];
    cells.iter().filter(|&&count| count == first).count() * 2 > cells.len()
}

/// Whether a run reads like code as a whole: a line starts with a shell
/// prompt, four lines in ten read like code, or it has three indent levels
/// with a quarter of its lines indented. A single line of code alone in its
/// run is code. A run with two sentences of prose in it is not code as a
/// whole (an answer around a code sample): its code is found line by line.
fn is_code_run(lines: &[&str]) -> bool {
    is_code_run_with(lines, &Facts::of(lines))
}

/// What the rules ask of each line of a run more than once, asked once.
struct Facts {
    /// The line reads like code ([`code_line`]).
    code: Vec<bool>,
    /// The line starts a list item ([`list_item`]).
    item: Vec<bool>,
}

impl Facts {
    fn of(lines: &[&str]) -> Self {
        Self {
            code: lines.iter().map(|line| code_line(line)).collect(),
            item: lines.iter().map(|line| list_item(line).is_some()).collect(),
        }
    }

    /// [`heading_shaped`], for line `at`.
    fn heading(&self, lines: &[&str], at: usize) -> bool {
        !self.code[at] && !self.item[at] && heading_shape(lines[at])
    }
}

fn is_code_run_with(lines: &[&str], facts: &Facts) -> bool {
    if lines.iter().any(|line| starts_with_prompt(line)) {
        return true;
    }
    let prose = lines
        .iter()
        .zip(&facts.code)
        .filter(|(line, code)| {
            let text = line.trim();
            !**code && text.len() >= 60 && text.chars().count() >= 60 && sentence_like(text)
        })
        .count();
    if prose >= 2 {
        return false;
    }
    let code = facts.code.iter().filter(|code| **code).count();
    if code * 10 >= lines.len() * 4 {
        return true;
    }
    // Indents make code, not a list with items under items.
    let items = facts.item.iter().filter(|item| **item).count();
    if items * 2 >= lines.len() {
        return false;
    }
    let mut levels: Vec<usize> = Vec::new();
    let mut indented = 0usize;
    for line in lines {
        let depth = line.chars().take_while(|ch| ch.is_whitespace()).count();
        indented += usize::from(depth > 0);
        if !levels.contains(&depth) {
            levels.push(depth);
        }
    }
    levels.len() >= 3 && indented * 4 >= lines.len() && lines.len() >= 3
}

/// Whether a run is rows of numbers: two rows or more, six in ten of them
/// with two numbers.
fn is_number_rows(lines: &[&str]) -> bool {
    let numeric = lines
        .iter()
        .filter(|line| {
            line.split_whitespace()
                .filter(|token| is_number(token))
                .nth(1)
                .is_some()
        })
        .count();
    lines.len() >= 2 && numeric * 10 >= lines.len() * 6
}

fn is_number(token: &str) -> bool {
    token
        .trim_start_matches([
            '$', '\u{20AC}', '\u{00A3}', '\u{00A5}', '+', '-', '\u{2212}', '(',
        ])
        .starts_with(|ch: char| ch.is_ascii_digit())
}

/// A table cell that is a number: digits with an optional currency sign,
/// grouping, decimals, sign or percent.
fn numeric_cell(cell: &str) -> bool {
    let cell = cell.trim();
    let body = cell
        .trim_start_matches([
            '$', '\u{20AC}', '\u{00A3}', '\u{00A5}', '+', '-', '\u{2212}', '(',
        ])
        .trim_end_matches(['%', ')']);
    !body.is_empty()
        && body.starts_with(|ch: char| ch.is_ascii_digit())
        && body
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, ',' | '.' | ' '))
}

/// Mail's header lines: a sender with an address, "To:", "Cc:", "Date:",
/// "to me", a time, or a date.
fn mail_header_line(line: &str) -> bool {
    let text = line.trim();
    let lower = text.to_lowercase();
    if [
        "from:",
        "to:",
        "cc:",
        "bcc:",
        "date:",
        "reply-to:",
        "subject:",
        "sent:",
    ]
    .iter()
    .any(|field| lower.starts_with(field))
    {
        return true;
    }
    if lower == "to me" || lower.starts_with("to me,") || lower.starts_with("to me ") {
        return true;
    }
    if (lower.starts_with("to ") || lower.starts_with("cc "))
        && text.split_whitespace().count() <= 6
    {
        return text.split_whitespace().skip(1).all(|word| {
            word.starts_with(|ch: char| ch.is_uppercase()) || word.contains('@') || word == "me,"
        });
    }
    if text.contains('@') && text.contains('<') && text.contains('>') && text.chars().count() <= 120
    {
        return true;
    }
    date_only(text) || (byline_like(text) && text.chars().count() <= 60 && !text.ends_with('.'))
}

/// A name alone on its line: one to four words, each starting with a
/// capital, nothing but letters and name punctuation.
fn bare_name(line: &str) -> bool {
    let words: Vec<&str> = line.split_whitespace().collect();
    (1..=4).contains(&words.len())
        && line.trim().chars().count() <= 40
        && words.iter().all(|word| {
            word.starts_with(char::is_uppercase)
                && word
                    .chars()
                    .all(|ch| ch.is_alphabetic() || matches!(ch, '\'' | '\u{2019}' | '-' | '.'))
        })
}

/// "On Oct 3, 2026, at 9:14 AM, Sam wrote:" and its kin.
fn starts_quote(line: &str) -> bool {
    let text = line.trim();
    text.starts_with("On ")
        && text.ends_with("wrote:")
        && (12..=200).contains(&text.chars().count())
}

fn signature_start(line: &str) -> bool {
    let text = line.trim_end();
    text == "--" || text == "-- " || text == "\u{2014}" || text == "__"
}

fn sent_from(line: &str) -> bool {
    let text = line.trim();
    text.starts_with("Sent from my ") || text.starts_with("Get Outlook for ")
}

// ---------------------------------------------------------------------------
// Making the blocks
// ---------------------------------------------------------------------------

/// A line of `main`: where it starts, and its text without the line break.
#[derive(Debug, Clone, Copy)]
struct Line<'m> {
    start: usize,
    text: &'m str,
}

impl Line<'_> {
    fn end(&self) -> usize {
        self.start + self.text.len()
    }

    fn chars(&self) -> usize {
        self.text.trim_end().chars().count()
    }
}

/// The runs of lines between blank lines.
fn runs(main: &str) -> Vec<Vec<Line<'_>>> {
    let mut out: Vec<Vec<Line<'_>>> = Vec::new();
    let mut current: Vec<Line<'_>> = Vec::new();
    let mut at = 0usize;
    for text in main.split('\n') {
        let line = Line { start: at, text };
        at += text.len() + 1;
        if text.trim().is_empty() {
            if !current.is_empty() {
                out.push(std::mem::take(&mut current));
            }
        } else {
            current.push(line);
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// What a line is, as the rules decide it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    /// Not decided yet.
    Free,
    Plain,
    Code,
    Item,
    /// A line under a list item, part of it.
    More,
    Label,
    H1,
    H2,
    Byline,
    Meta,
    Quote,
    /// A row of a table whose cells are known.
    Table,
}

/// A block and the span of `main` it was made from.
struct Piece {
    start: usize,
    end: usize,
    block: Block,
}

impl Piece {
    fn of(lines: &[Line<'_>], block: Block) -> Self {
        Self {
            start: lines.first().map_or(0, |line| line.start),
            end: lines.last().map_or(0, Line::end),
            block,
        }
    }
}

/// The blocks of `main`, the text a person was reading in `window`, which
/// was acquired as `source`. None when it holds no text.
#[must_use]
pub fn blocks(main: &str, window: &Window<'_>, source: EventSource) -> Vec<Block> {
    if main.trim().is_empty() {
        return Vec::new();
    }
    let kind = kind_of_window(window, source);
    let lead = window.title.and_then(|title| title_lead(title, window.app));
    let made = match kind {
        Kind::Terminal => terminal(main),
        Kind::People => chat(main),
        Kind::Editor => editor(main, lead),
        Kind::Sheet => sheet(main, lead),
        Kind::Mail => mail(main, lead),
        Kind::Document => document(main, Doc::new(lead)),
        Kind::AiChat => document(main, Doc::new(lead).without_question_headings()),
    };
    capped(merged(made, main), main)
}

/// Code next to code, and a quote next to a quote, with only blank lines
/// between them, are one block: a code sample with blank lines in it, a
/// quoted thread. The text in between is `main`'s own, blank lines and all.
fn merged(made: Vec<Piece>, main: &str) -> Vec<Piece> {
    let mut out: Vec<Piece> = Vec::with_capacity(made.len());
    for piece in made {
        if let Some(last) = out.last_mut() {
            let same = matches!(
                (&last.block, &piece.block),
                (Block::Code { .. }, Block::Code { .. })
                    | (Block::Quote { .. }, Block::Quote { .. })
            );
            if same && main[last.end..piece.start].trim().is_empty() {
                let text = main[last.start..piece.end].to_owned();
                last.end = piece.end;
                last.block = match last.block {
                    Block::Code { .. } => Block::Code { text },
                    _ => Block::Quote { text },
                };
                continue;
            }
        }
        out.push(piece);
    }
    out
}

/// The pieces within [`MAX_ELEMENTS`]: past it, the rest of `main` from the
/// block that would go over is one paragraph, as read.
fn capped(made: Vec<Piece>, main: &str) -> Vec<Block> {
    let mut out = Vec::with_capacity(made.len());
    let mut count = 0usize;
    for piece in made {
        let elements = piece.block.elements();
        if count + elements > MAX_ELEMENTS {
            let rest = main[piece.start..].trim_matches('\n');
            if !rest.trim().is_empty() {
                out.push(Block::Paragraph {
                    text: rest.to_owned(),
                });
            }
            return out;
        }
        count += elements;
        out.push(piece.block);
    }
    out
}

/// A terminal: one block, every line as read, prompt lines marked.
fn terminal(main: &str) -> Vec<Piece> {
    let prompts = main
        .split('\n')
        .enumerate()
        .filter(|(_, line)| starts_with_prompt(line))
        .filter_map(|(at, _)| u32::try_from(at).ok())
        .take(MAX_ELEMENTS - 1)
        .collect();
    vec![Piece {
        start: 0,
        end: main.len(),
        block: Block::Terminal {
            text: main.to_owned(),
            prompts,
        },
    }]
}

/// A turn being read: its speaker line, and what was said under it.
struct OpenTurn<'m> {
    line: Line<'m>,
    speaker: &'m str,
    time: &'m str,
    said: Vec<Line<'m>>,
}

impl OpenTurn<'_> {
    fn close(self) -> Piece {
        let end = self.said.last().map_or(self.line.end(), Line::end);
        Piece {
            start: self.line.start,
            end,
            block: Block::Turn {
                speaker: self.speaker.to_owned(),
                time: self.time.to_owned(),
                text: self
                    .said
                    .iter()
                    .map(|line| line.text.trim())
                    .collect::<Vec<_>>()
                    .join("\n"),
            },
        }
    }
}

/// A chat with people: turns when speaker lines are read, else a paragraph
/// for each line.
fn chat(main: &str) -> Vec<Piece> {
    let lines: Vec<Line<'_>> = runs(main).into_iter().flatten().collect();
    let has_speakers = lines.iter().any(|line| speaker_line(line.text).is_some());
    let mut out: Vec<Piece> = Vec::new();
    let mut turn: Option<OpenTurn<'_>> = None;
    for line in lines {
        if has_speakers {
            if let Some((speaker, time)) = speaker_line(line.text) {
                out.extend(turn.take().map(OpenTurn::close));
                turn = Some(OpenTurn {
                    line,
                    speaker,
                    time,
                    said: Vec::new(),
                });
                continue;
            }
            if date_only(line.text) {
                // A day divider between messages.
                out.extend(turn.take().map(OpenTurn::close));
                out.push(Piece::of(
                    &[line],
                    Block::Meta {
                        text: line.text.trim().to_owned(),
                    },
                ));
                continue;
            }
            if let Some(open) = turn.as_mut() {
                open.said.push(line);
                continue;
            }
        }
        out.push(Piece::of(
            &[line],
            Block::Paragraph {
                text: line.text.trim().to_owned(),
            },
        ));
    }
    out.extend(turn.take().map(OpenTurn::close));
    out
}

/// A code editor: its code as one block, lines as read; the rest of the
/// window by the document rules.
fn editor(main: &str, lead: Option<&str>) -> Vec<Piece> {
    let mut out: Vec<Piece> = Vec::new();
    let mut doc = Doc::new(lead);
    for run in runs(main) {
        let texts: Vec<&str> = run.iter().map(|line| line.text).collect();
        if is_code_run(&texts) || is_preformatted(&texts) {
            out.push(Piece::of(
                &run,
                Block::Code {
                    text: texts.join("\n"),
                },
            ));
            continue;
        }
        doc.run(&run, &mut [], &mut out);
    }
    out
}

/// A spreadsheet: tables where cells are known, table-like rows otherwise.
/// The line that names the window, among the first ones, is its heading.
fn sheet(main: &str, lead: Option<&str>) -> Vec<Piece> {
    let mut out: Vec<Piece> = Vec::new();
    let mut named = false;
    for run in runs(main) {
        let mut lines: &[Line<'_>] = &run;
        let title = (!named)
            .then(|| {
                lines
                    .iter()
                    .take(3)
                    .position(|line| names_window(line.text, lead))
            })
            .flatten();
        if let Some(title) = title {
            named = true;
            if title > 0 {
                out.push(rows(&lines[..title]));
            }
            out.push(Piece::of(
                &lines[title..=title],
                Block::Heading {
                    level: 1,
                    text: lines[title].text.trim().to_owned(),
                },
            ));
            lines = &lines[title + 1..];
            if lines.is_empty() {
                continue;
            }
        }
        out.push(rows(lines));
    }
    out
}

/// A sheet's rows: a table when their cells are known, else table-like lines.
fn rows(lines: &[Line<'_>]) -> Piece {
    let texts: Vec<&str> = lines.iter().map(|line| line.text).collect();
    let block = if is_table(&texts) {
        table(&texts)
    } else {
        Block::Lines {
            lines: texts.iter().map(|text| (*text).to_owned()).collect(),
            table: true,
        }
    };
    Piece::of(lines, block)
}

fn table(lines: &[&str]) -> Block {
    let rows: Vec<Vec<String>> = lines
        .iter()
        .map(|line| line.split('\t').map(str::to_owned).collect())
        .collect();
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let numeric: Vec<bool> = (0..columns)
        .map(|column| {
            let mut cells = rows
                .iter()
                .skip(1)
                .filter_map(|row| row.get(column))
                .filter(|cell| !cell.trim().is_empty())
                .peekable();
            cells.peek().is_some() && cells.all(|cell| numeric_cell(cell))
        })
        .collect();
    let numeric = if numeric.contains(&true) {
        numeric
    } else {
        Vec::new()
    };
    Block::Table { rows, numeric }
}

/// Mail: the subject, the header lines, the body by the document rules,
/// then quotes and the signature.
fn mail(main: &str, lead: Option<&str>) -> Vec<Piece> {
    let runs = runs(main);
    let lines: Vec<Line<'_>> = runs.iter().flatten().copied().collect();
    let mut roles = vec![Role::Free; lines.len()];
    // The subject, among the first lines.
    let subject = lines
        .iter()
        .take(12)
        .position(|line| names_window(line.text, lead));
    let mut at = 0usize;
    if let Some(subject) = subject {
        roles[subject] = Role::H1;
        at = subject + 1;
        // A sender's name alone on the line under the subject.
        if lines
            .get(at)
            .is_some_and(|line| bare_name(line.text) && !mail_header_line(line.text))
            && lines.get(at + 1).is_some()
        {
            roles[at] = Role::Meta;
            at += 1;
        }
    }
    while at < lines.len() && at < 16 && mail_header_line(lines[at].text) {
        roles[at] = Role::Meta;
        at += 1;
    }
    // Quotes and the signature.
    let mut quoting = false;
    let mut signing = false;
    for (index, line) in lines.iter().enumerate().skip(at) {
        if !quoting && starts_quote(line.text) {
            quoting = true;
        }
        if quoting || line.text.trim_start().starts_with('>') {
            roles[index] = Role::Quote;
            continue;
        }
        if signature_start(line.text) {
            signing = true;
        }
        if signing || sent_from(line.text) {
            roles[index] = Role::Meta;
        }
    }
    let mut doc = Doc::new(lead);
    doc.h1 = subject.is_some();
    let mut out: Vec<Piece> = Vec::new();
    let mut offset = 0usize;
    for run in &runs {
        let run_roles = &mut roles[offset..offset + run.len()];
        offset += run.len();
        doc.run(run, run_roles, &mut out);
    }
    out
}

/// The document rules, run by run.
fn document(main: &str, mut doc: Doc<'_>) -> Vec<Piece> {
    let mut out: Vec<Piece> = Vec::new();
    for run in runs(main) {
        doc.run(&run, &mut [], &mut out);
    }
    out
}

/// What the document rules carry from one run to the next.
struct Doc<'l> {
    lead: Option<&'l str>,
    /// The level-1 heading has been found.
    h1: bool,
    /// Lines since the level-1 heading, once it was found.
    since_h1: Option<usize>,
    /// A question over a long line may be a section's heading (a page's
    /// "What is a seat minimum?"), but not in an AI chat, where it is what
    /// the person asked.
    question_headings: bool,
}

impl<'l> Doc<'l> {
    fn new(lead: Option<&'l str>) -> Self {
        Self {
            lead,
            h1: false,
            since_h1: None,
            question_headings: true,
        }
    }

    fn without_question_headings(mut self) -> Self {
        self.question_headings = false;
        self
    }

    /// The blocks of one run of lines. `preset` holds roles already decided
    /// (mail's header lines, quotes and signature), or is empty.
    fn run(&mut self, run: &[Line<'_>], preset: &mut [Role], out: &mut Vec<Piece>) {
        let texts: Vec<&str> = run.iter().map(|line| line.text).collect();
        let facts = Facts::of(&texts);
        if preset.iter().all(|role| *role == Role::Free) {
            let whole = if is_table(&texts) {
                Some(table(&texts))
            } else if is_code_run_with(&texts, &facts) {
                Some(Block::Code {
                    text: texts.join("\n"),
                })
            } else if is_number_rows(&texts) {
                Some(Block::Lines {
                    lines: texts.iter().map(|text| (*text).to_owned()).collect(),
                    table: true,
                })
            } else {
                None
            };
            if let Some(block) = whole {
                self.passed(run.len());
                out.push(Piece::of(run, block));
                return;
            }
        }
        let mut roles: Vec<Role> = if preset.is_empty() {
            vec![Role::Free; run.len()]
        } else {
            preset.to_vec()
        };
        self.decide(run, &texts, &facts, &mut roles);
        emit(run, &roles, out);
    }

    /// Counts lines passed since the level-1 heading.
    fn passed(&mut self, lines: usize) {
        if let Some(since) = self.since_h1.as_mut() {
            *since += lines;
        }
    }

    fn decide(&mut self, run: &[Line<'_>], texts: &[&str], facts: &Facts, roles: &mut [Role]) {
        let n = run.len();
        // Rows with tab-separated cells, two or more in a row.
        let mut at = 0;
        while at < n {
            let mut end = at;
            while end < n && roles[end] == Role::Free && run[end].text.contains('\t') {
                end += 1;
            }
            let texts: Vec<&str> = run[at..end].iter().map(|line| line.text).collect();
            if is_table(&texts) {
                roles[at..end].fill(Role::Table);
            }
            at = end.max(at + 1);
        }
        // Two or more lines of code in a row.
        let mut at = 0;
        while at < n {
            if roles[at] == Role::Free && facts.code[at] {
                let mut end = at;
                while end < n && roles[end] == Role::Free && facts.code[end] {
                    end += 1;
                }
                if end - at >= 2 {
                    roles[at..end].fill(Role::Code);
                }
                at = end;
            } else {
                at += 1;
            }
        }
        // A code block's label and button over it ("rust", "Copy code"):
        // what was read, kept quiet.
        for at in 0..n {
            if roles[at] == Role::Code && (at == 0 || roles[at - 1] != Role::Code) {
                for above in (at.saturating_sub(2)..at).rev() {
                    if roles[above] != Role::Free || !code_label(run[above].text) {
                        break;
                    }
                    roles[above] = Role::Meta;
                }
            }
        }
        // List items, and the lines indented under them.
        let mut at = 0;
        while at < n {
            let item = (roles[at] == Role::Free && facts.item[at])
                .then(|| list_item(run[at].text))
                .flatten();
            let Some(item) = item else {
                at += 1;
                continue;
            };
            roles[at] = Role::Item;
            at += 1;
            while at < n
                && roles[at] == Role::Free
                && !facts.item[at]
                && indent_chars(run[at].text) > item.indent
                && !facts.code[at]
            {
                roles[at] = Role::More;
                at += 1;
            }
        }
        // The level-1 heading, its byline, labels and section headings.
        for at in 0..n {
            self.passed(1);
            if roles[at] != Role::Free {
                continue;
            }
            let text = run[at].text;
            if !self.h1 && names_window(text, self.lead) {
                self.h1 = true;
                self.since_h1 = Some(0);
                roles[at] = Role::H1;
                // A time stamp right over it is its byline (a note's date).
                if at > 0 && roles[at - 1] == Role::Plain && date_only(run[at - 1].text) {
                    roles[at - 1] = Role::Byline;
                }
                continue;
            }
            if self.since_h1.is_some_and(|since| since <= 3) && byline_like(text) {
                roles[at] = Role::Byline;
                continue;
            }
            let next = (at + 1 < n).then(|| (run[at + 1].text, roles[at + 1]));
            if label_shaped(text)
                && next.is_some_and(|(next, role)| {
                    role == Role::Free
                        && (names_window(next, self.lead) || facts.heading(texts, at + 1))
                })
            {
                roles[at] = Role::Label;
                // The line after it is a heading: the window's own name,
                // decided next, or a section's.
                if self.h1 || !names_window(run[at + 1].text, self.lead) {
                    roles[at + 1] = Role::H2;
                }
                continue;
            }
            if facts.heading(texts, at) && self.section_heading(run, texts, facts, roles, at) {
                roles[at] = Role::H2;
                continue;
            }
            roles[at] = Role::Plain;
        }
    }

    /// Whether the heading-shaped line `at` is a section's heading: it
    /// stands alone in its run; or it comes right before a line of 60
    /// characters or more, a list, code or a table, and not right after a
    /// short line of its own shape (then it is one of a group of rows); or it
    /// comes after a list, code or a long line and before two short lines
    /// (a title over rows: "Owners", then "Rounding fix Sam").
    fn section_heading(
        &self,
        run: &[Line<'_>],
        texts: &[&str],
        facts: &Facts,
        roles: &[Role],
        at: usize,
    ) -> bool {
        let n = run.len();
        if n == 1 {
            return true;
        }
        let text = run[at].text.trim();
        if !self.question_headings && text.ends_with('?') {
            return false;
        }
        let long = |line: &Line<'_>| line.chars() >= 60;
        let short = |index: usize| {
            index < n && roles[index] == Role::Free && run[index].chars() < 40 && !facts.item[index]
        };
        let in_rows = at > 0 && roles[at - 1] == Role::Plain && facts.heading(texts, at - 1);
        let before_body = at + 1 < n
            && (matches!(roles[at + 1], Role::Item | Role::Code | Role::Table)
                || (roles[at + 1] == Role::Free && long(&run[at + 1])));
        let after_break = at > 0
            && (matches!(
                roles[at - 1],
                Role::Item | Role::More | Role::Code | Role::Table
            ) || long(&run[at - 1]));
        (before_body && !in_rows) || (after_break && short(at + 1) && short(at + 2))
    }
}

/// A code block's label or button, read over it: a language's name or
/// "Copy code".
fn code_label(line: &str) -> bool {
    const LABELS: [&str; 34] = [
        "Copy code",
        "Copy",
        "Copy to clipboard",
        "rust",
        "python",
        "swift",
        "javascript",
        "typescript",
        "js",
        "ts",
        "jsx",
        "tsx",
        "bash",
        "sh",
        "shell",
        "zsh",
        "console",
        "json",
        "yaml",
        "toml",
        "sql",
        "go",
        "java",
        "kotlin",
        "c",
        "cpp",
        "csharp",
        "ruby",
        "php",
        "html",
        "css",
        "diff",
        "text",
        "plaintext",
    ];
    LABELS.contains(&line.trim())
}

fn indent_chars(line: &str) -> usize {
    line.chars().take_while(|ch| ch.is_whitespace()).count()
}

/// The blocks of a run whose roles are decided, in order.
fn emit(run: &[Line<'_>], roles: &[Role], out: &mut Vec<Piece>) {
    let longest = run.iter().map(Line::chars).max().unwrap_or(0);
    let n = run.len();
    let mut at = 0;
    while at < n {
        let role = roles[at];
        let mut end = at + 1;
        let same = |role: Role, other: Role| match role {
            Role::Item | Role::More => matches!(other, Role::Item | Role::More),
            Role::Plain | Role::Free => matches!(other, Role::Plain | Role::Free),
            Role::Code | Role::Quote | Role::Meta | Role::Table => other == role,
            _ => false,
        };
        while end < n && same(role, roles[end]) {
            end += 1;
        }
        let lines = &run[at..end];
        let text = lines[0].text.trim().to_owned();
        match role {
            Role::Code => out.push(Piece::of(
                lines,
                Block::Code {
                    text: lines
                        .iter()
                        .map(|line| line.text)
                        .collect::<Vec<_>>()
                        .join("\n"),
                },
            )),
            Role::Item | Role::More => {
                if let Some(block) = list(lines, roles.get(at..end).unwrap_or_default()) {
                    out.push(Piece::of(lines, block));
                }
            }
            Role::Quote => out.push(Piece::of(
                lines,
                Block::Quote {
                    text: lines
                        .iter()
                        .map(|line| line.text.trim_end())
                        .collect::<Vec<_>>()
                        .join("\n"),
                },
            )),
            Role::Meta if signature_start(lines[0].text) && lines.len() > 1 => {
                out.push(Piece::of(
                    lines,
                    Block::Meta {
                        text: lines
                            .iter()
                            .map(|line| line.text.trim_end())
                            .collect::<Vec<_>>()
                            .join("\n"),
                    },
                ));
            }
            // Header lines: one block each.
            Role::Meta => {
                for line in lines {
                    out.push(Piece::of(
                        std::slice::from_ref(line),
                        Block::Meta {
                            text: line.text.trim().to_owned(),
                        },
                    ));
                }
            }
            Role::H1 | Role::H2 => out.push(Piece::of(
                lines,
                Block::Heading {
                    level: if role == Role::H1 { 1 } else { 2 },
                    text,
                },
            )),
            Role::Table => {
                let texts: Vec<&str> = lines.iter().map(|line| line.text).collect();
                out.push(Piece::of(lines, table(&texts)));
            }
            Role::Label => out.push(Piece::of(lines, Block::Label { text })),
            Role::Byline => out.push(Piece::of(lines, Block::Byline { text })),
            Role::Plain | Role::Free => plain(lines, longest, out),
        }
        at = end;
    }
}

/// Plain lines: a paragraph each, except that two or more short lines in a
/// row (an address, a menu, a sign-off, rows) are one `lines` block. A line
/// is short when it is under 60 characters and three quarters of the run's
/// longest, or when no line of the run reaches 40.
fn plain(lines: &[Line<'_>], longest: usize, out: &mut Vec<Piece>) {
    let short =
        |line: &Line<'_>| longest < 40 || (line.chars() < 60 && line.chars() * 4 < longest * 3);
    let mut at = 0;
    while at < lines.len() {
        let mut end = at;
        while end < lines.len() && short(&lines[end]) {
            end += 1;
        }
        if end - at >= 2 {
            out.push(Piece::of(
                &lines[at..end],
                Block::Lines {
                    lines: lines[at..end]
                        .iter()
                        .map(|line| line.text.to_owned())
                        .collect(),
                    table: false,
                },
            ));
            at = end;
            continue;
        }
        let line = &lines[at];
        out.push(Piece::of(
            std::slice::from_ref(line),
            Block::Paragraph {
                text: line.text.trim().to_owned(),
            },
        ));
        at += 1;
    }
}

/// A list from its item lines and the lines under them.
fn list(lines: &[Line<'_>], roles: &[Role]) -> Option<Block> {
    let base = list_item(lines.first()?.text)?.indent;
    let mut items: Vec<Item> = Vec::new();
    for (line, role) in lines.iter().zip(roles) {
        if *role == Role::Item {
            if let Some(marked) = list_item(line.text) {
                items.push(Item {
                    marker: marked.marker.to_owned(),
                    text: marked.text.trim_end().to_owned(),
                    depth: u8::from(marked.indent > base),
                    checked: marked.checked,
                });
            }
        } else if let Some(last) = items.last_mut() {
            last.text.push('\n');
            last.text.push_str(line.text.trim());
        }
    }
    (!items.is_empty()).then_some(Block::List { items })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_of_codes_operators_makes_a_line_code() {
        for operator in [
            "::", "->", "=>", "==", "!=", "<=", ">=", "+=", "-=", "&&", "||", ":=", "</", "/>",
        ] {
            assert!(code_line(&format!("a {operator} b")), "{operator}");
        }
        // One half of an operator alone is not one.
        for line in [
            "a : b", "a - b", "a < b", "a > b", "a | b", "a & b", "a / b",
        ] {
            assert!(!code_line(line), "{line}");
        }
        assert!(!code_line("Round half up looks fair"));
        // Inside a word of another script, no byte of an operator appears.
        assert!(!code_line("\u{65E5}\u{672C}\u{8A9E}\u{3067}\u{3059}"));
    }
}
