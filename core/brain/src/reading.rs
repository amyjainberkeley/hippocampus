//! Readable text: what a person reads, made from what the store keeps.
//!
//! The store keeps each event's text as it arrived: a header line naming the
//! app, title, address and time, then what the window showed. A window the
//! capture helper classified stores its content, then [`CHROME_SEPARATOR`],
//! then its chrome. Nothing here changes what is stored. The reading is made
//! where text leaves the store: the window, AI tools and the on-device model.
//!
//! - [`body`] is the stored text without its header line.
//! - [`reading`] is `main`, what the person was reading, and `rest`,
//!   everything else in the window (tabs, sidebars, menus, status bars). Only
//!   junk tokens disappear.
//! - [`reading_prefix`] is the start of `main` for list rows. It stops as soon
//!   as it has enough.
//! - [`excerpt`] is a short passage of a reading: around a search's words,
//!   the last lines of a terminal or a chat, otherwise the first lines.
//! - [`passage`] is the same passage made from stored text, cleaning only the
//!   blocks it shows, for lists and search results.
//! - [`audit_text`] is everything stored, for an audit: no header and no
//!   U+001E, every stored word kept.
//!
//! # Rules this round
//!
//! Screen text (`screen_ocr`, `screen_context`, and the part of a
//! `browser_page_with_ocr` event that was read off the screen):
//! - N1: a token that is one CJK, kana or hangul character is junk when under
//!   10% of the text's letters are CJK.
//! - N2: a token made only of box-drawing characters and geometric shapes
//!   (U+2500 to U+25FF), private-use characters or U+FFFD is junk.
//! - A junk token is deleted together with one whitespace character beside
//!   it. Every other byte stays.
//! - N3: outside preformatted blocks, a line with no letter or digit is
//!   dropped, unless it is code's brackets ("}", "});") or a signature's
//!   "--", which formatted text needs.
//! - Outside preformatted blocks, wrapped lines are joined into paragraphs:
//!   in text that carries the separator, which the helper classified, whose
//!   indents are also set to none or four spaces; and in older text of a
//!   browser or a document, whose indents stay. Older text of a terminal, a
//!   code editor or a chat app keeps its lines.
//! - C1: in older text only (a classified window's content is what the
//!   helper kept as content, and stays whole), the window chrome at the
//!   edges of the content moves to `rest`: the run of lines at its top and
//!   the run at its bottom that are chrome by their own shape, place and
//!   window (a browser's tab strip, address bar or bookmarks bar, a web app's
//!   menus and side navigation, a search page's tabs, a site's menu; an
//!   editor's tabs, headings, breadcrumbs or status bar; Slack's sidebar
//!   headings or message box; Messages' receipt and message box; see
//!   [`crate::chrome`]). So do the lines the re-clean job learned from many
//!   frames, when it passes them ([`reading_with`]). The window's title and
//!   address come from the stored header when the caller gives none. A line
//!   that moves is never deleted. If moving would make a secret pattern
//!   appear, nothing moves.
//!
//! A block (the lines between blank lines) is preformatted, and kept byte for
//! byte but for junk tokens, in a terminal, when it reads like code, a table
//! or a shell session, or when it holds a tab. The whole block is judged at
//! once. Every other source is shown as stored, without its header. No
//! reading holds U+001E.
//!
//! # The guard
//!
//! The capture helper stores no OCR text that one of its four secret patterns
//! matches ([`crate::redaction::ocr_secrets`]). Cleaning could make one appear,
//! for example by removing a stray symbol between `token` and `=`, and so
//! could putting two stored pieces side by side that U+001E or a marker kept
//! apart. So:
//! - a cleaned part that matches falls back to the stored parts, with no
//!   other cleaning, cut in the same places;
//! - when `main` and `rest` shown one after the other would match, the words
//!   beside the boundary are left out;
//! - a stray U+001E reads as a space, unless that would match: then the words
//!   on either side of it are left out;
//! - a passage whose cut would make a pattern appear leaves out the cut words.

use std::borrow::Cow;
use std::cell::OnceCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::OnceLock;

use regex::Regex;

use crate::chrome::{self, Apart, RepeatedChrome, Window};
use crate::event_source::EventSource;
use crate::fts_sanitizer::{sanitize_fts5_query, LexicalAlternative};
use crate::reading_blocks::{self, Kind};
use crate::redaction::ocr_secrets::contains_secret;

/// Between a classified window's content and its chrome, in stored text.
/// The helper writes it whenever it classifies, even with no chrome.
pub const CHROME_SEPARATOR: &str = "\n\n\u{1E}\n";

/// Between a browser page's own text and the text read off the screen, in a
/// `browser_page_with_ocr` event.
pub const VISIBLE_OCR_SEPARATOR: &str = "\n\n[VISIBLE-OCR]\n";

/// The line an MCP resource event starts with, before its header.
const MCP_REVISION_PREFIX: &str = "[MCP_RESOURCE revision_sha256=";

/// A header whose title holds a line break is looked for this far.
const WRAPPED_HEADER_BYTES: usize = 8 * 1024;

/// Terminals: every block is kept as it was read, and a passage is the end.
pub const TERMINAL_APPS: [&str; 8] = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "org.alacritty",
    "co.zeit.hyper",
];

/// Chat apps: the newest message is at the bottom, so a passage is the end.
pub const CHAT_APPS: [&str; 12] = [
    "com.tinyspeck.slackmacgap",
    "com.apple.MobileSMS",
    "com.hnc.Discord",
    "net.whatsapp.WhatsApp",
    "desktop.WhatsApp",
    "ru.keepcoder.Telegram",
    "org.telegram.desktop",
    "org.whispersystems.signal-desktop",
    "com.microsoft.teams2",
    "com.facebook.archon",
    "com.openai.chat",
    "com.anthropic.claudefordesktop",
];

/// Words that tell no passage from another: a search for "the roadmap" is
/// shown where "roadmap" is. They count only in a search that has no other
/// word.
const STOP_WORDS: [&str; 34] = [
    "a", "about", "an", "and", "are", "as", "at", "be", "did", "do", "does", "for", "from", "how",
    "i", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "we", "what",
    "when", "where", "which", "who", "why", "with",
];

/// Left context a search passage may show before its first word, in bytes.
const LEAD_BYTES: usize = 32;

/// What a window said, ready to read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Reading {
    /// What the person was reading.
    pub main: String,
    /// Everything else in the window: tabs, sidebars, menus, status bars.
    /// For a browser page read both ways, the text read off the screen.
    pub rest: String,
}

/// The stored text without the header line the store writes before it.
///
/// Strict: the first line is removed only when it is a whole header,
/// `[app=… | title=… | url=…` and `]`, as captures (with `| ts=…`) and
/// transcript imports (with `| session=… | src=…`) write it. A title holding
/// a line break makes the header several lines: it then ends with the first
/// later line that holds ` | url=` and ends in `]`, within 8 KiB. An MCP
/// resource's revision line before the header goes with it. Any other text
/// comes back unchanged.
#[must_use]
pub fn body(stored: &str) -> &str {
    let after_revision = stored
        .strip_prefix(MCP_REVISION_PREFIX)
        .and_then(|rest| rest.split_once("]\n"))
        .filter(|(digest, _)| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
        .map_or(stored, |(_, rest)| rest);
    if let Some((first, rest)) = after_revision.split_once('\n') {
        if is_header(first) {
            return rest;
        }
    }
    wrapped_header_len(after_revision).map_or(stored, |len| &after_revision[len..])
}

fn is_header(line: &str) -> bool {
    line.strip_prefix("[app=")
        .and_then(|fields| fields.strip_suffix(']'))
        .and_then(|fields| fields.split_once(" | title="))
        .is_some_and(|(_, after_title)| after_title.contains(" | url="))
}

/// The window title and page address the stored header names, when the
/// text has a whole header ([`body`]). An address of `?` is none.
#[must_use]
pub fn header_fields(stored: &str) -> (Option<&str>, Option<&str>) {
    let after_revision = stored
        .strip_prefix(MCP_REVISION_PREFIX)
        .and_then(|rest| rest.split_once("]\n"))
        .filter(|(digest, _)| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
        .map_or(stored, |(_, rest)| rest);
    let header = match after_revision.split_once('\n') {
        Some((first, _)) if is_header(first) => first,
        _ => match wrapped_header_len(after_revision) {
            Some(len) => after_revision[..len].trim_end_matches('\n'),
            None => return (None, None),
        },
    };
    let Some((_, after_title)) = header
        .strip_prefix("[app=")
        .and_then(|fields| fields.strip_suffix(']'))
        .and_then(|fields| fields.split_once(" | title="))
    else {
        return (None, None);
    };
    let Some((title, after_url)) = after_title.rsplit_once(" | url=") else {
        return (None, None);
    };
    let url = after_url
        .split(" | ")
        .next()
        .filter(|url| !url.is_empty() && *url != "?");
    let title = Some(title.trim()).filter(|title| !title.is_empty());
    (title, url)
}

/// The window a stored text was read from: its app, the title the caller
/// gives or else the header's, and the header's address.
fn window_of<'a>(stored: &'a str, app: Option<&'a str>, title: Option<&'a str>) -> Window<'a> {
    let (header_title, url) = header_fields(stored);
    Window {
        app,
        title: title.or(header_title),
        url,
    }
}

/// The byte length, newline included, of a header whose title holds a line
/// break: its first line opens it with the app and the title, and a later
/// line closes it with ` | url=` and `]`.
fn wrapped_header_len(text: &str) -> Option<usize> {
    let (first, _) = text.split_once('\n')?;
    if !first.starts_with("[app=") || !first.contains(" | title=") {
        return None;
    }
    let window = &text[..floor_char_boundary(text, WRAPPED_HEADER_BYTES)];
    let mut at = first.len() + 1;
    while let Some(len) = window[at..].find('\n') {
        let line = &window[at..at + len];
        if line.ends_with(']') && line.contains(" | url=") {
            return Some(at + len + 1);
        }
        at += len + 1;
    }
    None
}

/// Everything stored, for an audit: the text without its header line, the
/// separator between a window's content and its chrome as a blank line, and
/// any other U+001E as a space. No stored word is left out and nothing is
/// cleaned.
#[must_use]
pub fn audit_text(stored: &str) -> String {
    let text = body(stored);
    if !text.contains('\u{1E}') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    for (index, piece) in text.split(CHROME_SEPARATOR).enumerate() {
        if index > 0 {
            out.push_str("\n\n");
        }
        if piece.contains('\u{1E}') {
            out.push_str(&piece.replace('\u{1E}', " "));
        } else {
            out.push_str(piece);
        }
    }
    out
}

/// The reading of one stored event.
///
/// `app` is the event's bundle id. `title` is the window's title; without
/// one, the stored header's is used, as is its page address.
#[must_use]
pub fn reading(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    title: Option<&str>,
) -> Reading {
    reading_with(stored, source, app, title, None)
}

/// [`reading`], with the chrome lines the re-clean job learned from the
/// moments around this one ([`RepeatedChrome`]) set apart too.
#[must_use]
pub fn reading_with(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    title: Option<&str>,
    learned: Option<&RepeatedChrome>,
) -> Reading {
    let text = body(stored);
    let window = window_of(stored, app, title);
    match source {
        EventSource::ScreenOcr | EventSource::ScreenContext => read_screen(text, &window, learned),
        EventSource::BrowserPageWithOcr => match text.split_once(VISIBLE_OCR_SEPARATOR) {
            Some((page, seen)) => apart(Reading {
                main: shown(page).into_owned(),
                rest: joined(&read_screen(seen, &window, learned)),
            }),
            None => as_stored(text),
        },
        _ => as_stored(text),
    }
}

/// What was on the screen: for a browser page read both ways, the reading of
/// the part read off the screen; otherwise [`reading`].
#[must_use]
pub fn screen_reading(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    title: Option<&str>,
) -> Reading {
    if source == EventSource::BrowserPageWithOcr {
        if let Some((_, seen)) = body(stored).split_once(VISIBLE_OCR_SEPARATOR) {
            return read_screen(seen, &window_of(stored, app, title), None);
        }
    }
    reading(stored, source, app, title)
}

/// The first `max_chars` characters of the event's `main`, or of its `rest`
/// when `main` is empty, for a list row.
///
/// The same text as `reading(…).main` cut to `max_chars`, but it cleans only
/// the blocks it shows. It takes `app` because a terminal's blocks are kept
/// as they were read.
#[must_use]
pub fn reading_prefix(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    max_chars: usize,
) -> String {
    if max_chars == 0 {
        return String::new();
    }
    let text = body(stored);
    match source {
        EventSource::ScreenOcr | EventSource::ScreenContext => {
            let (content, chrome, classified) = split_chrome(text);
            let window = window_of(stored, app, None);
            let rules = Rules::new(text, classified, &window);
            let set_aside = old_chrome_apart(content, classified, &window);
            let (content, chrome) = parts_after(content, chrome, set_aside.as_ref());
            let main = part_prefix(content, &rules, is_terminal(app), max_chars);
            if main.is_empty() {
                part_prefix(chrome, &rules, false, max_chars)
            } else {
                main
            }
        }
        EventSource::BrowserPageWithOcr => {
            // The page's own text comes first. Look for the marker only as
            // far as `max_chars` characters can reach.
            let reach = floor_char_boundary(
                text,
                max_chars
                    .saturating_mul(4)
                    .saturating_add(VISIBLE_OCR_SEPARATOR.len()),
            );
            let page = text[..reach]
                .find(VISIBLE_OCR_SEPARATOR)
                .map_or(text, |at| &text[..at]);
            let page = shown(page);
            if page.is_empty() && text.contains(VISIBLE_OCR_SEPARATOR) {
                let rest = reading(stored, source, app, None).rest;
                return first_chars(&rest, max_chars).to_owned();
            }
            first_chars(&page, max_chars).to_owned()
        }
        _ => first_chars(&shown(text), max_chars).to_owned(),
    }
}

/// The first `max_chars` characters of a reading's `main`, or of its `rest`
/// when `main` is empty: what [`reading_prefix`] gives for stored text, made
/// from a reading already cleaned (a stored one). A cut never makes a secret
/// pattern appear: when it would, the words it split are left out.
#[must_use]
pub fn reading_start(read: &Reading, max_chars: usize) -> String {
    let part = if read.main.is_empty() {
        &read.rest
    } else {
        &read.main
    };
    cut_clean(part, 0, first_chars(part, max_chars).len())
}

/// The words of a search, to find in a passage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExcerptQuery {
    words: HashSet<String>,
    /// Bit `n` is set when an ASCII word is `n` bytes long (the last bit
    /// stands for every length from 127 up), so most words of a text are
    /// passed over without lower-casing them.
    ascii_lengths: u128,
}

impl ExcerptQuery {
    /// The words of one search as typed.
    #[must_use]
    pub fn new(text: &str) -> Self {
        Self::from_alternatives(&[LexicalAlternative::Keywords(text)])
    }

    /// The words of every spelling a search tried, as the store matched them.
    /// Words such as "the" and "what" count only when there is no other.
    #[must_use]
    pub fn from_alternatives(alternatives: &[LexicalAlternative<'_>]) -> Self {
        let mut all = HashSet::new();
        for alternative in alternatives {
            let (LexicalAlternative::Keywords(text) | LexicalAlternative::Phrase(text)) =
                alternative;
            let literal = sanitize_fts5_query(text);
            all.extend(
                literal
                    .split(|ch: char| !ch.is_alphanumeric())
                    .filter(|word| !word.is_empty())
                    .map(str::to_lowercase),
            );
        }
        let telling: HashSet<String> = all
            .iter()
            .filter(|word| !STOP_WORDS.contains(&word.as_str()))
            .cloned()
            .collect();
        let words = if telling.is_empty() { all } else { telling };
        let ascii_lengths = words
            .iter()
            .filter(|word| word.is_ascii())
            .fold(0u128, |bits, word| bits | length_bit(word.len()));
        Self {
            words,
            ascii_lengths,
        }
    }

    /// True when there is no word to look for.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    /// Whether `text` holds one of the words.
    #[must_use]
    pub fn found_in(&self, text: &str) -> bool {
        !self.words.is_empty() && self.closest_words(text, usize::MAX).is_some()
    }

    /// The query's spelling of `word`, when it is one of the words.
    fn term(&self, word: &str) -> Option<&str> {
        if word.is_ascii() {
            if self.ascii_lengths & length_bit(word.len()) == 0 {
                return None;
            }
            self.words
                .get(word.to_ascii_lowercase().as_str())
                .map(String::as_str)
        } else {
            self.words
                .get(word.to_lowercase().as_str())
                .map(String::as_str)
        }
    }

    /// Byte range from the first to the end of the last word of the span
    /// that holds the most different words within `max_bytes`, shortest
    /// first. Literal words only: the store's stemming is not repeated.
    fn closest_words(&self, text: &str, max_bytes: usize) -> Option<(usize, usize)> {
        if self.words.is_empty() {
            return None;
        }
        let mut window: VecDeque<(usize, &str)> = VecDeque::new();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut best: Option<(usize, usize, usize)> = None; // (distinct words, first, end)
        for (start, word) in words(text) {
            let Some(term) = self.term(word) else {
                continue;
            };
            let end = start + word.len().min(max_bytes);
            window.push_back((start, term));
            *counts.entry(term).or_default() += 1;
            while let Some(&(first, front)) = window.front() {
                if end - first <= max_bytes && counts[front] == 1 {
                    break;
                }
                window.pop_front();
                let count = counts
                    .get_mut(front)
                    .expect("a word in the window is counted");
                *count -= 1;
                if *count == 0 {
                    counts.remove(front);
                }
            }
            let first = window.front().expect("the newest word fits the window").0;
            let distinct = counts.len();
            let better = best.is_none_or(|(most, from, to)| {
                distinct > most || (distinct == most && end - first < to - from)
            });
            if better {
                best = Some((distinct, first, end));
            }
        }
        best.map(|(_, first, end)| (first, end))
    }
}

/// The words of `text`, runs of letters and digits, with their byte offsets.
/// ASCII is read byte by byte; other characters are decoded.
fn words(text: &str) -> impl Iterator<Item = (usize, &str)> + '_ {
    let bytes = text.as_bytes();
    // Whether the character at `at` is a letter or digit, and its length.
    let char_at = move |at: usize| -> (bool, usize) {
        let byte = bytes[at];
        if byte < 0x80 {
            return (byte.is_ascii_alphanumeric(), 1);
        }
        text[at..]
            .chars()
            .next()
            .map_or((false, 1), |ch| (ch.is_alphanumeric(), ch.len_utf8()))
    };
    let mut at = 0;
    std::iter::from_fn(move || {
        loop {
            if at >= bytes.len() {
                return None;
            }
            let (word, len) = char_at(at);
            if word {
                break;
            }
            at += len;
        }
        let start = at;
        while at < bytes.len() {
            let (word, len) = char_at(at);
            if !word {
                break;
            }
            at += len;
        }
        Some((start, &text[start..at]))
    })
}

/// The bit [`ExcerptQuery`] keeps for a word `len` bytes long.
fn length_bit(len: usize) -> u128 {
    1u128 << len.min(127)
}

/// A passage of a reading of at most `max_bytes`, verbatim.
///
/// With a query: on the line of the closest group of its words, with a little
/// of what comes before them, from `main` when the words are there and from
/// `rest` otherwise. Otherwise, or when no word is found: the last whole
/// lines of `main` for a terminal or chat app, the first whole lines of
/// `main` for any other (a first line longer than that is cut between
/// words); `rest` when `main` is empty. A cut never makes a secret pattern
/// appear.
#[must_use]
pub fn excerpt(
    text: &Reading,
    app: Option<&str>,
    query: &ExcerptQuery,
    max_bytes: usize,
) -> String {
    if max_bytes == 0 {
        return String::new();
    }
    if !query.is_empty() {
        for part in [text.main.as_str(), text.rest.as_str()] {
            if let Some(found) = query.closest_words(part, max_bytes) {
                let (start, stop) = around(part, found, max_bytes);
                return cut_clean(part, start, stop);
            }
        }
    }
    let part = if text.main.trim().is_empty() {
        text.rest.as_str()
    } else {
        text.main.as_str()
    };
    let (start, stop) = if newest_last(app) {
        last_lines(part, max_bytes)
    } else {
        first_lines(part, max_bytes)
    };
    cut_clean(part, start, stop)
}

/// The passage [`excerpt`] makes of `reading(stored, source, app, None)`,
/// made from the stored text by cleaning only the blocks it needs: for a
/// search, the blocks from the one where its words are; otherwise the first
/// blocks, or the last for a terminal or chat app. For lists and search
/// results, where reading every window whole would cost too much.
///
/// Without a search it is the excerpt's passage. With one, the words are
/// looked for in the stored text first, so when they come more than once the
/// passage may stand around a different group of them; it is still verbatim
/// in the reading. Only what it shows is checked for secret patterns; when
/// that holds one, the window is read whole.
#[must_use]
pub fn passage(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    query: &ExcerptQuery,
    max_bytes: usize,
) -> String {
    if max_bytes == 0 {
        return String::new();
    }
    let text = body(stored);
    match source {
        EventSource::ScreenOcr | EventSource::ScreenContext => {
            screen_passage(text, &window_of(stored, app, None), query, max_bytes)
        }
        EventSource::BrowserPageWithOcr => match text.split_once(VISIBLE_OCR_SEPARATOR) {
            Some((page, seen)) => {
                // The page is shown as stored. The part read off the screen
                // is read only when the page is empty or lacks the words it
                // holds.
                let main = shown(page);
                if main.trim().is_empty() || (!query.found_in(&main) && query.found_in(seen)) {
                    return excerpt(&reading(stored, source, app, None), app, query, max_bytes);
                }
                let page_only = Reading {
                    main: main.into_owned(),
                    rest: String::new(),
                };
                excerpt(&page_only, app, query, max_bytes)
            }
            None => excerpt(&as_stored(text), app, query, max_bytes),
        },
        _ => excerpt(&as_stored(text), app, query, max_bytes),
    }
}

// ---------------------------------------------------------------------------
// Screen text
// ---------------------------------------------------------------------------

/// What the rules know about one screen text.
struct Rules<'t> {
    /// The whole screen text, content and chrome, for N1's count of letters.
    text: &'t str,
    cjk_rare: OnceCell<bool>,
    /// The text carries the separator: paragraphs join, indents are set.
    classified: bool,
    /// How wrapped lines join in this window.
    join: Join,
    /// The first part of the window's title: a line that repeats it is a
    /// heading, never the end of the line before it.
    lead: Option<String>,
}

/// How wrapped lines join, by the kind of window (SPEC 4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Join {
    /// Never: terminals, spreadsheets, and code editors' older text.
    Never,
    /// J1 only: what a code editor's classified text holds besides code (an
    /// assistant's panel).
    Wrapped,
    /// J1, and only for a line that fills the line: chats with people, so
    /// two messages never merge.
    Filled,
    /// J1 to J4: pages, documents, notes, PDFs, mail and AI chats.
    Prose,
}

impl<'t> Rules<'t> {
    fn new(text: &'t str, classified: bool, window: &Window<'_>) -> Self {
        let join = match reading_blocks::kind_of(window.app, window.title, window.url) {
            Kind::Editor if classified => Join::Wrapped,
            Kind::Terminal | Kind::Sheet | Kind::Editor => Join::Never,
            Kind::People => Join::Filled,
            Kind::Document | Kind::Mail | Kind::AiChat => Join::Prose,
        };
        Self {
            text,
            cjk_rare: OnceCell::new(),
            classified,
            join,
            lead: window
                .title
                .and_then(|title| reading_blocks::title_lead(title, window.app))
                .map(str::to_owned),
        }
    }

    #[cfg(test)]
    fn for_app(text: &'t str, classified: bool, app: Option<&str>) -> Self {
        Self::new(
            text,
            classified,
            &Window {
                app,
                title: None,
                url: None,
            },
        )
    }

    /// Older text whose wrapped lines join; its indents stay as read.
    fn joins_older(&self) -> bool {
        !self.classified && self.join != Join::Never
    }

    /// Under 10% of the text's letters are CJK, so N1 applies. Counted only
    /// when a lone CJK character turns up.
    fn cjk_rare(&self) -> bool {
        *self.cjk_rare.get_or_init(|| cjk_is_rare(self.text))
    }
}

fn is_terminal(app: Option<&str>) -> bool {
    app.is_some_and(|app| TERMINAL_APPS.contains(&app))
}

/// A terminal or chat app: the newest text is at the bottom.
fn newest_last(app: Option<&str>) -> bool {
    app.is_some_and(|app| TERMINAL_APPS.contains(&app) || CHAT_APPS.contains(&app))
}

fn read_screen(text: &str, window: &Window<'_>, learned: Option<&RepeatedChrome>) -> Reading {
    let app = window.app;
    let (content, chrome, classified) = split_chrome(text);
    let rules = Rules::new(text, classified, window);
    let set_aside = if classified {
        None
    } else {
        chrome_apart(content, window, learned)
    };
    let (kept, moved) = parts_after(content, chrome, set_aside.as_ref());
    // A terminal's own text is kept as read; its tabs and title are not
    // terminal output.
    let cleaned = Reading {
        main: clean(kept, &rules, is_terminal(app)),
        rest: clean(moved, &rules, false),
    };
    if contains_secret(&cleaned.main) || contains_secret(&cleaned.rest) {
        // Cleaning or moving chrome made a pattern appear, or the stored text
        // holds one: show the stored parts with no other cleaning.
        return apart(Reading {
            main: shown(content).into_owned(),
            rest: shown(chrome).into_owned(),
        });
    }
    apart(cleaned)
}

/// The lines [`chrome::set_apart`] sets apart in older (unclassified) text,
/// with no lines learned from many frames: the list rows' and passages'
/// reading. A classified window's content stays whole.
fn old_chrome_apart<'t>(
    content: &'t str,
    classified: bool,
    window: &Window<'_>,
) -> Option<Apart<'t>> {
    if classified {
        None
    } else {
        chrome_apart(content, window, None)
    }
}

/// The lines [`chrome::set_apart`] sets apart, unless moving them puts
/// together a secret pattern that the stored text keeps apart (a key on one
/// side of a removed line, its value on the other): then nothing moves.
/// Checked only when a line moves, and only where it makes a difference:
/// what moved, and the text around each place where two kept pieces now
/// meet. What stays is otherwise the content's own text in order.
fn chrome_apart<'t>(
    content: &'t str,
    window: &Window<'_>,
    learned: Option<&RepeatedChrome>,
) -> Option<Apart<'t>> {
    chrome::set_apart(content, window, learned).filter(|found| {
        !contains_secret(&found.moved)
            && !found
                .holes
                .iter()
                .any(|&hole| secret_where_pieces_meet(&found.kept, hole))
    })
}

/// Whether the text around byte `at` of `text` holds a secret pattern that
/// neither side of `at` holds alone: one that the two pieces meeting there
/// made. Every pattern spans far less than [`MEET_REACH`] bytes.
fn secret_where_pieces_meet(text: &str, at: usize) -> bool {
    let start = ceil_char_boundary(text, at.saturating_sub(MEET_REACH));
    let end = floor_char_boundary(text, at.saturating_add(MEET_REACH));
    let at = floor_char_boundary(text, at);
    contains_secret(&text[start..end])
        && !contains_secret(&text[start..at])
        && !contains_secret(&text[at..end])
}

/// How far around a place where two kept pieces meet the secret check reads.
const MEET_REACH: usize = 512;

/// The content and the chrome once [`chrome_apart`] has run on older text,
/// which carries no chrome the helper set apart: the content without the
/// lines it set apart, and those lines.
fn parts_after<'t>(
    content: &'t str,
    chrome: &'t str,
    set_aside: Option<&'t Apart<'t>>,
) -> (&'t str, &'t str) {
    match set_aside {
        None => (content, chrome),
        Some(found) => (&found.kept, &found.moved),
    }
}

/// The content before the separator, the chrome after it, and whether the
/// text carries it at all.
fn split_chrome(text: &str) -> (&str, &str, bool) {
    let bytes = text.as_bytes();
    let mut from = 0;
    while let Some(found) = text[from..].find('\u{1E}') {
        let at = from + found;
        if at >= 2 && &bytes[at - 2..at] == b"\n\n" && bytes.get(at + 1) == Some(&b'\n') {
            return (&text[..at - 2], &text[at + 2..], true);
        }
        from = at + 1;
    }
    (text, "", false)
}

/// `main` and `rest` as they are shown one after the other, with a blank
/// line between them.
fn joined(reading: &Reading) -> String {
    match (reading.main.is_empty(), reading.rest.is_empty()) {
        (_, true) => reading.main.clone(),
        (true, false) => reading.rest.clone(),
        (false, false) => format!("{}\n\n{}", reading.main, reading.rest),
    }
}

/// `reading`, unless `main` and `rest` shown one after the other would make a
/// secret pattern appear that neither holds alone: then the words beside the
/// boundary are left out, one from each side at a time, until none does.
fn apart(mut reading: Reading) -> Reading {
    if reading.main.is_empty()
        || reading.rest.is_empty()
        || contains_secret(&reading.main)
        || contains_secret(&reading.rest)
    {
        return reading;
    }
    while !reading.main.is_empty() && !reading.rest.is_empty() && contains_secret(&joined(&reading))
    {
        reading.main = without_last_word(&reading.main).to_owned();
        reading.rest = without_first_word(&reading.rest).to_owned();
    }
    reading
}

/// `left`, `glue` and `right` in a row, unless that makes a secret pattern
/// appear that neither side holds: then the words beside the join are left
/// out, one from each side at a time, until it does not.
fn join_apart(left: &str, glue: &str, right: &str) -> String {
    let whole = format!("{left}{glue}{right}");
    if !contains_secret(&whole) || contains_secret(left) || contains_secret(right) {
        return whole;
    }
    let (mut left, mut right) = (left, right);
    loop {
        left = without_last_word(left);
        right = without_first_word(right);
        if left.is_empty() || right.is_empty() {
            return format!("{left}{right}");
        }
        let whole = format!("{left}{glue}{right}");
        if !contains_secret(&whole) {
            return whole;
        }
    }
}

/// `text` without its last whitespace-delimited word and the whitespace
/// around it.
fn without_last_word(text: &str) -> &str {
    let text = text.trim_end();
    text.rfind(char::is_whitespace)
        .map_or("", |at| text[..at].trim_end())
}

/// `text` without its first whitespace-delimited word and the whitespace
/// around it.
fn without_first_word(text: &str) -> &str {
    let text = text.trim_start();
    text.find(char::is_whitespace)
        .map_or("", |at| text[at..].trim_start())
}

/// Stored text as it may be shown: no U+001E. A stray one, not part of the
/// separator, reads as a space, unless that would make a secret pattern
/// appear: then the words on either side of it are left out.
fn shown(text: &str) -> Cow<'_, str> {
    if !text.contains('\u{1E}') {
        return Cow::Borrowed(text);
    }
    let spaced = text.replace('\u{1E}', " ");
    if !contains_secret(&spaced) || contains_secret(text) {
        return Cow::Owned(spaced);
    }
    let mut pieces = text.split('\u{1E}');
    let mut out = pieces.next().unwrap_or_default().to_owned();
    for piece in pieces {
        out = join_apart(&out, " ", piece);
    }
    Cow::Owned(out)
}

fn as_stored(text: &str) -> Reading {
    Reading {
        main: shown(text).into_owned(),
        rest: String::new(),
    }
}

fn clean(text: &str, rules: &Rules<'_>, terminal: bool) -> String {
    clean_blocks(&shown(text), rules, terminal, usize::MAX)
}

/// The start of one part's reading, `max_chars` characters long, cleaning
/// only the blocks it shows.
fn part_prefix(part: &str, rules: &Rules<'_>, terminal: bool, max_chars: usize) -> String {
    let part = shown(part);
    let cleaned = clean_blocks(&part, rules, terminal, max_chars);
    let cut = first_chars(&cleaned, max_chars);
    if !contains_secret(cut) {
        return cut.to_owned();
    }
    // Cleaning or the cut made a secret pattern appear: show the stored start.
    cut_clean(&part, 0, first_chars(&part, max_chars).len())
}

/// A block's byte range in its text: from the start of its first line to the
/// end of its last.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Span {
    start: usize,
    end: usize,
}

/// The blocks of a text, in order: runs of lines that are not blank.
struct Blocks<'t> {
    text: &'t str,
    at: usize,
}

impl<'t> Blocks<'t> {
    fn new(text: &'t str) -> Self {
        Self { text, at: 0 }
    }

    /// The blocks from the line that starts at byte `at` on.
    fn from(text: &'t str, at: usize) -> Self {
        Self { text, at }
    }
}

/// The blocks of a text from its end back to its start.
struct BlocksBack<'t> {
    text: &'t str,
    /// The end of the next line to look at; none when the start is passed.
    at: Option<usize>,
}

impl<'t> BlocksBack<'t> {
    fn new(text: &'t str) -> Self {
        Self {
            text,
            at: Some(text.len()),
        }
    }
}

impl Iterator for BlocksBack<'_> {
    type Item = Span;

    fn next(&mut self) -> Option<Span> {
        let text = self.text;
        let mut found: Option<Span> = None;
        while let Some(end) = self.at {
            let start = text[..end].rfind('\n').map_or(0, |at| at + 1);
            self.at = start.checked_sub(1);
            if text[start..end].trim().is_empty() {
                if found.is_some() {
                    return found;
                }
            } else {
                match found.as_mut() {
                    Some(span) => span.start = start,
                    None => found = Some(Span { start, end }),
                }
            }
        }
        found
    }
}

/// The start of the block that holds byte `at` of `text`, which is on a line
/// that is not blank: the first line after the blank line before it.
fn block_start(text: &str, at: usize) -> usize {
    let mut start = text[..at].rfind('\n').map_or(0, |found| found + 1);
    while start > 0 {
        let before = text[..start - 1].rfind('\n').map_or(0, |found| found + 1);
        if text[before..start - 1].trim().is_empty() {
            break;
        }
        start = before;
    }
    start
}

impl Iterator for Blocks<'_> {
    type Item = Span;

    fn next(&mut self) -> Option<Span> {
        let text = self.text;
        let mut found: Option<Span> = None;
        while self.at <= text.len() {
            let start = self.at;
            let end = text[start..].find('\n').map_or(text.len(), |at| start + at);
            self.at = end + 1;
            if text[start..end].trim().is_empty() {
                if found.is_some() {
                    return found;
                }
            } else {
                match found.as_mut() {
                    Some(span) => span.end = end,
                    None => found = Some(Span { start, end }),
                }
            }
        }
        found
    }
}

fn block_lines(text: &str, span: Span) -> Vec<&str> {
    text[span.start..span.end].split('\n').collect()
}

/// The cleaned text of `text`, block by block, until `budget` characters
/// stand before its trailing whitespace (`usize::MAX` for all of it). A
/// block that keeps no text goes with the blank lines before it; blank lines
/// at the start and end go.
fn clean_blocks(text: &str, rules: &Rules<'_>, terminal: bool, budget: usize) -> String {
    let mut out = String::new();
    let mut total = 0usize;
    let mut shown_chars = 0usize;
    let mut previous_end: Option<usize> = None;
    for span in Blocks::new(text) {
        if !out.is_empty() && shown_chars >= budget {
            break;
        }
        let gap = previous_end.map_or("", |end| &text[end..span.start]);
        previous_end = Some(span.end);
        let gap_chars = if out.is_empty() {
            0
        } else {
            gap.chars().count()
        };
        let room = budget.saturating_sub(total + gap_chars).max(1);
        let cleaned = clean_block(&block_lines(text, span), rules, terminal, room);
        if cleaned.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push_str(gap);
            total += gap_chars;
        }
        let chars = cleaned.chars().count();
        shown_chars = total + chars - trailing_whitespace(&cleaned);
        total += chars;
        out.push_str(&cleaned);
    }
    out
}

/// The cleaned text of the last blocks of `text`: the end of
/// `clean_blocks(text, …)`, long enough that more than `min_bytes` bytes of
/// it stand before its trailing whitespace, or all of it. It reads the text
/// from its end.
fn clean_tail(text: &str, rules: &Rules<'_>, terminal: bool, min_bytes: usize) -> String {
    // From the end: a cleaned block, the text before it, a cleaned block, …
    let mut pieces: Vec<Cow<'_, str>> = Vec::new();
    let mut length = 0usize;
    let mut trailing = 0usize;
    // The earliest block kept so far, and the text between it and the block
    // before it, which stands before it once an earlier block is kept.
    let mut head: Option<Span> = None;
    let mut head_gap = "";
    let mut later: Option<Span> = None;
    for span in BlocksBack::new(text) {
        if later.is_some() && later == head {
            head_gap = &text[span.end..later.map_or(span.end, |next| next.start)];
        }
        later = Some(span);
        let cleaned = clean_block(&block_lines(text, span), rules, terminal, usize::MAX);
        if cleaned.is_empty() {
            continue;
        }
        if head.is_some() {
            pieces.push(Cow::Borrowed(head_gap));
            length += head_gap.len();
        } else {
            trailing = cleaned.len() - cleaned.trim_end().len();
        }
        length += cleaned.len();
        pieces.push(Cow::Owned(cleaned));
        head = Some(span);
        if length - trailing > min_bytes {
            break;
        }
    }
    pieces.reverse();
    pieces.concat()
}

/// The passage of one part's cleaned text around the closest group of the
/// query's words, cleaning only the blocks from the one where the group
/// starts in the stored text. None when the words are not there.
fn query_passage(
    part: &str,
    rules: &Rules<'_>,
    terminal: bool,
    query: &ExcerptQuery,
    max_bytes: usize,
) -> Option<String> {
    let (first, _) = query.closest_words(part, max_bytes)?;
    let mut region = String::new();
    let mut previous_end: Option<usize> = None;
    for span in Blocks::from(part, block_start(part, first)) {
        let gap = previous_end.map_or("", |end| &part[end..span.start]);
        previous_end = Some(span.end);
        let cleaned = clean_block(&block_lines(part, span), rules, terminal, usize::MAX);
        if cleaned.is_empty() {
            continue;
        }
        if !region.is_empty() {
            region.push_str(gap);
        }
        region.push_str(&cleaned);
        if let Some((at, _)) = query.closest_words(&region, max_bytes) {
            if region.len() >= at.saturating_add(max_bytes) {
                break;
            }
        }
    }
    let found = query.closest_words(&region, max_bytes)?;
    let (start, stop) = around(&region, found, max_bytes);
    Some(cut_clean(&region, start, stop))
}

/// [`passage`] for screen text.
fn screen_passage(
    text: &str,
    window: &Window<'_>,
    query: &ExcerptQuery,
    max_bytes: usize,
) -> String {
    let app = window.app;
    let (content, chrome, classified) = split_chrome(text);
    let rules = Rules::new(text, classified, window);
    let set_aside = old_chrome_apart(content, classified, window);
    let (content, chrome) = parts_after(content, chrome, set_aside.as_ref());
    let content = shown(content);
    let chrome = shown(chrome);
    let parts = [(&*content, is_terminal(app)), (&*chrome, false)];
    let mut found = None;
    if !query.is_empty() {
        found = parts
            .iter()
            .find_map(|&(part, terminal)| query_passage(part, &rules, terminal, query, max_bytes));
    }
    let piece = found.unwrap_or_else(|| {
        for &(part, terminal) in &parts {
            if newest_last(app) {
                let tail = clean_tail(part, &rules, terminal, max_bytes);
                if !tail.is_empty() {
                    let (start, stop) = last_lines(&tail, max_bytes);
                    return cut_clean(&tail, start, stop);
                }
            } else {
                // Enough characters that the first lines are the same as in
                // the whole reading: more than `max_bytes` after any blank
                // lines it opens with.
                let budget = max_bytes.saturating_add(1);
                let mut head = clean_blocks(part, &rules, terminal, budget);
                let opening = head.len() - head.trim_start_matches('\n').len();
                if opening > 0 {
                    head = clean_blocks(part, &rules, terminal, budget.saturating_add(opening));
                }
                if !head.is_empty() {
                    let (start, stop) = first_lines(&head, max_bytes);
                    return cut_clean(&head, start, stop);
                }
            }
        }
        String::new()
    });
    if contains_secret(&piece) {
        // Cleaned on its own, the passage holds a pattern: read the window
        // whole, which knows what the stored text holds.
        return excerpt(&read_screen(text, window, None), app, query, max_bytes);
    }
    piece
}

/// Characters of whitespace at the end of `text`.
fn trailing_whitespace(text: &str) -> usize {
    text.chars()
        .rev()
        .take_while(|ch| ch.is_whitespace())
        .count()
}

fn clean_block(lines: &[&str], rules: &Rules<'_>, terminal: bool, budget: usize) -> String {
    if terminal || is_preformatted(lines) {
        // Junk tokens go; every line keeps its place.
        return joined_lines(lines.iter().map(|line| without_junk(line, rules)), budget);
    }
    if rules.joins_older() {
        return joined_paragraphs(lines, rules, budget);
    }
    let kept = lines
        .iter()
        .map(|line| without_junk(line, rules))
        .filter(|line| holds_text(line));
    if rules.classified {
        shaped(&kept.collect::<Vec<_>>(), rules)
    } else {
        joined_lines(kept, budget)
    }
}

/// Older text of a browser, a document or a chat: its lines without junk,
/// wrapped lines joined into paragraphs by the rules for its kind of window
/// ([`Wrap::glue`]), indents as read, until `budget` characters stand before
/// the trailing whitespace. The longest line is measured as read.
fn joined_paragraphs(lines: &[&str], rules: &Rules<'_>, budget: usize) -> String {
    let wrap = Wrap::of(lines.iter().copied(), rules);
    let mut kept: Vec<Cow<'_, str>> = Vec::new();
    let mut source = lines
        .iter()
        .map(|line| without_junk(line, rules))
        .filter(|line| holds_text(line));
    let mut guarded = false;
    loop {
        let mut out = String::new();
        let mut at = 0usize;
        loop {
            // Each join looks at the line after the next one.
            while kept.len() < at + 3 {
                match source.next() {
                    Some(line) => kept.push(line),
                    None => break,
                }
            }
            let Some(line) = kept.get(at) else {
                break;
            };
            let glue = at.checked_sub(1).and_then(|before| {
                wrap.glue(&kept[before], line, kept.get(at + 1).map(AsRef::as_ref))
            });
            push_line(&mut out, line, glue, guarded);
            at += 1;
            if budget != usize::MAX && out.trim_end().chars().count() >= budget {
                break;
            }
        }
        if guarded || !made_a_secret(&out, &kept[..at.min(kept.len())]) {
            return out;
        }
        // A join made a secret pattern appear: join again, keeping apart
        // any two lines whose join would.
        guarded = true;
    }
}

/// Appends `line` to `out`: after a line break, or joined to the line before
/// it with `glue`. With `guarded`, two lines whose join would make a secret
/// pattern appear that neither holds stay apart.
fn push_line(out: &mut String, line: &str, glue: Option<Glue>, guarded: bool) {
    if let Some(glue) = glue {
        let left = out.trim_end().len();
        let right = line.trim_start();
        let space = if glue == Glue::Space { " " } else { "" };
        if !guarded || !join_makes_secret(&out[..left], space, right) {
            out.truncate(left);
            out.push_str(space);
            out.push_str(right);
            return;
        }
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(line);
}

/// Whether `joined` holds a secret pattern its lines, kept apart, do not.
fn made_a_secret(joined: &str, lines: &[Cow<'_, str>]) -> bool {
    contains_secret(joined)
        && !contains_secret(
            &lines
                .iter()
                .map(AsRef::as_ref)
                .collect::<Vec<&str>>()
                .join("\n"),
        )
}

/// Whether putting `right` after `left` with `glue` makes a secret pattern
/// appear that neither side holds, looking [`MEET_REACH`] bytes each way.
fn join_makes_secret(left: &str, glue: &str, right: &str) -> bool {
    let left = &left[ceil_char_boundary(left, left.len().saturating_sub(MEET_REACH))..];
    let right = &right[..floor_char_boundary(right, MEET_REACH)];
    contains_secret(&format!("{left}{glue}{right}"))
        && !contains_secret(left)
        && !contains_secret(right)
}

/// Whether a line outside preformatted text stays (N3): it holds a letter
/// or a digit, or it is code's brackets ("}", "});") or a signature's "--".
fn holds_text(line: &str) -> bool {
    let has_word = if line.is_ascii() {
        line.bytes().any(|byte| byte.is_ascii_alphanumeric())
    } else {
        line.chars().any(char::is_alphanumeric)
    };
    if has_word {
        return true;
    }
    let text = line.trim();
    text == "--"
        || (!text.is_empty()
            && text
                .chars()
                .all(|ch| matches!(ch, '{' | '}' | '(' | ')' | '[' | ']' | ';' | ',')))
}

/// `lines` joined by line breaks, stopping once `budget` characters stand
/// before the trailing whitespace. Empty when no line holds text.
fn joined_lines<'l>(lines: impl Iterator<Item = Cow<'l, str>>, budget: usize) -> String {
    let mut out = String::new();
    let mut total = 0usize;
    let mut has_text = false;
    for (index, line) in lines.enumerate() {
        if index > 0 {
            out.push('\n');
            total += 1;
        }
        out.push_str(&line);
        total += line.chars().count();
        if line.chars().any(|ch| !ch.is_whitespace()) {
            has_text = true;
            if total - trailing_whitespace(&line) >= budget {
                break;
            }
        }
    }
    if has_text {
        out
    } else {
        String::new()
    }
}

/// Classified text: wrapped lines joined into paragraphs by the rules for
/// its kind of window, then every indent set to none or four spaces.
fn shaped(lines: &[Cow<'_, str>], rules: &Rules<'_>) -> String {
    let wrap = Wrap::of(lines.iter().map(AsRef::as_ref), rules);
    let mut guarded = false;
    loop {
        let mut out: Vec<String> = Vec::with_capacity(lines.len());
        for (at, line) in lines.iter().enumerate() {
            let line: &str = line;
            let glue = at.checked_sub(1).and_then(|before| {
                wrap.glue(&lines[before], line, lines.get(at + 1).map(AsRef::as_ref))
            });
            if let (Some(glue), Some(last)) = (glue, out.last_mut()) {
                let space = if glue == Glue::Space { " " } else { "" };
                let left = last.trim_end().len();
                if !guarded || !join_makes_secret(&last[..left], space, line.trim_start()) {
                    last.truncate(left);
                    last.push_str(space);
                    last.push_str(line.trim_start());
                    continue;
                }
            }
            out.push(line.to_owned());
        }
        let text = out
            .iter()
            .map(|line| {
                if indent(line).is_empty() {
                    Cow::Borrowed(line.as_str())
                } else {
                    Cow::Owned(format!("    {}", line.trim_start()))
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        if guarded || !made_a_secret(&text, lines) {
            return text;
        }
        guarded = true;
    }
}

/// How two lines meet when the second continues the first: with a space,
/// or with nothing (a hyphenated word, "well-" and "known"; two CJK, kana or
/// hangul characters).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Glue {
    Space,
    Tight,
}

/// What the joining rules know of one block of lines, as read.
struct Wrap<'r> {
    join: Join,
    /// The longest line, in characters (J1).
    longest: usize,
    /// The widest line, a CJK character counting as two (J3, J4).
    widest: usize,
    /// How many lines hold text.
    lines: usize,
    /// How many lines reach the wrap edge (nine tenths of the widest): a
    /// wrap edge is one only where two lines or more reach it.
    at_edge: usize,
    /// The first part of the window's title.
    lead: Option<&'r str>,
}

impl<'r> Wrap<'r> {
    fn of<'l>(lines: impl Iterator<Item = &'l str>, rules: &'r Rules<'_>) -> Self {
        let mut wrap = Self {
            join: rules.join,
            longest: 0,
            widest: 0,
            lines: 0,
            at_edge: 0,
            lead: rules.lead.as_deref(),
        };
        let mut widths: Vec<usize> = Vec::new();
        for line in lines {
            let line = line.trim_end();
            if !holds_text(line) {
                continue;
            }
            wrap.lines += 1;
            // An ASCII line is as wide as it is long.
            let (length, wide) = if line.is_ascii() {
                (line.len(), line.len())
            } else {
                (line.chars().count(), width(line))
            };
            wrap.longest = wrap.longest.max(length);
            widths.push(wide);
        }
        wrap.widest = widths.iter().copied().max().unwrap_or(0);
        wrap.at_edge = widths
            .iter()
            .filter(|&&width| width * 10 >= wrap.widest * 9)
            .count();
        wrap
    }

    /// How `next` joins `line`, the line before it, when it continues it;
    /// none when they stay apart. `after` is the line after `next`. Lines of
    /// code never join, nor a line of one script with a line of another.
    ///
    /// - J1: `line` is long (30 characters and three quarters of the
    ///   block's longest), ends in a letter, digit, comma or hyphen, `next`
    ///   starts with a small letter, and both have the same indent. In a
    ///   chat with people, `line` must also fill the line (50 characters and
    ///   nine tenths of the longest), so two messages never merge.
    /// - J2: `line` ends on a joining word ("and", "the", "by" …), with the
    ///   same indent, whatever `next`'s length or case, unless `next` is a
    ///   list item, a speaker line or a heading. Not in a group of short
    ///   lines (no line of 40 characters): an address, a menu, a poem.
    /// - J3: in a block of prose (three lines or more, one of them 50
    ///   characters wide, two of them at the wrap edge), `line` fills the
    ///   line (nine tenths of the widest), ends in a letter or digit, and
    ///   `next` starts with a
    ///   capital or a digit and is not a list item, a heading, a byline or a
    ///   speaker line: a wrap just before a name.
    /// - J4: the same, with `line` ending a sentence: a line that ends at
    ///   the wrap edge was wrapped; a paragraph's last line rarely is.
    fn glue(&self, line: &str, next: &str, after: Option<&str>) -> Option<Glue> {
        if self.join == Join::Never {
            return None;
        }
        let end = line.trim_end().chars().next_back()?;
        let start = next.trim_start().chars().next()?;
        if is_cjk_text(end) != is_cjk_text(start) {
            return None;
        }
        let tight = is_cjk_text(end) && is_cjk_text(start);
        let length = line.trim_end().chars().count();
        let fills = |measure: usize, of: usize| measure * 10 >= of * 9;
        // Each rule's own shape first, which is quick to tell; code, list
        // items, speakers and headings only for a pair one of them fits.
        let j1 = joins(line, next, self.longest)
            && (self.join != Join::Filled || (length >= 50 && fills(length, self.longest)));
        let prose_rules = !j1 && self.join == Join::Prose && indent(line) == indent(next);
        let j2 = prose_rules
            && self.longest >= 40
            && line.split_whitespace().nth(1).is_some()
            && reading_blocks::ends_on_joining_word(line);
        let j3_or_j4 = prose_rules
            && !j2
            && self.lines >= 3
            && self.widest >= 50
            && self.at_edge >= 2
            && fills(width(line), self.widest)
            && {
                let capital = start.is_uppercase() || start.is_ascii_digit() || tight;
                let j3 = end.is_alphanumeric() && capital;
                let j4 = (matches!(end, '.' | '?' | '!') && start.is_uppercase())
                    || (tight && matches!(end, '\u{3002}' | '\u{FF1F}' | '\u{FF01}'));
                j3 || j4
            };
        if !(j1 || j2 || j3_or_j4)
            || reading_blocks::code_line(line)
            || reading_blocks::code_line(next)
        {
            return None;
        }
        if !j1
            && (reading_blocks::list_item(next).is_some()
                || reading_blocks::speaker_line(next).is_some()
                || reading_blocks::heading_follows(next, after, self.lead)
                || (j3_or_j4 && reading_blocks::byline_like(next)))
        {
            return None;
        }
        Some(if tight || (j1 && ends_in_hyphenated_word(line)) {
            Glue::Tight
        } else {
            Glue::Space
        })
    }
}

/// A CJK, kana or hangul character, or CJK punctuation.
fn is_cjk_text(ch: char) -> bool {
    is_cjk(ch) || matches!(ch, '\u{3000}'..='\u{303F}' | '\u{FF00}'..='\u{FF65}')
}

/// How wide `line` is drawn: a CJK character counts as two.
fn width(line: &str) -> usize {
    line.trim_end()
        .chars()
        .map(|ch| if is_cjk_text(ch) { 2 } else { 1 })
        .sum()
}

/// J1: whether `next` continues the paragraph `line` wraps: `line` is long
/// (30 characters and at least three quarters of the block's longest), ends
/// in a letter, digit, comma or hyphen, `next` starts with a lowercase
/// letter, and both have the same indent.
fn joins(line: &str, next: &str, longest: usize) -> bool {
    let end = line.trim_end();
    let length = end.chars().count();
    length >= 30
        && length * 4 >= longest * 3
        && end
            .chars()
            .next_back()
            .is_some_and(|ch| ch.is_alphanumeric() || ch == ',' || ch == '-')
        && next
            .trim_start()
            .chars()
            .next()
            .is_some_and(char::is_lowercase)
        && indent(line) == indent(next)
}

fn ends_in_hyphenated_word(line: &str) -> bool {
    let mut chars = line.trim_end().chars().rev();
    chars.next() == Some('-') && chars.next().is_some_and(char::is_alphabetic)
}

fn indent(line: &str) -> &str {
    &line[..line.len() - line.trim_start().len()]
}

/// A block is preformatted when 40% of its lines read like code, when it has
/// three indent levels with a quarter of its lines indented, when a line
/// holds a tab or starts with a shell prompt, or when 60% of its lines carry
/// two numbers. The whole block is judged: each count only grows, so the
/// answer is known as soon as one of them is reached.
pub(crate) fn is_preformatted(lines: &[&str]) -> bool {
    let count = lines.len();
    let (mut code, mut indented, mut numeric) = (0usize, 0usize, 0usize);
    let mut levels: Vec<usize> = Vec::with_capacity(3);
    for line in lines {
        let facts = LineFacts::of(line);
        if line.contains('\t') || (facts.prompt_mark && starts_with_prompt(line)) {
            return true;
        }
        code += usize::from(facts.code);
        let depth = line.chars().take_while(|ch| ch.is_whitespace()).count();
        indented += usize::from(depth > 0);
        if levels.len() < 3 && !levels.contains(&depth) {
            levels.push(depth);
        }
        numeric += usize::from(
            facts.digit
                && line
                    .split_whitespace()
                    .filter(|token| is_number(token))
                    .nth(1)
                    .is_some(),
        );
        if code * 10 >= count * 4
            || numeric * 10 >= count * 6
            || (levels.len() >= 3 && indented * 4 >= count)
        {
            return true;
        }
    }
    false
}

/// What the preformatted test needs of one line, from one pass over its
/// bytes.
struct LineFacts {
    /// It holds a character a shell prompt starts with (or a lead byte of
    /// one), so the prompt pattern is worth trying.
    prompt_mark: bool,
    /// It reads like code: one of `{}();=<>[]`, or `::`, or it ends in `,`
    /// or `:`. (`->` and `=>` hold `>` and `=`.) A sentence's semicolon,
    /// followed by a space, and the angle brackets around an email address
    /// ("Dana Whitfield <dana@northwind.example>") are not code.
    code: bool,
    /// It holds an ASCII digit, so it may carry numbers.
    digit: bool,
}

impl LineFacts {
    fn of(line: &str) -> Self {
        let mut facts = Self {
            prompt_mark: false,
            code: false,
            digit: false,
        };
        let bytes = line.as_bytes();
        let address = email_in_brackets(line);
        let mut previous = 0u8;
        for (at, &byte) in bytes.iter().enumerate() {
            let in_address = address.is_some_and(|(open, close)| at == open || at == close);
            match byte {
                b';' if bytes.get(at + 1) == Some(&b' ') => {}
                b'<' | b'>' if in_address => {}
                b'{' | b'}' | b'(' | b')' | b';' | b'=' | b'<' | b'[' | b']' => facts.code = true,
                b'>' => {
                    facts.code = true;
                    facts.prompt_mark = true;
                }
                b'$' | b'%' | b'#' | 0xCE | 0xE2 => facts.prompt_mark = true,
                b'0'..=b'9' => facts.digit = true,
                b':' if previous == b':' => facts.code = true,
                _ => {}
            }
            previous = byte;
        }
        facts.code = facts.code || line.trim_end().ends_with([',', ':']);
        facts
    }
}

/// The byte offsets of the `<` and `>` around an email address in `line`,
/// as mail shows a sender: "Dana Whitfield <dana@northwind.example>".
fn email_in_brackets(line: &str) -> Option<(usize, usize)> {
    let at = line.find('@')?;
    let open = line[..at].rfind('<')?;
    let close = at + line[at..].find('>')?;
    let address = &line[open + 1..close];
    (!address.contains(char::is_whitespace) && address.contains('.')).then_some((open, close))
}

fn is_number(token: &str) -> bool {
    token
        .trim_start_matches(['$', '€', '£', '¥', '+', '-', '\u{2212}', '('])
        .starts_with(|ch: char| ch.is_ascii_digit())
}

pub(crate) fn starts_with_prompt(line: &str) -> bool {
    static PROMPT: OnceLock<Regex> = OnceLock::new();
    // Most lines hold no prompt mark: a byte test first ("\u{276F}" and
    // "\u{279C}" start with 0xE2, "\u{3BB}" with 0xCE).
    if !line
        .bytes()
        .any(|byte| matches!(byte, b'$' | b'%' | b'#' | b'>' | 0xE2 | 0xCE))
        || !line.contains(['$', '%', '#', '>', '\u{276F}', '\u{279C}', '\u{3BB}'])
    {
        return false;
    }
    PROMPT
        .get_or_init(|| {
            Regex::new(r"^\s*(?:[$%\x{276F}\x{279C}\x{3BB}]|>{1,3}|\S+@\S+(?:\s+\S+)?\s*[$%#])\s")
                .expect("the prompt pattern compiles")
        })
        .is_match(line)
}

/// `line` without its junk tokens, each deleted with one whitespace
/// character beside it (the one before it when there is one).
fn without_junk<'l>(line: &'l str, rules: &Rules<'_>) -> Cow<'l, str> {
    // Every junk character is outside ASCII.
    if line.is_ascii() {
        return Cow::Borrowed(line);
    }
    let mut cuts: Vec<(usize, usize)> = Vec::new();
    let mut free_from = 0;
    for (start, end) in token_spans(line) {
        if !is_junk(&line[start..end], rules) {
            continue;
        }
        let before = line[..start]
            .chars()
            .next_back()
            .filter(|ch| ch.is_whitespace() && start - ch.len_utf8() >= free_from);
        let after = line[end..].chars().next().filter(|ch| ch.is_whitespace());
        let cut = match (before, after) {
            (Some(ch), _) => (start - ch.len_utf8(), end),
            (None, Some(ch)) => (start, end + ch.len_utf8()),
            (None, None) => (start, end),
        };
        free_from = cut.1;
        cuts.push(cut);
    }
    if cuts.is_empty() {
        return Cow::Borrowed(line);
    }
    let mut out = String::with_capacity(line.len());
    let mut at = 0;
    for (start, end) in cuts {
        out.push_str(&line[at..start]);
        at = end;
    }
    out.push_str(&line[at..]);
    Cow::Owned(out)
}

/// Byte ranges of the whitespace-delimited tokens of `line`.
fn token_spans(line: &str) -> impl Iterator<Item = (usize, usize)> + '_ {
    let mut chars = line.char_indices().peekable();
    std::iter::from_fn(move || {
        while chars.next_if(|(_, ch)| ch.is_whitespace()).is_some() {}
        let (start, first) = chars.next()?;
        let mut end = start + first.len_utf8();
        while let Some((at, ch)) = chars.next_if(|(_, ch)| !ch.is_whitespace()) {
            end = at + ch.len_utf8();
        }
        Some((start, end))
    })
}

/// N1 and N2.
fn is_junk(token: &str, rules: &Rules<'_>) -> bool {
    let mut chars = token.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if chars.next().is_none() && is_cjk(first) {
        return rules.cjk_rare();
    }
    token.chars().all(is_glyph_debris)
}

fn is_glyph_debris(ch: char) -> bool {
    matches!(
        ch,
        '\u{2500}'..='\u{25FF}'
            | '\u{E000}'..='\u{F8FF}'
            | '\u{F0000}'..='\u{FFFFD}'
            | '\u{100000}'..='\u{10FFFD}'
            | '\u{FFFD}'
    )
}

fn is_cjk(ch: char) -> bool {
    matches!(
        ch,
        '\u{1100}'..='\u{11FF}' // hangul jamo
            | '\u{3040}'..='\u{30FF}' // hiragana, katakana
            | '\u{3130}'..='\u{318F}' // hangul compatibility jamo
            | '\u{31F0}'..='\u{31FF}' // katakana extension
            | '\u{3400}'..='\u{4DBF}' // ideographs, extension A
            | '\u{4E00}'..='\u{9FFF}' // ideographs
            | '\u{A960}'..='\u{A97F}' // hangul jamo extension A
            | '\u{AC00}'..='\u{D7FF}' // hangul syllables, jamo extension B
            | '\u{F900}'..='\u{FAFF}' // compatibility ideographs
            | '\u{FF66}'..='\u{FF9F}' // halfwidth katakana
            | '\u{FFA0}'..='\u{FFDC}' // halfwidth hangul
            | '\u{20000}'..='\u{323AF}' // ideographs, extensions B to H
    )
}

/// Under 10% of the letters in `text` are CJK, kana or hangul.
fn cjk_is_rare(text: &str) -> bool {
    if text.is_ascii() {
        return true;
    }
    let bytes = text.as_bytes();
    let mut letters = 0usize;
    let mut cjk = 0usize;
    let mut at = 0;
    while at < bytes.len() {
        let byte = bytes[at];
        if byte < 0x80 {
            if byte.is_ascii_alphabetic() {
                letters += 1;
            }
            at += 1;
            continue;
        }
        let ch = text[at..].chars().next().expect("a character starts here");
        if ch.is_alphabetic() {
            letters += 1;
            cjk += usize::from(is_cjk(ch));
        }
        at += ch.len_utf8();
    }
    cjk * 10 < letters
}

// ---------------------------------------------------------------------------
// Passages
// ---------------------------------------------------------------------------

fn is_line_break(ch: char) -> bool {
    matches!(ch, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The byte range of a search passage: on the line of the first word, with
/// up to [`LEAD_BYTES`] of what comes before it, never opening on half a
/// word, then as much as fits.
fn around(text: &str, (first, end): (usize, usize), max_bytes: usize) -> (usize, usize) {
    let line_start = text[..first]
        .char_indices()
        .rev()
        .find(|(_, ch)| is_line_break(*ch))
        .map_or(0, |(at, ch)| at + ch.len_utf8());
    let lead = max_bytes.saturating_sub(end - first).min(LEAD_BYTES);
    let mut start = ceil_char_boundary(text, first.saturating_sub(lead).max(line_start));
    if start > line_start && !text[..start].ends_with(char::is_whitespace) {
        start = text[start..first]
            .find(char::is_whitespace)
            .map_or(first, |at| start + at);
        start = first - text[start..first].trim_start().len();
    }
    (
        start,
        floor_char_boundary(text, start.saturating_add(max_bytes)),
    )
}

/// The byte range of the first whole lines of `text` that fit `max_bytes`,
/// after any blank lines it opens with. A first line longer than that is cut
/// after its last word that fits, or, when what fits is one word, at the
/// limit.
fn first_lines(text: &str, max_bytes: usize) -> (usize, usize) {
    let start = text.len() - text.trim_start_matches('\n').len();
    let text_from = &text[start..];
    let end = text_from.trim_end().len();
    if end <= max_bytes {
        return (start, start + end);
    }
    let limit = floor_char_boundary(text_from, max_bytes);
    let head = &text_from[..limit];
    let after = &text_from[limit..];
    let stop = if after.starts_with('\n') || after.starts_with("\r\n") {
        limit
    } else if let Some(at) = head.rfind('\n') {
        at
    } else if after.starts_with(char::is_whitespace) {
        limit
    } else {
        head.rfind(char::is_whitespace)
            .filter(|&at| !head[..at].trim().is_empty())
            .unwrap_or(limit)
    };
    (start, start + text_from[..stop].trim_end().len())
}

/// The byte range of the last whole lines of `text` that fit `max_bytes`.
/// A last line longer than that gives its end, from a word's start.
fn last_lines(text: &str, max_bytes: usize) -> (usize, usize) {
    let stop = text.trim_end().len();
    let mut start = if stop <= max_bytes {
        0
    } else {
        let earliest = ceil_char_boundary(text, stop - max_bytes);
        if text[..earliest].ends_with('\n') {
            earliest
        } else if let Some(at) = text[earliest..stop].find('\n') {
            earliest + at + 1
        } else {
            text[earliest..stop]
                .char_indices()
                .find(|(_, ch)| ch.is_whitespace())
                .map_or(earliest, |(at, ch)| earliest + at + ch.len_utf8())
        }
    };
    start = stop - text[start..stop].trim_start_matches('\n').len();
    (start, stop)
}

/// `text[start..stop]`, unless the cut makes a secret pattern appear that
/// `text` itself does not hold: then the words the cut split are left out.
fn cut_clean(text: &str, start: usize, stop: usize) -> String {
    let piece = &text[start..stop];
    if !contains_secret(piece) || contains_secret(text) {
        return piece.to_owned();
    }
    let mut from = start;
    if from > 0 && !text[..from].ends_with(char::is_whitespace) {
        from = piece
            .find(char::is_whitespace)
            .map_or(stop, |at| start + at);
    }
    let mut to = stop;
    if to < text.len() && !text[to..].starts_with(char::is_whitespace) {
        to = text[from..stop]
            .rfind(char::is_whitespace)
            .map_or(from, |at| from + at);
    }
    text[from..to].trim().to_owned()
}

/// The first `max_chars` characters of `text`.
fn first_chars(text: &str, max_chars: usize) -> &str {
    text.char_indices()
        .nth(max_chars)
        .map_or(text, |(at, _)| &text[..at])
}

fn floor_char_boundary(text: &str, at: usize) -> usize {
    let mut at = at.min(text.len());
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    at
}

fn ceil_char_boundary(text: &str, at: usize) -> usize {
    let mut at = at.min(text.len());
    while !text.is_char_boundary(at) {
        at += 1;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_prompt_mark_is_seen_past_the_byte_test() {
        for line in [
            "$ ls",
            "% make",
            "> npm test",
            ">>> print(1)",
            "\u{276F} cargo test",
            "\u{279C} git status",
            "\u{3BB} stack build",
            "dev@studio shop % cargo test",
            "root@box:~# ls",
        ] {
            assert!(starts_with_prompt(line), "{line}");
        }
        for line in [
            "Round half up looks fair.",
            "It costs $5 a month",
            "50% off",
            "a -> b",
            "\u{2019}Quoted\u{2019} \u{2014} not a prompt",
            "\u{3B1}\u{3B2} letters",
        ] {
            assert!(!starts_with_prompt(line), "{line}");
        }
    }

    #[test]
    fn a_junk_token_goes_with_the_space_before_it() {
        let latin = Rules::for_app("Docs Pricing and some more words to count", false, None);
        assert_eq!(
            without_junk("Docs \u{25a1} Pricing", &latin),
            "Docs Pricing"
        );
        assert_eq!(without_junk("\u{25a1} Pricing", &latin), "Pricing");
        assert_eq!(without_junk("Pricing \u{25a1}", &latin), "Pricing");
        assert_eq!(
            without_junk("  \u{25a1} let x = 1;", &latin),
            "  let x = 1;"
        );
        assert_eq!(without_junk("a \u{53e3} \u{53e3}", &latin), "a");
        assert_eq!(without_junk("\u{53e3} \u{53e3} b", &latin), "b");
        let cjk = Rules::for_app("\u{53e3} b", false, None);
        assert_eq!(without_junk("\u{53e3} b", &cjk), "\u{53e3} b");
    }

    #[test]
    fn letters_are_counted_only_when_a_lone_cjk_character_turns_up() {
        let rules = Rules::for_app("Docs \u{25a1} Pricing", false, None);
        assert_eq!(
            without_junk("Docs \u{25a1} Pricing", &rules),
            "Docs Pricing"
        );
        assert!(rules.cjk_rare.get().is_none());
        assert_eq!(without_junk("\u{4e09} Docs", &rules), "Docs");
        assert_eq!(rules.cjk_rare.get(), Some(&true));
    }

    #[test]
    fn a_long_block_is_judged_as_a_whole() {
        // 64 lines of code, then 4 comment lines indented 8 spaces and 4 of
        // prose: code is most of the block, so all of it is kept as read.
        let code = "    let deleted = store.delete_batch(batch)?;\n".repeat(64);
        let comments = "        // the sweep goes on until nothing is left\n".repeat(4);
        let prose =
            "the plan grows with every seat the customer adds and the price follows it\n".repeat(4);
        let text = format!("{code}{comments}{prose}");
        let rules = Rules::for_app(&text, true, None);
        assert_eq!(clean(text.trim_end(), &rules, false), text.trim_end());
    }

    #[test]
    fn a_senders_address_and_a_sentences_semicolon_are_not_code() {
        let mail = [
            "Re: Invoice 1042",
            "Dana Whitfield <dana@northwind.example>",
            "to me",
            "Thanks for sending this over. The October invoice is attached; the amount due is $1,240.00",
            "by October 30, and the purchase order number has not changed.",
        ];
        assert!(!is_preformatted(&mail));
        let rules = Rules::for_app("", false, Some("com.google.Chrome"));
        assert!(clean_block(&mail, &rules, false, usize::MAX)
            .contains("the amount due is $1,240.00 by October 30, and"));
        assert!(is_preformatted(&[
            "let x = 1;",
            "let y = vec![x];",
            "fn main() {}"
        ]));
        assert!(LineFacts::of("for (i = 0;i < n;i++)").code);
        assert!(LineFacts::of("Vec<String>").code);
    }

    #[test]
    fn a_list_prefix_stops_inside_a_long_block() {
        let text = "the plan grows with every seat the customer adds\n".repeat(2_000);
        // Lines kept as read (a chat app's older text).
        let rules = Rules::for_app(&text, false, Some("com.tinyspeck.slackmacgap"));
        let head = clean_blocks(&text, &rules, false, 100);
        assert!(head.len() < 200, "{}", head.len());
        assert_eq!(head, text[..head.len()]);
        // Lines joined into a paragraph (a page's older text) stop as soon.
        let rules = Rules::for_app(&text, false, None);
        let head = clean_blocks(&text, &rules, false, 100);
        assert!(head.len() < 200, "{}", head.len());
        assert!(
            head.starts_with("the plan grows with every seat the customer adds the plan grows"),
            "{head}"
        );
    }

    #[test]
    fn tokens_are_whitespace_delimited() {
        let spans: Vec<_> = token_spans("  ab \u{53e3}  c").collect();
        assert_eq!(spans, vec![(2, 4), (5, 8), (10, 11)]);
    }

    #[test]
    fn the_separator_is_found_only_whole() {
        assert_eq!(split_chrome("a\u{1e}b"), ("a\u{1e}b", "", false));
        assert_eq!(split_chrome("a\n\n\u{1e}\nb"), ("a", "b", true));
        assert_eq!(split_chrome("a\u{1e}\n\n\u{1e}\nb"), ("a\u{1e}", "b", true));
    }

    #[test]
    fn blocks_are_the_runs_of_lines_between_blank_lines() {
        let text = "\n a\nb\n \n\nc\n";
        let spans: Vec<Span> = Blocks::new(text).collect();
        assert_eq!(
            spans,
            vec![Span { start: 1, end: 5 }, Span { start: 9, end: 10 }]
        );
        assert_eq!(Blocks::new("").count(), 0);
        assert_eq!(Blocks::new("\n \n").count(), 0);
    }

    #[test]
    fn words_are_runs_of_letters_and_digits() {
        let text = "Caf\u{e9}, \u{6771}\u{4eac}-2 \u{1f642}x_y";
        let found: Vec<(usize, &str)> = words(text).collect();
        assert_eq!(
            found,
            vec![
                (0, "Caf\u{e9}"),
                (7, "\u{6771}\u{4eac}"),
                (14, "2"),
                (20, "x"),
                (22, "y")
            ]
        );
        assert_eq!(words("").count(), 0);
        assert_eq!(words(" ,.").count(), 0);
    }

    #[test]
    fn blocks_read_from_the_end_are_the_same_blocks() {
        for text in [
            "\n a\nb\n \n\nc\n",
            "",
            "a",
            "a\n\nb",
            "\n\n",
            "x\ny\n\n\nz \n",
        ] {
            let mut back: Vec<Span> = BlocksBack::new(text).collect();
            back.reverse();
            assert_eq!(back, Blocks::new(text).collect::<Vec<_>>(), "{text:?}");
        }
        let text = "one\n\ntwo\nthree\n\nfour";
        assert_eq!(block_start(text, text.find("three").unwrap()), 5);
        assert_eq!(block_start(text, 1), 0);
        assert_eq!(block_start(text, text.find("four").unwrap()), 16);
    }

    #[test]
    fn the_first_lines_that_fit_are_whole_lines_or_whole_words() {
        let text = "first line\nsecond line\nthird";
        assert_eq!(
            &text[first_lines(text, 22).0..first_lines(text, 22).1],
            "first line\nsecond line"
        );
        assert_eq!(&text[..first_lines(text, 15).1], "first line");
        let one = "one long line of words";
        assert_eq!(&one[..first_lines(one, 10).1], "one long");
        assert_eq!(&one[..first_lines(one, 8).1], "one long");
        let word = "x".repeat(40);
        assert_eq!(first_lines(&word, 10), (0, 10));
        let indented = format!("    {}", "y".repeat(40));
        assert_eq!(first_lines(&indented, 10), (0, 10));
        let opening = "\nfirst\nsecond";
        let (start, stop) = first_lines(opening, 8);
        assert_eq!(&opening[start..stop], "first");
    }

    #[test]
    fn a_stray_separator_character_never_joins_a_key_to_its_value() {
        assert_eq!(shown("a\u{1e}b"), "a b");
        let joined = shown("Access password\u{1e}: hunter2 now");
        assert!(!contains_secret(&joined), "{joined:?}");
        assert!(joined.contains("Access") && joined.contains("now"));
    }

    #[test]
    fn main_and_rest_never_make_a_secret_where_they_meet() {
        let read = apart(Reading {
            main: "Account settings\nAccess token".into(),
            rest: "= 12345\nSidebar".into(),
        });
        assert!(!contains_secret(&joined(&read)), "{read:?}");
        assert_eq!(read.main, "Account settings\nAccess");
        assert_eq!(read.rest, "12345\nSidebar");
        let fine = Reading {
            main: "Launch plan".into(),
            rest: "Sidebar".into(),
        };
        assert_eq!(apart(fine.clone()), fine);
    }
}
