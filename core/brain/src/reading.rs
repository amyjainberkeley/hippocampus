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
//! - [`excerpt`] is a short passage: around a search's words, the last lines
//!   of a terminal or a chat, otherwise the first lines.
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
//!   dropped.
//! - Only text that carries the separator, which the helper classified, has
//!   its wrapped lines joined into paragraphs and its indents set to none or
//!   four spaces, outside preformatted blocks. Older text keeps its lines.
//!
//! A block (lines between blank lines) is preformatted, and kept byte for
//! byte but for junk tokens, in a terminal, when it reads like code, a table
//! or a shell session, or when it holds a tab. Every other source is shown as
//! stored, without its header. No reading holds U+001E.
//!
//! # The guard
//!
//! The capture helper stores no OCR text that one of its four secret patterns
//! matches ([`crate::redaction::ocr_secrets`]). Cleaning could make one appear,
//! for example by removing a stray symbol between `token` and `=`. When a
//! cleaned reading matches, it falls back to the stored parts with no other
//! cleaning, cut in the same places. A short passage whose cut makes a pattern
//! appear leaves out the words the cut split.

use std::borrow::Cow;
use std::cell::OnceCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::OnceLock;

use regex::Regex;

use crate::event_source::EventSource;
use crate::fts_sanitizer::{sanitize_fts5_query, LexicalAlternative};
use crate::redaction::ocr_secrets::contains_secret;

/// Between a classified window's content and its chrome, in stored text.
/// The helper writes it whenever it classifies, even with no chrome.
pub const CHROME_SEPARATOR: &str = "\n\n\u{1E}\n";

/// Between a browser page's own text and the text read off the screen, in a
/// `browser_page_with_ocr` event.
pub const VISIBLE_OCR_SEPARATOR: &str = "\n\n[VISIBLE-OCR]\n";

/// The line an MCP resource event starts with, before its header.
const MCP_REVISION_PREFIX: &str = "[MCP_RESOURCE revision_sha256=";

/// Terminals: every block is kept as it was read, and a passage is the end.
pub const TERMINAL_APPS: [&str; 7] = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "org.alacritty",
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
/// transcript imports (with `| session=… | src=…`) write it. An MCP
/// resource's revision line before the header goes with it. Any other text
/// comes back unchanged.
#[must_use]
pub fn body(stored: &str) -> &str {
    let after_revision = stored
        .strip_prefix(MCP_REVISION_PREFIX)
        .and_then(|rest| rest.split_once("]\n"))
        .filter(|(digest, _)| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
        .map_or(stored, |(_, rest)| rest);
    match after_revision.split_once('\n') {
        Some((first, rest)) if is_header(first) => rest,
        _ => stored,
    }
}

fn is_header(line: &str) -> bool {
    line.strip_prefix("[app=")
        .and_then(|fields| fields.strip_suffix(']'))
        .and_then(|fields| fields.split_once(" | title="))
        .is_some_and(|(_, after_title)| after_title.contains(" | url="))
}

/// The reading of one stored event.
///
/// `app` is the event's bundle id. `_title` is the window's title; no rule
/// uses it this round.
#[must_use]
pub fn reading(
    stored: &str,
    source: EventSource,
    app: Option<&str>,
    _title: Option<&str>,
) -> Reading {
    let text = body(stored);
    match source {
        EventSource::ScreenOcr | EventSource::ScreenContext => read_screen(text, app),
        EventSource::BrowserPageWithOcr => match text.split_once(VISIBLE_OCR_SEPARATOR) {
            Some((page, seen)) => Reading {
                main: shown(page).into_owned(),
                rest: joined(&read_screen(seen, app)),
            },
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
            return read_screen(seen, app);
        }
    }
    reading(stored, source, app, title)
}

/// The first `max_chars` characters of the event's `main`, for a list row.
///
/// The same text as `reading(…).main` cut to `max_chars`, but it reads only
/// as many blocks as it needs. It takes `app` because a terminal's blocks are
/// kept as they were read.
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
        EventSource::ScreenOcr | EventSource::ScreenContext => screen_prefix(text, app, max_chars),
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
            shown(first_chars(page, max_chars)).into_owned()
        }
        _ => shown(first_chars(text, max_chars)).into_owned(),
    }
}

/// The words of a search, to find in a passage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExcerptQuery {
    words: HashSet<String>,
}

impl ExcerptQuery {
    /// The words of one search as typed.
    #[must_use]
    pub fn new(text: &str) -> Self {
        Self::from_alternatives(&[LexicalAlternative::Keywords(text)])
    }

    /// The words of every spelling a search tried, as the store matched them.
    #[must_use]
    pub fn from_alternatives(alternatives: &[LexicalAlternative<'_>]) -> Self {
        let mut words = HashSet::new();
        for alternative in alternatives {
            let (LexicalAlternative::Keywords(text) | LexicalAlternative::Phrase(text)) =
                alternative;
            let literal = sanitize_fts5_query(text);
            words.extend(
                literal
                    .split(|ch: char| !ch.is_alphanumeric())
                    .filter(|word| !word.is_empty())
                    .map(str::to_lowercase),
            );
        }
        Self { words }
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

    /// Byte range from the first to the end of the last word of the span
    /// that holds the most different words within `max_bytes`, shortest
    /// first. Literal words only: the store's stemming is not repeated.
    fn closest_words(&self, text: &str, max_bytes: usize) -> Option<(usize, usize)> {
        let mut window: VecDeque<(usize, &str)> = VecDeque::new();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut best: Option<(usize, usize, usize)> = None; // (distinct words, first, end)
        let mut offset = 0;
        for segment in text.split_inclusive(|ch: char| !ch.is_alphanumeric()) {
            let word = segment.trim_end_matches(|ch: char| !ch.is_alphanumeric());
            let start = offset;
            offset += segment.len();
            if word.is_empty() {
                continue;
            }
            let Some(term) = self.words.get(&word.to_lowercase()) else {
                continue;
            };
            let end = start + word.len().min(max_bytes);
            window.push_back((start, term.as_str()));
            *counts.entry(term.as_str()).or_default() += 1;
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

/// A passage of `text` of at most `max_bytes`, verbatim.
///
/// With a query: on the line of the closest group of its words, with a little
/// of what comes before them, from `main` when the words are there and from
/// `rest` otherwise. Otherwise, or when no word is found: the last lines of
/// `main` for a terminal or chat app, the first part of `main` for any other.
/// A cut never makes a secret pattern appear.
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
    let main = text.main.as_str();
    let newest_last =
        app.is_some_and(|app| TERMINAL_APPS.contains(&app) || CHAT_APPS.contains(&app));
    let (start, stop) = if newest_last {
        last_lines(main, max_bytes)
    } else {
        (0, floor_char_boundary(main, max_bytes))
    };
    cut_clean(main, start, stop)
}

// ---------------------------------------------------------------------------
// Screen text
// ---------------------------------------------------------------------------

/// A block longer than this is judged in pieces of this many lines, so no
/// decision needs a whole window's text.
const BLOCK_LINES: usize = 64;

/// What the rules know about one screen text.
struct Rules<'t> {
    /// The whole screen text, content and chrome, for N1's count of letters.
    text: &'t str,
    cjk_rare: OnceCell<bool>,
    /// The text carries the separator: paragraphs join, indents are set.
    classified: bool,
}

impl<'t> Rules<'t> {
    fn new(text: &'t str, classified: bool) -> Self {
        Self {
            text,
            cjk_rare: OnceCell::new(),
            classified,
        }
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

fn read_screen(text: &str, app: Option<&str>) -> Reading {
    let (content, chrome, classified) = split_chrome(text);
    let rules = Rules::new(text, classified);
    // A terminal's own text is kept as read; its tabs and title are not
    // terminal output.
    let cleaned = Reading {
        main: clean(content, &rules, is_terminal(app)),
        rest: clean(chrome, &rules, false),
    };
    if makes_secret(&cleaned) {
        return Reading {
            main: shown(content).into_owned(),
            rest: shown(chrome).into_owned(),
        };
    }
    cleaned
}

fn screen_prefix(text: &str, app: Option<&str>, max_chars: usize) -> String {
    let (content, _, classified) = split_chrome(text);
    let rules = Rules::new(text, classified);
    let content = shown(content);
    let mut out = String::new();
    let mut chars = 0usize;
    clean_blocks(&content, &rules, is_terminal(app), &mut |gap, block| {
        out.push_str(gap);
        out.push_str(block);
        chars += gap.chars().count() + block.chars().count();
        chars < max_chars
    });
    out.truncate(first_chars(&out, max_chars).len());
    if !contains_secret(&out) {
        return out;
    }
    // Cleaning or the cut made a secret pattern appear: show the stored start.
    cut_clean(&content, 0, first_chars(&content, max_chars).len())
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

fn makes_secret(reading: &Reading) -> bool {
    if reading.rest.is_empty() {
        contains_secret(&reading.main)
    } else {
        contains_secret(&joined(reading))
    }
}

fn joined(reading: &Reading) -> String {
    match (reading.main.is_empty(), reading.rest.is_empty()) {
        (_, true) => reading.main.clone(),
        (true, false) => reading.rest.clone(),
        (false, false) => format!("{}\n\n{}", reading.main, reading.rest),
    }
}

/// Stored text as it may be shown: no U+001E.
fn shown(text: &str) -> Cow<'_, str> {
    if text.contains('\u{1E}') {
        Cow::Owned(text.replace('\u{1E}', " "))
    } else {
        Cow::Borrowed(text)
    }
}

fn as_stored(text: &str) -> Reading {
    Reading {
        main: shown(text).into_owned(),
        rest: String::new(),
    }
}

fn clean(text: &str, rules: &Rules<'_>, terminal: bool) -> String {
    let text = shown(text);
    let mut out = String::with_capacity(text.len());
    clean_blocks(&text, rules, terminal, &mut |gap, block| {
        out.push_str(gap);
        out.push_str(block);
        true
    });
    out
}

/// Clean `text` block by block (a block is the lines between blank lines,
/// in pieces of at most [`BLOCK_LINES`]). Each block that keeps any text goes
/// to `sink` with what stood before it (nothing before the first), in order.
/// A block that loses all its text takes the blank lines before it along.
/// `sink` returns false to stop.
fn clean_blocks(
    text: &str,
    rules: &Rules<'_>,
    terminal: bool,
    sink: &mut dyn FnMut(&str, &str) -> bool,
) {
    let mut gap = String::new();
    let mut started = false;
    let mut block: Vec<&str> = Vec::new();
    // A blank line after the text ends the last block.
    for line in text.split('\n').chain(std::iter::once("")) {
        let blank = line.trim().is_empty();
        if !blank && block.len() < BLOCK_LINES {
            block.push(line);
            continue;
        }
        if !block.is_empty() {
            let cleaned = clean_block(&block, rules, terminal);
            block.clear();
            if !cleaned.is_empty() {
                let before = if started { gap.as_str() } else { "" };
                if !sink(before, &cleaned) {
                    return;
                }
                started = true;
            }
            gap.clear();
            gap.push('\n');
        }
        if blank {
            if started {
                gap.push_str(line);
                gap.push('\n');
            }
        } else {
            // The first line of the next piece of a long block.
            block.push(line);
        }
    }
}

fn clean_block(lines: &[&str], rules: &Rules<'_>, terminal: bool) -> String {
    if terminal || is_preformatted(lines) {
        // Junk tokens go; every line keeps its place.
        let kept: Vec<Cow<'_, str>> = lines.iter().map(|line| without_junk(line, rules)).collect();
        if kept.iter().all(|line| line.trim().is_empty()) {
            return String::new();
        }
        return kept.join("\n");
    }
    let kept: Vec<Cow<'_, str>> = lines
        .iter()
        .map(|line| without_junk(line, rules))
        .filter(|line| line.chars().any(char::is_alphanumeric))
        .collect();
    if rules.classified {
        shaped(&kept)
    } else {
        kept.join("\n")
    }
}

/// Join wrapped lines into paragraphs, then set every indent to none or four
/// spaces.
fn shaped(lines: &[Cow<'_, str>]) -> String {
    let longest = lines
        .iter()
        .map(|line| line.trim_end().chars().count())
        .max()
        .unwrap_or(0);
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    let mut previous: Option<&str> = None;
    for line in lines {
        let line: &str = line;
        if let (Some(before), Some(last)) = (previous, out.last_mut()) {
            if joins(before, line, longest) {
                last.truncate(last.trim_end().len());
                if !ends_in_hyphenated_word(before) {
                    last.push(' ');
                }
                last.push_str(line.trim_start());
                previous = Some(line);
                continue;
            }
        }
        out.push(line.to_owned());
        previous = Some(line);
    }
    out.iter()
        .map(|line| {
            if indent(line).is_empty() {
                Cow::Borrowed(line.as_str())
            } else {
                Cow::Owned(format!("    {}", line.trim_start()))
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Whether `next` continues the paragraph `line` wraps: `line` is long (30
/// characters and at least three quarters of the block's longest), ends in a
/// letter, digit, comma or hyphen, `next` starts with a lowercase letter, and
/// both have the same indent.
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
/// two numbers.
fn is_preformatted(lines: &[&str]) -> bool {
    let count = lines.len();
    if lines
        .iter()
        .any(|line| line.contains('\t') || starts_with_prompt(line))
    {
        return true;
    }
    let code = lines.iter().filter(|line| reads_like_code(line)).count();
    if code * 10 >= count * 4 {
        return true;
    }
    let levels: HashSet<usize> = lines
        .iter()
        .map(|line| indent(line).chars().count())
        .collect();
    let indented = lines.iter().filter(|line| !indent(line).is_empty()).count();
    if levels.len() >= 3 && indented * 4 >= count {
        return true;
    }
    let numeric = lines
        .iter()
        .filter(|line| {
            line.split_whitespace()
                .filter(|token| is_number(token))
                .count()
                >= 2
        })
        .count();
    numeric * 10 >= count * 6
}

fn reads_like_code(line: &str) -> bool {
    const INSIDE: &[char] = &['{', '}', '(', ')', ';', '=', '<', '>', '[', ']'];
    const AT_END: &[char] = &['{', '}', '(', ')', ';', ',', '=', '[', ']', '<', '>', ':'];
    let line = line.trim_end();
    line.contains(INSIDE)
        || line.contains("::")
        || line.contains("->")
        || line.contains("=>")
        || line.ends_with(AT_END)
}

fn is_number(token: &str) -> bool {
    token
        .trim_start_matches(['$', '€', '£', '¥', '+', '-', '\u{2212}', '('])
        .starts_with(|ch: char| ch.is_ascii_digit())
}

fn starts_with_prompt(line: &str) -> bool {
    static PROMPT: OnceLock<Regex> = OnceLock::new();
    if !line.contains(['$', '%', '#', '>', '\u{276F}', '\u{279C}', '\u{3BB}']) {
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
    fn a_junk_token_goes_with_the_space_before_it() {
        let latin = Rules::new("Docs Pricing and some more words to count", false);
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
        let cjk = Rules::new("\u{53e3} b", false);
        assert_eq!(without_junk("\u{53e3} b", &cjk), "\u{53e3} b");
    }

    #[test]
    fn letters_are_counted_only_when_a_lone_cjk_character_turns_up() {
        let rules = Rules::new("Docs \u{25a1} Pricing", false);
        assert_eq!(
            without_junk("Docs \u{25a1} Pricing", &rules),
            "Docs Pricing"
        );
        assert!(rules.cjk_rare.get().is_none());
        assert_eq!(without_junk("\u{4e09} Docs", &rules), "Docs");
        assert_eq!(rules.cjk_rare.get(), Some(&true));
    }

    #[test]
    fn a_long_block_is_judged_in_pieces() {
        let prose = "the plan grows with every seat the customer adds and the price follows it\n";
        let code = "    let deleted = store.delete_batch(batch)?;\n";
        let text = format!("{}{}", prose.repeat(BLOCK_LINES), code.repeat(BLOCK_LINES));
        let rules = Rules::new(&text, true);
        let cleaned = clean(text.trim_end(), &rules, false);
        assert!(
            cleaned.ends_with(code.trim_end()),
            "the code piece keeps its indent"
        );
        assert!(
            !cleaned.contains("follows it\nthe plan"),
            "the prose piece joins its lines"
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
}
