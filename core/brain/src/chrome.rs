//! Window chrome: what a window shows around what the person was reading.
//!
//! A browser's tab strip, address bar and bookmarks bar; a web app's menus
//! and side navigation; an editor's tabs, side bar headings, breadcrumbs and
//! status bar; a chat app's sidebar headings and message box. The reader
//! ([`crate::reading`]) moves these lines out of `main` into `rest` ("Also in
//! this window"). Nothing is deleted: `rest` keeps them, and the stored text,
//! which search indexes, keeps every word, so a tab title still finds its
//! moment.
//!
//! Only text stored before the capture helper classified windows is looked
//! at. A classified window's content is what the helper, which knew where
//! each line sat on the screen, kept as content, and it stays whole.
//!
//! Chrome sits around what was read, so only the window's edges are looked
//! at: the run of lines at its top and the run at its bottom, each ending at
//! the first line that is not chrome. A line in the middle of what was read
//! never moves as a whole, however much it reads like chrome: a reply "More",
//! a heading "## TIMELINE", a formula with "×" in it.
//!
//! Two kinds of rule:
//!
//! - **One frame.** The shape of a line, where it sits and the window it is
//!   in: tab titles joined by close buttons, led by the favicons of pinned
//!   tabs, or holding the window's own title among other titles; an address
//!   alone with toolbar glyphs; "All Bookmarks"; a web app's row of menus
//!   ("File Edit View Insert Format Tools Help"); a search page's tabs; a
//!   site's menu ending in its "Subscribe" or "Sign in" button; the side
//!   navigation of Gmail, Google Calendar, GitHub, YouTube, LinkedIn, Notes,
//!   Finder and System Settings; "EXPLORER", "Ln 14, Col 37"; Slack's
//!   "Message #launch-plan"; Messages' "Delivered" and "iMessage".
//! - **Many frames** ([`RepeatedChrome`]). A line of two words or more that
//!   windows of one app showed at their edges, unchanged, in at least half of
//!   that app's frames and under at least [`RepeatedChrome::MIN_TITLES`]
//!   different titles: a sidebar, a site's menu, a bookmarks bar. Lines of
//!   code, tables and shell sessions are never learned, and a chat app learns
//!   only its channel names, never what was said. The re-clean job learns
//!   these lines from the moments around a moment. Such a line also comes off
//!   the start of a line it was read into (a sidebar read into the same line
//!   as a message), anywhere outside code.
//!
//! A terminal's text is kept as it was read; only a coding assistant's
//! status line and empty input box at its bottom are set apart ("⏵⏵ accept
//! edits on (shift+tab to cycle)").

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};

use crate::reading::{is_preformatted, CHAT_APPS, TERMINAL_APPS};

/// The window's first lines, where a tab strip, an address bar and a
/// bookmarks bar sit. Counted in lines that are not blank.
pub const TOP_LINES: usize = 6;

/// The most lines a run of chrome at the top or the bottom holds.
const RUN_LINES: usize = 40;

/// Browsers, as the capture helper lists them
/// (`BrowserPixelCapturePolicy.browserBundleIds`), and a few more.
pub const BROWSER_APPS: [&str; 23] = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "company.thebrowser.Browser",
    "company.thebrowser.dia",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "com.kagi.kagimacOS",
    "app.zen-browser.zen",
];

/// Code editors: tabs at the top, a side bar and a status bar.
pub const EDITOR_APPS: [&str; 9] = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.vscodium",
    "com.todesktop.230313mzl4w4u92",
    "com.exafunction.windsurf",
    "dev.zed.Zed",
    "com.sublimetext.4",
    "com.jetbrains.intellij",
    "com.jetbrains.pycharm",
];

const SLACK: &str = "com.tinyspeck.slackmacgap";

const MESSAGES: &str = "com.apple.MobileSMS";

/// Messages' message box, as its placeholder reads.
const MESSAGES_BOX: [&str; 5] = [
    "iMessage",
    "Text Message",
    "Text Message \u{2022} SMS",
    "Text Message \u{00b7} SMS",
    "RCS Message",
];

/// The receipt Messages shows under the last message, whole lines.
const MESSAGES_RECEIPTS: [&str; 5] = [
    "Delivered",
    "Delivered Quietly",
    "Not Delivered",
    "Sent as Text Message",
    "Read",
];

/// Words a sentence needs and a site's menu does not: a heading such as
/// "Why You Should Subscribe" is not a menu.
const SENTENCE_WORDS: [&str; 33] = [
    "i", "you", "we", "they", "he", "she", "it", "your", "our", "my", "their", "why", "how",
    "what", "when", "where", "who", "should", "can", "will", "would", "could", "is", "are", "was",
    "were", "do", "does", "did", "to", "the", "a", "an",
];

/// Close buttons on tabs, as the reader reads them. An `x` or `X` counts
/// too, after a title cut short or when two or more join titles.
const CLOSE_MARKS: [&str; 7] = [
    "\u{d7}",   // ×
    "\u{2715}", // ✕
    "\u{2716}", // ✖
    "\u{2a2f}", // ⨯
    "\u{2573}", // ╳
    "\u{24e7}", // ⓧ
    "\u{2297}", // ⊗
];

/// Marks between the parts of a window title.
const TITLE_SEPARATORS: [&str; 5] = [" - ", " \u{2014} ", " \u{2013} ", " | ", " \u{00b7} "];

/// Glyphs only a browser's toolbar shows: back, forward, reload, the
/// bookmark star, the menu.
const TOOLBAR_GLYPHS: [&str; 16] = [
    "<", ">", "\u{2039}", "\u{203a}", "\u{2190}", "\u{2192}", "\u{27f3}", "\u{21bb}", "\u{21ba}",
    "\u{2606}", "\u{2605}", "\u{22ee}", "\u{2261}", "\u{2302}", "\u{22ef}", "\u{2630}",
];

/// Words an address bar shows beside the address.
const ADDRESS_BAR_WORDS: [&str; 5] = ["Not", "Secure", "Search", "https", "http"];

/// Menu names a web app shows in a row of their own, under its title: Google
/// Docs, Sheets and Slides, Office on the web, an editor in a tab.
const MENU_NAMES: [&str; 42] = [
    "File",
    "Edit",
    "View",
    "Insert",
    "Format",
    "Tools",
    "Extensions",
    "Add-ons",
    "Help",
    "Data",
    "Slide",
    "Arrange",
    "Table",
    "Home",
    "Layout",
    "References",
    "Review",
    "Mailings",
    "Draw",
    "Design",
    "Formulas",
    "Automate",
    "Transitions",
    "Animations",
    "Window",
    "Go",
    "Run",
    "Selection",
    "Terminal",
    "History",
    "Bookmarks",
    "Profiles",
    "Tab",
    "Image",
    "Layer",
    "Select",
    "Filter",
    "Object",
    "Type",
    "Text",
    "Accessibility",
    "Page",
];

/// What a search page's tabs under the search box say.
const SEARCH_TABS: [&str; 23] = [
    "All", "AI", "Mode", "Search", "Copilot", "Images", "Videos", "Short", "videos", "News",
    "Shopping", "Maps", "Books", "Flights", "Finance", "Web", "Forums", "Places", "Products",
    "Chat", "More", "Tools", "Settings",
];

/// Buttons a site's menu ends in.
const MENU_END_BUTTONS: [&str; 6] = [
    "Share",
    "Sign in",
    "Log in",
    "Sign up",
    "Subscribe",
    "Get started",
];

/// Buttons a page or web app shows alone on a line near its top. "Get
/// started" and "Subscribe" alone are as often a page's heading.
const LONE_BUTTONS: [&str; 3] = ["Share", "Sign in", "Log in"];

/// What an empty address bar says, in lower case.
const ADDRESS_PLACEHOLDERS: [&str; 8] = [
    "search google or type a url",
    "search or type a url",
    "search or type web address",
    "search or enter address",
    "search with google or enter address",
    "search or enter website name",
    "search or enter url",
    "search or enter url...",
];

/// Top-level domains an address without a path may end in.
const ADDRESS_TLDS: [&str; 40] = [
    "com", "org", "net", "edu", "gov", "io", "dev", "app", "ai", "co", "us", "uk", "de", "fr",
    "ca", "au", "in", "jp", "nl", "es", "it", "se", "ch", "eu", "me", "tv", "info", "xyz", "so",
    "page", "site", "cloud", "tech", "ly", "gg", "fm", "to", "is", "example", "test",
];

/// Side bar and panel headings of a code editor, whole lines.
const EDITOR_HEADINGS: [&str; 17] = [
    "EXPLORER",
    "OPEN EDITORS",
    "OUTLINE",
    "TIMELINE",
    "SEARCH",
    "SOURCE CONTROL",
    "SOURCE CONTROL GRAPH",
    "RUN AND DEBUG",
    "EXTENSIONS",
    "PROBLEMS",
    "OUTPUT",
    "DEBUG CONSOLE",
    "TERMINAL",
    "PORTS",
    "COMMENTS",
    "NPM SCRIPTS",
    "CHAT",
];

/// Slack's sidebar headings, whole lines (after any count or icon before
/// them). They sit at the top of the sidebar; the ones of two words or more
/// can also be read last, under the messages.
const SLACK_HEADINGS: [&str; 19] = [
    "Home",
    "DMs",
    "Activity",
    "Later",
    "More",
    "Threads",
    "Huddles",
    "Drafts & sent",
    "Channels",
    "Direct messages",
    "Apps",
    "Add channels",
    "Add coworkers",
    "Invite people",
    "Canvases",
    "Lists",
    "Files",
    "Unreads",
    "Mentions & reactions",
];

/// The kind of window, as far as the one-frame rules care.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Family {
    Browser,
    Editor,
    Slack,
    Messages,
    Terminal,
    Other,
}

fn family(app: Option<&str>) -> Family {
    let Some(app) = app else {
        return Family::Other;
    };
    if TERMINAL_APPS.contains(&app) {
        Family::Terminal
    } else if BROWSER_APPS.contains(&app) {
        Family::Browser
    } else if EDITOR_APPS.contains(&app) || app.starts_with("com.jetbrains.") {
        Family::Editor
    } else if app == SLACK {
        Family::Slack
    } else if app == MESSAGES {
        Family::Messages
    } else {
        Family::Other
    }
}

/// Whether `app` is a browser.
#[must_use]
pub fn is_browser(app: Option<&str>) -> bool {
    family(app) == Family::Browser
}

/// Whether `app` is a code editor.
pub(crate) fn is_editor(app: Option<&str>) -> bool {
    family(app) == Family::Editor
}

/// Whether `app` is a chat app, whose window is mostly what people said.
fn is_chat(app: Option<&str>) -> bool {
    app.is_some_and(|app| CHAT_APPS.contains(&app))
}

/// What the rules know of a window besides its text, as the store keeps it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Window<'a> {
    /// The app's bundle id.
    pub app: Option<&'a str>,
    /// The window's title.
    pub title: Option<&'a str>,
    /// The page's address.
    pub url: Option<&'a str>,
}

/// The content without its chrome, and the chrome it held.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Apart<'t> {
    /// What was read, without the chrome.
    pub kept: Cow<'t, str>,
    /// The chrome, line by line in the order the lines came.
    pub moved: String,
    /// Byte offsets in `kept` where text that stood between two kept pieces
    /// moved, so they now stand side by side. None when only whole lines at
    /// the content's top and bottom moved: `kept` is then the content's own
    /// text from its first kept line to its last.
    pub holes: Vec<usize>,
}

impl Apart<'_> {
    /// Only whole lines at the content's edges moved ([`Self::holes`]).
    #[must_use]
    pub fn contiguous(&self) -> bool {
        self.holes.is_empty()
    }
}

/// The content of an old (unclassified) window without its chrome, and the
/// chrome it held. `None` when no line is chrome. `learned` adds the lines
/// the many-frame rule found ([`RepeatedChrome`]).
///
/// A line that is chrome goes whole, with the blank lines around it. In the
/// middle, only what cannot be anything else goes: an editor's status bar
/// and row of panel names, Slack's sidebar headings of two words or more
/// ("Drafts & sent"), and a learned line read into the start of a line
/// outside code, whose own words stay without the indent the sidebar left.
/// A line that only names the window, or a lone word, between two lines of
/// chrome at the top stays, and the run goes on past it.
#[must_use]
pub fn set_apart<'t>(
    content: &'t str,
    window: &Window<'_>,
    learned: Option<&RepeatedChrome>,
) -> Option<Apart<'t>> {
    let look = Look::new(window, learned);
    if look.family == Family::Terminal {
        return terminal_apart(content);
    }
    let TopRun { top, held, body } = top_run(content, &look);
    let Some((body_start, first_end)) = body else {
        // Every line is chrome, or names the window between chrome.
        if top.is_empty() {
            return None;
        }
        let mut kept = String::new();
        let mut holes = Vec::new();
        for line in &held {
            kept.push_str(line);
            kept.push('\n');
            holes.push(kept.len());
        }
        kept.truncate(kept.trim_end().len());
        holes.retain(|&hole| hole < kept.len());
        return Some(Apart {
            kept: Cow::Owned(kept),
            moved: top.join("\n"),
            holes,
        });
    };
    let (bottom, body_end) = bottom_run(content, &look, body_start, first_end);
    // The middle: what is chrome wherever it sits.
    let cuts = middle_cuts(content, body_start, body_end, &look);
    if top.is_empty() && bottom.is_empty() && cuts.is_empty() {
        return None;
    }
    let mut holes = Vec::new();
    let kept = if held.is_empty() && cuts.is_empty() {
        Cow::Borrowed(&content[body_start..body_end])
    } else {
        let mut out = String::with_capacity(body_end - body_start + 64);
        for line in &held {
            out.push_str(line);
            out.push('\n');
            holes.push(out.len());
        }
        let mut at = body_start;
        for cut in &cuts {
            out.push_str(&content[at..cut.from]);
            holes.push(out.len());
            at = cut.to;
        }
        out.push_str(&content[at..body_end]);
        Cow::Owned(out)
    };
    let mut moved: Vec<&str> = top;
    moved.extend(cuts.iter().map(|cut| cut.chrome));
    moved.extend(bottom.iter().rev());
    Some(Apart {
        kept,
        moved: moved.join("\n"),
        holes,
    })
}

/// A terminal: only a coding assistant's status line and empty input box,
/// and the box drawn around it, at the bottom.
fn terminal_apart(content: &str) -> Option<Apart<'_>> {
    let mut moved: Vec<&str> = Vec::new();
    let mut end = None;
    for (start, line_end) in NonBlankBack::new(content) {
        let line = content[start..line_end].trim();
        if moved.len() < 12 && is_assistant_chrome(line) {
            moved.push(line);
            continue;
        }
        end = Some(line_end);
        break;
    }
    // Only box lines and the status line: nothing that was said.
    if !moved
        .iter()
        .any(|line| line.chars().any(char::is_alphanumeric))
    {
        return None;
    }
    moved.reverse();
    Some(Apart {
        kept: Cow::Borrowed(&content[..end.unwrap_or(0)]),
        moved: moved.join("\n"),
        holes: Vec::new(),
    })
}

/// A coding assistant's own lines at a terminal's bottom: its status line,
/// its hints, its empty input box (">"), and the box drawn around it.
fn is_assistant_chrome(line: &str) -> bool {
    const HINTS: [&str; 9] = [
        "accept edits on",
        "auto-accept edits",
        "bypass permissions on",
        "plan mode on",
        "? for shortcuts",
        "esc to interrupt",
        "shift+tab to cycle",
        "ctrl+t to",
        "ctrl+r to expand",
    ];
    let bare =
        line.trim_matches(|ch: char| ch.is_whitespace() || ('\u{2500}'..='\u{257F}').contains(&ch));
    bare.is_empty()
        || bare == ">"
        || bare.starts_with("\u{23f5}\u{23f5}")
        || HINTS.iter().any(|hint| bare.to_lowercase().contains(hint))
}

/// The run of chrome at the content's top.
struct TopRun<'t> {
    /// The lines that are chrome.
    top: Vec<&'t str>,
    /// Lines the run went on past, which stay.
    held: Vec<&'t str>,
    /// The byte range of the first line that is not chrome, if any.
    body: Option<(usize, usize)>,
}

/// The run at the top. Below the window's own name read off the screen,
/// only one-frame chrome counts: a learned line there is the document's own
/// (a table's header under its name).
fn top_run<'t>(content: &'t str, look: &Look<'_>) -> TopRun<'t> {
    let mut run = TopRun {
        top: Vec::new(),
        held: Vec::new(),
        body: None,
    };
    let mut index = 0usize;
    let mut unknown_held = false;
    let mut past_name = false;
    let mut lines = NonBlank::new(content).peekable();
    while let Some((start, end)) = lines.next() {
        let line = content[start..end].trim();
        if index < RUN_LINES {
            if look.top(line, index, !past_name) {
                past_name |= look.title.is_some_and(|title| is_title_bar(line, title));
                run.top.push(line);
                index += 1;
                continue;
            }
            if let Some(&(next_start, next_end)) = lines.peek() {
                let next = content[next_start..next_end].trim();
                if look.strip_over_two_lines(line, next, index) {
                    run.top.push(line);
                    run.top.push(next);
                    lines.next();
                    index += 2;
                    continue;
                }
                // A line the run goes on past, keeping it: the window's own
                // name, a single word (a sidebar's section label), or one
                // line the rules do not know above a line of one-frame chrome
                // (in a browser, the first line or one between lines of
                // chrome near the top, such as a bookmarks bar of folders; in
                // an editor, its title bar read first, "tax.rs —
                // trailhead-shop").
                let names = look.names_window(line);
                let single_word = line.split_whitespace().count() == 1;
                let unknown = !unknown_held
                    && match look.family {
                        Family::Browser => index < TOP_LINES && (index == 0 || !run.top.is_empty()),
                        Family::Editor => index == 0 && is_title_bar_line(line),
                        _ => false,
                    };
                let learned_counts = !past_name && !names && single_word;
                if (names || single_word || unknown) && look.top(next, index + 1, learned_counts) {
                    unknown_held |= !names && !single_word;
                    past_name |= names;
                    run.held.push(line);
                    index += 1;
                    continue;
                }
            }
        }
        run.body = Some((start, end));
        break;
    }
    run
}

/// The run of chrome at the content's bottom, never past its first line
/// that is not chrome (which starts at `body_start` and ends at
/// `first_end`): its lines from the bottom up, and where what stays ends.
fn bottom_run<'t>(
    content: &'t str,
    look: &Look<'_>,
    body_start: usize,
    first_end: usize,
) -> (Vec<&'t str>, usize) {
    let mut bottom: Vec<&str> = Vec::new();
    let mut receipts = 0usize;
    for (start, end) in NonBlankBack::new(content) {
        if start <= body_start {
            break;
        }
        let line = content[start..end].trim();
        if bottom.len() < RUN_LINES && look.bottom(line, &mut receipts) {
            bottom.push(line);
            continue;
        }
        return (bottom, end);
    }
    (bottom, first_end)
}

/// A piece of a line, or a whole line with its line break, that moves out of
/// the middle of the content.
struct Cut<'t> {
    /// Where the piece starts in the content.
    from: usize,
    /// Where what stays goes on.
    to: usize,
    /// What moves.
    chrome: &'t str,
}

/// What moves out of the content's middle, between its first and last kept
/// lines (`from..to`): whole lines that are chrome wherever they sit, and
/// learned lines read into the start of a line outside code.
fn middle_cuts<'t>(content: &'t str, from: usize, to: usize, look: &Look<'_>) -> Vec<Cut<'t>> {
    let anywhere = matches!(look.family, Family::Slack | Family::Editor);
    let mut cuts = Vec::new();
    let Some(learned) = look.learned else {
        if !anywhere {
            return cuts;
        }
        // One pass over the lines, with no allocation: a list row reads a
        // whole window this way.
        let mut at = from;
        for line in content[from..to].split('\n') {
            let end = at + line.len();
            if end < to && look.anywhere(line) {
                cuts.push(Cut {
                    from: at,
                    to: end + 1,
                    chrome: line.trim(),
                });
            }
            at = end + 1;
        }
        return cuts;
    };
    let region = &content[from..to];
    let mut block_start = from;
    for block in region.split("\n\n") {
        let lines: Vec<&str> = block.split('\n').collect();
        let code = is_preformatted(&lines);
        let mut at = block_start;
        for line in &lines {
            let end = at + line.len();
            if anywhere && end < to && look.anywhere(line) {
                cuts.push(Cut {
                    from: at,
                    to: end + 1,
                    chrome: line.trim(),
                });
            } else if let Some((chrome, words)) =
                (!code).then(|| learned.split_start(line)).flatten()
            {
                let words_offset = words.as_ptr() as usize - line.as_ptr() as usize;
                cuts.push(Cut {
                    from: at,
                    to: at + words_offset,
                    chrome,
                });
            }
            at = end + 1;
        }
        block_start += block.len() + 2;
    }
    cuts
}

/// The non-blank lines of a text, from its start: each line's byte range,
/// without its line break.
struct NonBlank<'t> {
    text: &'t str,
    at: usize,
}

impl<'t> NonBlank<'t> {
    fn new(text: &'t str) -> Self {
        Self { text, at: 0 }
    }
}

impl Iterator for NonBlank<'_> {
    type Item = (usize, usize);

    fn next(&mut self) -> Option<(usize, usize)> {
        while self.at <= self.text.len() {
            let start = self.at;
            let end = self.text[start..]
                .find('\n')
                .map_or(self.text.len(), |found| start + found);
            self.at = end + 1;
            if !self.text[start..end].trim().is_empty() {
                return Some((start, end));
            }
        }
        None
    }
}

/// The non-blank lines of a text, from its end.
struct NonBlankBack<'t> {
    text: &'t str,
    /// The end of the next line to look at; none once the start is passed.
    at: Option<usize>,
}

impl<'t> NonBlankBack<'t> {
    fn new(text: &'t str) -> Self {
        Self {
            text,
            at: Some(text.len()),
        }
    }
}

impl Iterator for NonBlankBack<'_> {
    type Item = (usize, usize);

    fn next(&mut self) -> Option<(usize, usize)> {
        while let Some(end) = self.at {
            let start = self.text[..end].rfind('\n').map_or(0, |found| found + 1);
            self.at = start.checked_sub(1);
            if !self.text[start..end].trim().is_empty() {
                return Some((start, end));
            }
        }
        None
    }
}

/// The rules for one window.
struct Look<'w> {
    family: Family,
    chat: bool,
    /// The start of the window's title ([`title_start`]).
    title: Option<&'w str>,
    /// The whole title, trimmed.
    full_title: Option<&'w str>,
    site: Option<Site>,
    learned: Option<&'w RepeatedChrome>,
}

impl<'w> Look<'w> {
    fn new(window: &Window<'w>, learned: Option<&'w RepeatedChrome>) -> Self {
        let family = family(window.app);
        Self {
            family,
            chat: is_chat(window.app),
            title: window.title.and_then(title_start),
            full_title: window
                .title
                .map(str::trim)
                .filter(|title| !title.is_empty()),
            site: Site::of(family, window),
            learned: learned.filter(|learned| !learned.is_empty()),
        }
    }

    fn learned_whole(&self, line: &str) -> bool {
        self.learned.is_some_and(|learned| learned.contains(line))
    }

    /// Whether `line` names the window: its title, or the title's start.
    fn names_window(&self, line: &str) -> bool {
        [self.title, self.full_title]
            .into_iter()
            .flatten()
            .any(|title| same_words(line, title))
    }

    /// Whether `line`, the `index`-th line of the run at the top, is chrome:
    /// by the one-frame rules, or, with `learned`, a learned line. A line
    /// that names the window is never a site's navigation: a settings pane's
    /// heading is also its name in the side bar.
    fn top(&self, line: &str, index: usize, learned: bool) -> bool {
        let site = self.site.is_some_and(|site| site.is_nav(line)) && !self.names_window(line);
        let learned = learned && self.learned_whole(line);
        match self.family {
            Family::Browser => {
                (index < TOP_LINES && self.browser_top(line, index)) || site || learned
            }
            Family::Editor => {
                (index < TOP_LINES && is_tab_strip(line, self.title))
                    || is_editor_chrome(line)
                    || learned
            }
            Family::Slack => is_slack_top(line, index) || learned,
            Family::Messages => learned,
            Family::Other => site || learned,
            Family::Terminal => false,
        }
    }

    fn browser_top(&self, line: &str, index: usize) -> bool {
        is_tab_strip(line, self.title)
            || is_strip_continuation(line)
            || is_address_bar(line)
            || is_bookmarks_bar(line)
            || (index < 3 && is_toolbar(line))
            || is_menu_row(line)
            || is_search_tabs(line)
            || is_lone_button(line)
            || is_site_menu(line)
            || self.title.is_some_and(|title| is_title_bar(line, title))
    }

    /// Whether `line` is chrome wherever it sits: an editor's status bar or
    /// row of panel names, Slack's sidebar headings of two words or more.
    /// Most lines are passed over by their length or letters alone.
    fn anywhere(&self, line: &str) -> bool {
        let line = line.trim();
        if line.is_empty() {
            return false;
        }
        match self.family {
            Family::Editor => {
                (line.contains("Ln ") && is_status_bar(without_lead(line)))
                    || (line.len() <= 120
                        && line.ends_with(|ch: char| ch.is_ascii_uppercase())
                        && !line.bytes().any(|b| b.is_ascii_lowercase())
                        && is_panel_row(without_lead(line)))
            }
            Family::Slack => line.len() <= 40 && is_slack_long_heading(line),
            _ => false,
        }
    }

    /// A browser's tab strip read over two lines, near the top: each line
    /// holds a close button, and together they read as a strip.
    fn strip_over_two_lines(&self, line: &str, next: &str, index: usize) -> bool {
        matches!(self.family, Family::Browser | Family::Editor)
            && index + 1 < TOP_LINES
            && has_close_mark(line)
            && has_close_mark(next)
            && !is_tab_strip(line, self.title)
            && is_tab_strip(&format!("{line} {next}"), self.title)
    }

    /// Whether `line`, in the run at the bottom, is chrome. Messages shows
    /// one receipt, under the last message.
    fn bottom(&self, line: &str, receipts: &mut usize) -> bool {
        match self.family {
            Family::Editor => is_editor_bottom(line) || self.learned_whole(line),
            Family::Slack => {
                is_slack_message_box(line, self.full_title) || is_slack_long_heading(line)
            }
            Family::Messages => {
                let bare = without_lead(line);
                if MESSAGES_BOX.contains(&bare) {
                    return true;
                }
                if *receipts == 0 && is_receipt(bare) {
                    *receipts += 1;
                    return true;
                }
                false
            }
            Family::Browser | Family::Other => !self.chat && self.learned_whole(line),
            Family::Terminal => false,
        }
    }
}

/// The start of a window's title as a tab or a title bar shows it: its
/// first part (before " - ", " · ", " | " …) when that is two words or
/// eight characters, else the whole title. `None` for a title too short to
/// tell apart.
fn title_start(title: &str) -> Option<&str> {
    let title = title.trim();
    let first = TITLE_SEPARATORS
        .iter()
        .filter_map(|separator| title.find(separator))
        .min()
        .map_or(title, |at| title[..at].trim());
    let telling = |text: &str| text.split_whitespace().count() >= 2 || text.chars().count() >= 8;
    if telling(first) {
        Some(first)
    } else if telling(title) {
        Some(title)
    } else {
        None
    }
}

/// The same words in the same order, whatever the spacing and case.
fn same_words(a: &str, b: &str) -> bool {
    let mut a = a.split_whitespace();
    let mut b = b.split_whitespace();
    loop {
        match (a.next(), b.next()) {
            (None, None) => return true,
            (Some(x), Some(y)) if x.to_lowercase() == y.to_lowercase() => {}
            _ => return false,
        }
    }
}

// ---------------------------------------------------------------------------
// One-frame rules
// ---------------------------------------------------------------------------

fn letters(token: &str) -> usize {
    token.chars().filter(|ch| ch.is_alphabetic()).count()
}

/// A tab title the strip cut short: it ends in an ellipsis.
fn is_cut_short(token: &str) -> bool {
    token.ends_with('\u{2026}') || token.ends_with("...")
}

/// A number alone: a size, a price, an operand. A close button never
/// follows one in a tab strip ("1920 × 1080").
fn is_bare_number(token: &str) -> bool {
    token.chars().any(|ch| ch.is_ascii_digit())
        && token
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, ',' | '.' | '%' | '$'))
}

/// A favicon as the reader reads it: one capital letter (not "A" or "I",
/// which are words), a symbol, or a day or count of one or two digits.
fn is_favicon(token: &str) -> bool {
    let mut chars = token.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if chars.next().is_none() {
        if first.is_ascii_uppercase() {
            return first != 'A' && first != 'I';
        }
        return !first.is_alphanumeric()
            && !matches!(
                first,
                '-' | '\u{00b7}'
                    | '|'
                    | ':'
                    | ';'
                    | ','
                    | '.'
                    | '('
                    | ')'
                    | '"'
                    | '\''
                    | '&'
                    | '/'
                    | '\\'
                    | '+'
                    | '='
                    | '\u{2014}'
                    | '\u{2013}'
                    | '\u{2026}'
            )
            && !CLOSE_MARKS.contains(&token);
    }
    token.len() <= 2 && token.chars().all(|ch| ch.is_ascii_digit())
}

/// A line of tab titles, near the top of a browser or an editor. One of:
///
/// - two close buttons or more, between titles of which two read like tab
///   titles (two words or more, a file name, cut short, or led by a
///   favicon);
/// - one close button, and a title cut short or a new-tab `+` at the end;
/// - one close button among three titles led by favicons, or after the
///   favicons of two pinned tabs at the start;
/// - the window's own title among two more titles, or beside a close button
///   or another favicon-led title.
///
/// A close button is `×` and its kin, or `x`/`X` after a title cut short or
/// when two or more of them join titles; it never counts after a number
/// alone. A line with `=` is a formula. "T N 27 Trailhead - Sched × ✓ Q4
/// planning - Goo # launch-plan (Chan…" is a tab strip; "1920 × 1080",
/// "Width × Height × Depth" and "Area = length × width × height" are not.
fn is_tab_strip(line: &str, title: Option<&str>) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.len() < 3 || tokens.contains(&"=") {
        return false;
    }
    if StripShape::of(&tokens).evidence() {
        return true;
    }
    title.is_some_and(|title| holds_title_among_others(line, title))
}

/// A window's title bar as the reader read it: a name, a dash, a project.
fn is_title_bar_line(line: &str) -> bool {
    line.contains(" \u{2014} ") || line.contains(" - ")
}

/// Whether `line` holds a tab's close button.
fn has_close_mark(line: &str) -> bool {
    line.split_whitespace()
        .any(|token| CLOSE_MARKS.contains(&token) || matches!(token, "x" | "X"))
}

/// The rest of a tab strip that wrapped onto a second line: it starts with
/// the close button of the tab cut at the line's end, and holds another or
/// ends in the new-tab `+`.
fn is_strip_continuation(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens.len() >= 3
        && CLOSE_MARKS.contains(&tokens[0])
        && (tokens[1..].iter().any(|token| CLOSE_MARKS.contains(token))
            || tokens.last() == Some(&"+"))
}

/// What a line of tokens shows of a tab strip.
#[derive(Debug, Default)]
struct StripShape {
    closes: usize,
    cut_short: usize,
    new_tab: bool,
    /// Parts between close buttons with two letters or more.
    titles: usize,
    /// …of which read like tab titles.
    tabby: usize,
    /// Favicons followed by a word: the start of a tab.
    favicon_led: usize,
    /// Favicons in a row at the line's start: pinned tabs.
    pinned: usize,
}

impl StripShape {
    fn of(tokens: &[&str]) -> Self {
        let x_candidates = tokens
            .iter()
            .enumerate()
            .filter(|(at, token)| {
                matches!(**token, "x" | "X") && *at > 0 && !is_bare_number(tokens[at - 1])
            })
            .count();
        let mut shape = Self {
            new_tab: tokens.last() == Some(&"+"),
            pinned: tokens.iter().take_while(|token| is_favicon(token)).count(),
            ..Self::default()
        };
        let mut part: Vec<&str> = Vec::new();
        for (at, token) in tokens.iter().enumerate() {
            let after_title = at > 0
                && !is_bare_number(tokens[at - 1])
                && part.iter().map(|word| letters(word)).sum::<usize>() >= 2;
            let close = after_title
                && (CLOSE_MARKS.contains(token)
                    || (matches!(*token, "x" | "X")
                        && (is_cut_short(tokens[at - 1]) || x_candidates >= 2)));
            if close {
                shape.closes += 1;
                shape.count_part(&part);
                part.clear();
                continue;
            }
            if is_cut_short(token) {
                shape.cut_short += 1;
            }
            if is_favicon(token)
                && tokens
                    .get(at + 1)
                    .is_some_and(|next| letters(next) >= 2 || is_cut_short(next))
            {
                shape.favicon_led += 1;
            }
            part.push(token);
        }
        shape.count_part(&part);
        shape
    }

    fn count_part(&mut self, part: &[&str]) {
        if part.iter().map(|word| letters(word)).sum::<usize>() < 2 {
            return;
        }
        self.titles += 1;
        let lettered = part.iter().filter(|word| letters(word) > 0).count();
        let tabby = lettered >= 2
            || part.iter().any(|word| is_cut_short(word))
            || part
                .iter()
                .any(|word| word.contains('.') && letters(word) >= 2)
            || part.first().is_some_and(|word| is_favicon(word));
        self.tabby += usize::from(tabby);
    }

    fn evidence(&self) -> bool {
        (self.closes >= 2 && self.tabby >= 2)
            || (self.closes >= 1 && (self.cut_short >= 1 || self.new_tab) && self.titles >= 2)
            || (self.closes >= 1 && self.favicon_led >= 3)
            || (self.closes >= 1 && self.pinned >= 2 && self.titles >= 2)
    }
}

/// Whether `line` holds the window's title (as a tab shows its start)
/// beside more tabs: a close button, another favicon-led title, two more
/// parts joined the way titles are, or other titles apart by wide gaps.
fn holds_title_among_others(line: &str, title: &str) -> bool {
    if is_wide_gap_tabs(line, title) {
        return true;
    }
    let Some(at) = line.find(title) else {
        return false;
    };
    let others = format!("{} {}", &line[..at], &line[at + title.len()..]);
    let tokens: Vec<&str> = others.split_whitespace().collect();
    if tokens.is_empty() {
        return false;
    }
    let close = tokens.iter().enumerate().any(|(at, token)| {
        CLOSE_MARKS.contains(token)
            || (matches!(*token, "x" | "X") && at > 0 && !is_bare_number(tokens[at - 1]))
    });
    let favicon_led = tokens
        .windows(2)
        .any(|pair| is_favicon(pair[0]) && letters(pair[1]) >= 2);
    let joins = TITLE_SEPARATORS
        .iter()
        .map(|separator| others.matches(separator).count())
        .sum::<usize>();
    close || favicon_led || joins >= 2
}

/// Safari's tab bar: titles apart by wide gaps, the window's own among them.
fn is_wide_gap_tabs(line: &str, title: &str) -> bool {
    let parts: Vec<&str> = line
        .split("   ")
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect();
    parts.len() >= 2 && parts.iter().any(|part| same_words(part, title))
}

/// An address, as an address bar shows it: with a scheme, a host with a
/// path, a host that ends in a common top-level domain, or `localhost`.
fn is_address(token: &str) -> bool {
    if token.contains('@') {
        return false;
    }
    let lower = token.to_ascii_lowercase();
    let (rest, scheme) = match lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
    {
        Some(rest) => (rest, true),
        None => (lower.as_str(), false),
    };
    let (host, path) = match rest.find(['/', '?', '#']) {
        Some(at) => (&rest[..at], true),
        None => (rest, false),
    };
    let host = host.split(':').next().unwrap_or_default();
    if host == "localhost" {
        return true;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2
        || labels.iter().any(|label| {
            label.is_empty()
                || !label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return false;
    }
    let tld = labels[labels.len() - 1];
    if tld.len() < 2 || !tld.bytes().all(|b| b.is_ascii_alphabetic()) {
        return false;
    }
    scheme || path || ADDRESS_TLDS.contains(&tld)
}

/// A toolbar glyph or a button read as one or two characters.
fn is_decoration(token: &str) -> bool {
    token.chars().count() <= 2 || !token.chars().any(char::is_alphanumeric)
}

/// An address bar: an address and nothing but toolbar glyphs, short
/// buttons and words like "Not Secure"; or an empty bar's placeholder.
fn is_address_bar(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.iter().any(|token| is_address(token)) {
        return tokens.iter().all(|token| {
            is_address(token) || is_decoration(token) || ADDRESS_BAR_WORDS.contains(token)
        });
    }
    // A placeholder, with the icons on either side of it left out.
    let start = tokens
        .iter()
        .position(|token| !is_icon_or_glyph(token))
        .unwrap_or(tokens.len());
    let end = tokens
        .iter()
        .rposition(|token| !is_icon_or_glyph(token))
        .map_or(start, |at| at + 1);
    if start >= end {
        return false;
    }
    let said = tokens[start..end].join(" ").to_lowercase();
    ADDRESS_PLACEHOLDERS.contains(&said.as_str())
}

/// A search or toolbar icon read as a glyph or a single letter.
fn is_icon_or_glyph(token: &str) -> bool {
    token.chars().count() == 1 || !token.chars().any(char::is_alphanumeric)
}

/// A bookmarks or favorites bar: it ends in "All Bookmarks" or "Other
/// Bookmarks" or "Reading List", or shows the empty bar's hint.
fn is_bookmarks_bar(line: &str) -> bool {
    let lower = line.to_lowercase();
    let lower = lower.trim_end_matches(|ch: char| !ch.is_alphanumeric());
    [
        "all bookmarks",
        "other bookmarks",
        "mobile bookmarks",
        "reading list",
    ]
    .iter()
    .any(|end| lower.ends_with(end))
        || lower.contains("place your bookmarks here")
}

/// A web app's row of menus: four or more menu names and nothing else, with
/// File, Edit or View among them. "File Edit View Insert Format Tools
/// Extensions Help" is one; "Edit the file, then view it" is not.
fn is_menu_row(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens.len() >= 4
        && tokens.iter().all(|token| MENU_NAMES.contains(token))
        && tokens
            .iter()
            .any(|token| matches!(*token, "File" | "Edit" | "View"))
}

/// A search page's tabs: four or more tab names and nothing else, starting
/// with All, AI Mode or the engine's own tab, and naming Images, Videos or
/// News. "All Images Videos News Shopping Short videos More Tools" is one;
/// "All images are free to use" is not.
fn is_search_tabs(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens.len() >= 4
        && tokens.iter().all(|token| SEARCH_TABS.contains(token))
        && tokens.contains(&"All")
        && tokens
            .iter()
            .any(|token| matches!(*token, "Images" | "Videos" | "News"))
}

/// A button alone on its line, as a web app's title row shows it: "Share",
/// "Sign in".
fn is_lone_button(line: &str) -> bool {
    LONE_BUTTONS.contains(&without_lead(line))
}

/// A site's menu across its header, read as one line and ending in its
/// sign-in or subscribe button: "Dev Notes Articles Topics About
/// Subscribe", "Pricing Docs Blog Sign in Get started". Three or more words
/// before the button, at least three in four of them capitalized, no
/// sentence punctuation and no word only a sentence needs: "How to Sign in"
/// and "Why You Should Subscribe" are headings, not menus.
fn is_site_menu(line: &str) -> bool {
    if line.contains(['.', ',', '?', '!', ':', ';']) {
        return false;
    }
    let Some(before) = MENU_END_BUTTONS
        .iter()
        .find_map(|button| line.strip_suffix(button))
        .filter(|before| before.ends_with(char::is_whitespace))
    else {
        return false;
    };
    let words: Vec<&str> = before
        .split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .collect();
    if words.len() < 3
        || words
            .iter()
            .any(|word| SENTENCE_WORDS.contains(&word.to_lowercase().as_str()))
    {
        return false;
    }
    let capitalized = words
        .iter()
        .filter(|word| word.chars().next().is_some_and(char::is_uppercase))
        .count();
    capitalized * 4 >= words.len() * 3
}

/// A web app's title bar: the window's own name and nothing but toolbar
/// glyphs beside it ("Q4 planning ☆").
fn is_title_bar(line: &str, title: &str) -> bool {
    let glyph = |token: &&str| !token.chars().any(char::is_alphanumeric);
    let tokens: Vec<&str> = line.split_whitespace().collect();
    let words: Vec<&str> = tokens
        .iter()
        .copied()
        .filter(|token| !glyph(token))
        .collect();
    words.len() < tokens.len() && same_words(&words.join(" "), title)
}

/// Toolbar remnants: buttons alone on a line (a new-tab `+`, `< > C ☆`):
/// one browser glyph or more, the rest glyphs or tokens of one or two
/// characters, and no sign of a formula.
fn is_toolbar(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens == ["+"] {
        return true;
    }
    tokens.iter().any(|token| TOOLBAR_GLYPHS.contains(token))
        && tokens.iter().all(|token| {
            TOOLBAR_GLYPHS.contains(token)
                || (token.chars().count() <= 2
                    && !token.contains(['=', '+', '-', '\u{2212}', '\u{d7}', '^', '/']))
        })
}

/// A line without the icon, count or bullet the reader put before it. A
/// Markdown lead (`#`, `##`, `-`, `*`, `>`, `1.`) is the text's own and
/// stays.
fn without_lead(line: &str) -> &str {
    let mut rest = line;
    loop {
        let trimmed = rest.trim_start();
        let Some(token) = trimmed.split_whitespace().next() else {
            return trimmed;
        };
        let markdown = token.chars().all(|ch| ch == '#')
            || matches!(token, "-" | "*" | "+" | ">")
            || token.strip_suffix(['.', ')']).is_some_and(|number| {
                !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit())
            });
        let lead = !markdown
            && (token.chars().count() <= 2 && !token.chars().any(char::is_alphabetic)
                || token.chars().count() == 1);
        if lead && trimmed.len() > token.len() {
            rest = &trimmed[token.len()..];
        } else {
            return trimmed;
        }
    }
}

/// An editor's side bar heading, panel row, status bar or breadcrumb.
fn is_editor_chrome(line: &str) -> bool {
    let line = without_lead(line);
    EDITOR_HEADINGS.contains(&line)
        || is_panel_row(line)
        || is_status_bar(line)
        || is_breadcrumb(line)
}

/// What an editor shows at its bottom: side bar headings read last, the
/// panel's row of names, the status bar.
fn is_editor_bottom(line: &str) -> bool {
    let line = without_lead(line);
    EDITOR_HEADINGS.contains(&line) || is_panel_row(line) || is_status_bar(line)
}

/// A row of panel names and nothing else: "PROBLEMS OUTPUT DEBUG CONSOLE
/// TERMINAL PORTS".
fn is_panel_row(line: &str) -> bool {
    let mut rest = line.trim();
    let mut names = 0usize;
    'outer: while !rest.is_empty() {
        for heading in EDITOR_HEADINGS.iter().rev() {
            if let Some(after) = rest.strip_prefix(heading) {
                if after.is_empty() || after.starts_with(char::is_whitespace) {
                    rest = after.trim_start();
                    names += 1;
                    continue 'outer;
                }
            }
        }
        return false;
    }
    names >= 2
}

/// An editor's status bar: it holds "Ln 14, Col 37".
fn is_status_bar(line: &str) -> bool {
    let bytes = line.as_bytes();
    let mut from = 0;
    while let Some(found) = line[from..].find("Ln ") {
        let at = from + found + 3;
        let digits = bytes[at..]
            .iter()
            .take_while(|b| b.is_ascii_digit())
            .count();
        if digits > 0 && line[at + digits..].starts_with(", Col ") {
            let after = at + digits + 6;
            if bytes.get(after).is_some_and(u8::is_ascii_digit) {
                return true;
            }
        }
        from = at;
    }
    false
}

/// A breadcrumb: three or more names joined by " > " or " › ", each with a
/// letter, at most four words and no punctuation but `-_./@`, that name a
/// path: every name one word, or one of them a file name. So code such as
/// `if a > b > c { … }` and steps such as "System Settings > Privacy >
/// Accessibility" are not one.
fn is_breadcrumb(line: &str) -> bool {
    let parts: Vec<&str> = line
        .split(" > ")
        .flat_map(|part| part.split(" \u{203a} "))
        .map(str::trim)
        .collect();
    parts.len() >= 3
        && parts.iter().all(|part| {
            part.chars().any(char::is_alphabetic)
                && part.chars().count() <= 48
                && part.split_whitespace().count() <= 4
                && part
                    .chars()
                    .all(|ch| ch.is_alphanumeric() || ch.is_whitespace() || "-_./@".contains(ch))
        })
        && (parts
            .iter()
            .all(|part| part.split_whitespace().count() == 1)
            || parts.iter().any(|part| is_file_name(part)))
}

/// A file name: one word with a short extension ("tax.rs", "README.md").
fn is_file_name(part: &str) -> bool {
    part.split_whitespace().count() == 1
        && part.rsplit_once('.').is_some_and(|(name, ext)| {
            !name.is_empty()
                && (1..=5).contains(&ext.len())
                && ext.chars().all(char::is_alphanumeric)
        })
}

/// What Slack shows at its top: a sidebar heading, or the top bar with the
/// workspace's search box ("Northwind Studio > Q Search Northwind Studio").
fn is_slack_top(line: &str, index: usize) -> bool {
    let bare = without_lead(line);
    if SLACK_HEADINGS.contains(&bare) {
        return true;
    }
    let tokens: Vec<&str> = line.split_whitespace().collect();
    index < 2
        && tokens.contains(&"Search")
        && tokens.len() <= 9
        && !tokens
            .iter()
            .any(|token| token.chars().next().is_some_and(char::is_lowercase))
}

/// Slack's sidebar headings of two words or more ([`SLACK_HEADINGS`]).
const SLACK_LONG_HEADINGS: [&str; 6] = [
    "Drafts & sent",
    "Direct messages",
    "Add channels",
    "Add coworkers",
    "Invite people",
    "Mentions & reactions",
];

/// A Slack sidebar heading of two words or more, which can be read last
/// and anywhere: "Drafts & sent", "4 Direct messages".
fn is_slack_long_heading(line: &str) -> bool {
    SLACK_LONG_HEADINGS
        .iter()
        .any(|heading| line.ends_with(heading) && without_lead(line) == *heading)
}

/// Slack's message box: "Message #launch-plan", "Message Maya Chen", or
/// "Message" and the channel or person the title names. "Message me later"
/// and "Message received" are messages.
fn is_slack_message_box(line: &str, title: Option<&str>) -> bool {
    let Some(to) = without_lead(line).strip_prefix("Message ") else {
        return false;
    };
    let to = to.trim();
    let words: Vec<&str> = to.split_whitespace().collect();
    if words.is_empty() || words.len() > 4 || to.ends_with(['.', '?', '!']) {
        return false;
    }
    let named = title.is_some_and(|title| {
        let name = title
            .split(" (Channel)")
            .next()
            .and_then(|name| name.split(" (DM)").next())
            .unwrap_or_default()
            .trim()
            .trim_start_matches('#');
        !name.is_empty() && to.trim_start_matches('#') == name
    });
    named
        || (words.len() == 1 && to.starts_with('#') && to.len() > 1)
        || words
            .iter()
            .all(|word| word.chars().next().is_some_and(char::is_uppercase))
}

/// A receipt under Messages' last message: "Delivered", "Read", "Read 2:21
/// PM", "Read Yesterday".
fn is_receipt(bare: &str) -> bool {
    if MESSAGES_RECEIPTS.contains(&bare) {
        return true;
    }
    bare.strip_prefix("Read ").is_some_and(|when| {
        let tokens: Vec<&str> = when.split_whitespace().collect();
        (1..=3).contains(&tokens.len())
            && tokens.iter().all(|token| {
                let token = token.trim_end_matches(',');
                matches!(token, "AM" | "PM" | "Today" | "Yesterday")
                    || [
                        "Monday",
                        "Tuesday",
                        "Wednesday",
                        "Thursday",
                        "Friday",
                        "Saturday",
                        "Sunday",
                    ]
                    .contains(&token)
                    || (token.contains(':')
                        && token.chars().all(|ch| ch.is_ascii_digit() || ch == ':'))
            })
    })
}

// ---------------------------------------------------------------------------
// Web apps and apps with a side bar
// ---------------------------------------------------------------------------

/// A web app, or an app with a side bar, whose navigation the reader knows
/// by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Site {
    Gmail,
    Calendar,
    GitHub,
    YouTube,
    LinkedIn,
    Notes,
    Finder,
    SystemSettings,
}

const GMAIL_NAV: [&str; 26] = [
    "Gmail",
    "Compose",
    "Inbox",
    "Starred",
    "Snoozed",
    "Important",
    "Sent",
    "Drafts",
    "Scheduled",
    "All Mail",
    "Spam",
    "Trash",
    "Categories",
    "Social",
    "Updates",
    "Forums",
    "Promotions",
    "Purchases",
    "More",
    "Less",
    "Labels",
    "Manage labels",
    "Create new label",
    "Mail",
    "Chat",
    "Meet",
];

const CALENDAR_NAV: [&str; 12] = [
    "Calendar",
    "Today",
    "Day",
    "Week",
    "Month",
    "Year",
    "Schedule",
    "4 days",
    "Create",
    "My calendars",
    "Other calendars",
    "Booking pages",
];

const GITHUB_TABS: [&str; 22] = [
    "Code",
    "Issues",
    "Pull requests",
    "Actions",
    "Projects",
    "Wiki",
    "Security",
    "Insights",
    "Settings",
    "Discussions",
    "Conversation",
    "Commits",
    "Checks",
    "Files changed",
    "Overview",
    "Repositories",
    "Packages",
    "Stars",
    "Codespaces",
    "Marketplace",
    "Explore",
    "Models",
];

const YOUTUBE_NAV: [&str; 16] = [
    "Home",
    "Shorts",
    "Subscriptions",
    "You",
    "History",
    "Playlists",
    "Your videos",
    "Watch later",
    "Liked videos",
    "Explore",
    "Trending",
    "Music",
    "Gaming",
    "Sports",
    "Library",
    "Search",
];

const LINKEDIN_NAV: [&str; 11] = [
    "Home",
    "My Network",
    "Jobs",
    "Messaging",
    "Notifications",
    "Me",
    "For Business",
    "Try Premium",
    "Learning",
    "in",
    "Search",
];

const NOTES_NAV: [&str; 16] = [
    "iCloud",
    "All iCloud",
    "Notes",
    "Quick Notes",
    "Shared",
    "Recently Deleted",
    "Folders",
    "On My Mac",
    "Tags",
    "New Folder",
    "Pinned",
    "Today",
    "Yesterday",
    "Previous 7 Days",
    "Previous 30 Days",
    "All Notes",
];

const FINDER_NAV: [&str; 22] = [
    "Favorites",
    "AirDrop",
    "Recents",
    "Applications",
    "Desktop",
    "Documents",
    "Downloads",
    "iCloud",
    "iCloud Drive",
    "Shared",
    "Locations",
    "Network",
    "Tags",
    "Red",
    "Orange",
    "Yellow",
    "Green",
    "Blue",
    "Purple",
    "Gray",
    "All Tags\u{2026}",
    "Macintosh HD",
];

const SETTINGS_NAV: [&str; 46] = [
    "Search",
    "Apple Account",
    "Family",
    "Wi-Fi",
    "Bluetooth",
    "Network",
    "VPN",
    "Battery",
    "Energy",
    "General",
    "Accessibility",
    "Appearance",
    "Apple Intelligence & Siri",
    "Siri",
    "Control Center",
    "Desktop & Dock",
    "Displays",
    "Screen Saver",
    "Spotlight",
    "Wallpaper",
    "Notifications",
    "Sound",
    "Focus",
    "Screen Time",
    "Lock Screen",
    "Privacy & Security",
    "Login Password",
    "Touch ID & Password",
    "Users & Groups",
    "Internet Accounts",
    "Game Center",
    "iCloud",
    "Wallet & Apple Pay",
    "Keyboard",
    "Mouse",
    "Trackpad",
    "Printers & Scanners",
    "Passwords",
    "Software Update",
    "Storage",
    "AirDrop & Handoff",
    "Login Items",
    "Language & Region",
    "Date & Time",
    "Sharing",
    "Time Machine",
];

impl Site {
    fn of(family: Family, window: &Window<'_>) -> Option<Self> {
        if family == Family::Browser {
            let host = window.url.and_then(crate::apps::host_of);
            let title = window.title.unwrap_or_default().trim();
            let host_is = |site: &str| {
                host.as_deref()
                    .is_some_and(|host| host == site || host.ends_with(&format!(".{site}")))
            };
            return if host_is("mail.google.com") || title.ends_with(" - Gmail") {
                Some(Self::Gmail)
            } else if host_is("calendar.google.com") || title.starts_with("Google Calendar") {
                Some(Self::Calendar)
            } else if host_is("github.com") || title.ends_with(" \u{00b7} GitHub") {
                Some(Self::GitHub)
            } else if host_is("youtube.com") || title.ends_with(" - YouTube") || title == "YouTube"
            {
                Some(Self::YouTube)
            } else if host_is("linkedin.com") || title.ends_with("| LinkedIn") {
                Some(Self::LinkedIn)
            } else {
                None
            };
        }
        match window.app {
            Some("com.apple.Notes") => Some(Self::Notes),
            Some("com.apple.finder") => Some(Self::Finder),
            Some("com.apple.systempreferences" | "com.apple.Settings") => {
                Some(Self::SystemSettings)
            }
            _ => None,
        }
    }

    /// Whether `line` is this site's navigation.
    fn is_nav(self, line: &str) -> bool {
        let bare = without_count(without_lead(line));
        match self {
            Self::Gmail => {
                GMAIL_NAV.contains(&bare)
                    || (line.contains("Search mail") && line.split_whitespace().count() <= 8)
            }
            Self::Calendar => {
                CALENDAR_NAV.contains(&bare) || is_calendar_header(line) || is_weekday_row(line)
            }
            Self::GitHub => is_repo_path(line) || names_row(line, &GITHUB_TABS, 3),
            Self::YouTube => YOUTUBE_NAV.contains(&bare) || names_row(line, &YOUTUBE_NAV, 3),
            Self::LinkedIn => names_row(line, &LINKEDIN_NAV, 4),
            Self::Notes => NOTES_NAV.contains(&bare),
            Self::Finder => FINDER_NAV.contains(&bare),
            Self::SystemSettings => SETTINGS_NAV.contains(&bare),
        }
    }
}

/// A line without the count after it: "Inbox 1,204" is "Inbox", "Drafts
/// (3)" is "Drafts".
fn without_count(line: &str) -> &str {
    let trimmed = line.trim_end();
    match trimmed.rsplit_once(' ') {
        Some((before, last))
            if last.chars().any(|ch| ch.is_ascii_digit())
                && last
                    .chars()
                    .all(|ch| ch.is_ascii_digit() || matches!(ch, ',' | '.' | '(' | ')' | '+')) =>
        {
            before.trim_end()
        }
        _ => trimmed,
    }
}

/// A row of a site's tab or menu names, with counts after some of them,
/// and nothing else: at least `min` names.
fn names_row(line: &str, names: &[&str], min: usize) -> bool {
    let mut rest = line.trim();
    let mut found = 0usize;
    while !rest.is_empty() {
        let token = rest.split_whitespace().next().unwrap_or_default();
        let count = token.chars().any(|ch| ch.is_ascii_digit())
            && token
                .chars()
                .all(|ch| ch.is_ascii_digit() || matches!(ch, ',' | '+' | 'k' | 'K'));
        let icon = !token.chars().any(char::is_alphanumeric) || token.chars().count() == 1;
        if count || icon {
            rest = rest[token.len()..].trim_start();
            continue;
        }
        // The longest name that starts here.
        let best = names
            .iter()
            .filter(|name| {
                rest.strip_prefix(**name)
                    .is_some_and(|after| after.is_empty() || after.starts_with(char::is_whitespace))
            })
            .max_by_key(|name| name.len());
        let Some(name) = best else {
            return false;
        };
        rest = rest[name.len()..].trim_start();
        found += 1;
    }
    found >= min
}

/// Google Calendar's header: "Today", a month and a year among buttons.
fn is_calendar_header(line: &str) -> bool {
    const MONTHS: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens.len() <= 14
        && tokens.contains(&"Today")
        && tokens.iter().any(|token| MONTHS.contains(token))
        && tokens
            .iter()
            .any(|token| token.len() == 4 && token.bytes().all(|b| b.is_ascii_digit()))
}

/// A calendar's row of weekdays: three or more of them, with dates.
fn is_weekday_row(line: &str) -> bool {
    const DAYS: [&str; 7] = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
    let tokens: Vec<&str> = line.split_whitespace().collect();
    let day = |token: &&str| DAYS.contains(&token.to_uppercase().as_str());
    tokens.iter().filter(|token| day(token)).count() >= 3
        && tokens.iter().all(|token| {
            day(token) || (token.len() <= 2 && token.bytes().all(|b| b.is_ascii_digit()))
        })
}

/// GitHub's repository header: "northwind / trailhead-shop".
fn is_repo_path(line: &str) -> bool {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    let (owner, repo) = match tokens.as_slice() {
        [owner, "/", repo] | [owner, "/", repo, "Public" | "Private"] => (*owner, *repo),
        _ => return false,
    };
    [owner, repo].iter().all(|part| {
        part.chars().any(char::is_alphanumeric)
            && part
                .chars()
                .all(|ch| ch.is_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    })
}

// ---------------------------------------------------------------------------
// Many-frame rule
// ---------------------------------------------------------------------------

/// One moment of an app, for [`RepeatedChrome::learn`]: its window title and
/// its screen text (the stored text without the header; for a browser page
/// read both ways, the part read off the screen).
#[derive(Debug, Clone, Copy)]
pub struct Frame<'a> {
    /// The window's title.
    pub title: Option<&'a str>,
    /// What the window said.
    pub text: &'a str,
}

/// Lines that windows of one app showed unchanged at their edges while
/// they showed different documents.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RepeatedChrome {
    /// Each learned line as its words, grouped by its first word.
    by_first: HashMap<String, Vec<Vec<String>>>,
    count: usize,
}

/// How often one line was seen while learning.
#[derive(Default)]
struct Seen {
    titles: HashSet<String>,
    frames: usize,
    last_frame: Option<usize>,
}

impl RepeatedChrome {
    /// A line is learned when windows with at least this many different
    /// titles showed it.
    pub const MIN_TITLES: usize = 3;
    /// A learned line has at least this many words: a lone word ("ok",
    /// "Done", "thanks!") is as often what someone wrote.
    pub const MIN_WORDS: usize = 2;
    /// Lines longer than this many words are not learned.
    const MAX_WORDS: usize = 40;
    /// Lines looked at from the top of each frame, and from its bottom.
    const EDGE_TOP: usize = 8;
    const EDGE_BOTTOM: usize = 4;
    /// Lines read from one frame, at most.
    const MAX_LINES_PER_FRAME: usize = 600;

    /// Learn from the moments of one app, `app`. Only text stored before
    /// windows were classified is learned from. A line is learned when it
    /// has two words or more, sits among a frame's first or last lines
    /// outside code, and was shown in at least half the frames, under at
    /// least [`Self::MIN_TITLES`] titles. A chat app learns only its channel
    /// names ("# general"), wherever they sit. Lines are compared by their
    /// words, leaving out icons the reader misread; titles by [`title_key`].
    #[must_use]
    pub fn learn<'a>(frames: impl IntoIterator<Item = Frame<'a>>, app: Option<&str>) -> Self {
        let chat = is_chat(app);
        let mut seen: HashMap<Vec<String>, Seen> = HashMap::new();
        let mut total = 0usize;
        for frame in frames {
            if frame.text.contains('\u{1e}') {
                // Classified: the helper already set its chrome apart.
                continue;
            }
            let number = total;
            total += 1;
            let title = title_key(frame.title.unwrap_or_default());
            for line in edge_lines(frame.text, chat) {
                let words = words_of(line);
                if words.len() < Self::MIN_WORDS
                    || words.len() > Self::MAX_WORDS
                    || words.iter().map(|word| letters(word)).sum::<usize>() < 2
                {
                    continue;
                }
                let entry = seen.entry(words).or_default();
                if entry.last_frame != Some(number) {
                    entry.frames += 1;
                    entry.last_frame = Some(number);
                }
                if entry.titles.len() < Self::MIN_TITLES {
                    entry.titles.insert(title.clone());
                }
            }
        }
        let mut learned = Self::default();
        for (words, entry) in seen {
            if entry.titles.len() >= Self::MIN_TITLES && entry.frames * 2 >= total {
                learned.insert(words);
            }
        }
        learned
    }

    fn insert(&mut self, words: Vec<String>) {
        let group = self.by_first.entry(words[0].clone()).or_default();
        if !group.contains(&words) {
            group.push(words);
            // Longest first, so a line takes the longest start it has.
            group.sort_by_key(|words| std::cmp::Reverse(words.len()));
            self.count += 1;
        }
    }

    /// Nothing was learned.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// How many lines were learned.
    #[must_use]
    pub fn len(&self) -> usize {
        self.count
    }

    /// Whether `line` is a learned line, word for word.
    #[must_use]
    pub fn contains(&self, line: &str) -> bool {
        let words = words_of(line);
        words.first().is_some_and(|first| {
            self.by_first
                .get(first)
                .is_some_and(|group| group.contains(&words))
        })
    }

    /// When `line` starts with a learned line and goes on with at least one
    /// word of two letters: that start, and the words after it. The line's
    /// indent goes with the start: it measured where the sidebar was.
    #[must_use]
    pub fn split_start<'l>(&self, line: &'l str) -> Option<(&'l str, &'l str)> {
        let words: Vec<(usize, usize)> = token_spans(line)
            .into_iter()
            .filter(|&(start, end)| !is_icon(&line[start..end]))
            .collect();
        let first = words.first().map(|&(start, end)| &line[start..end])?;
        let group = self.by_first.get(first)?;
        for learned in group {
            if learned.len() >= words.len() {
                continue;
            }
            let matches = learned
                .iter()
                .zip(&words)
                .all(|(want, &(start, end))| line[start..end] == **want);
            if !matches {
                continue;
            }
            if !words[learned.len()..]
                .iter()
                .any(|&(start, end)| letters(&line[start..end]) >= 2)
            {
                return None;
            }
            let chrome = &line[words[0].0..words[learned.len() - 1].1];
            let after = &line[words[learned.len()].0..];
            return Some((chrome, after));
        }
        None
    }
}

/// The lines of one frame the many-frame rule may learn: outside code,
/// tables and shell sessions, the first [`RepeatedChrome::EDGE_TOP`] and
/// last [`RepeatedChrome::EDGE_BOTTOM`] lines that are not blank; in a chat
/// app, its channel names wherever they sit.
fn edge_lines(text: &str, chat: bool) -> Vec<&str> {
    let mut lines: Vec<(&str, bool)> = Vec::new();
    for block in text.split("\n\n") {
        if lines.len() >= RepeatedChrome::MAX_LINES_PER_FRAME {
            break;
        }
        let block_lines: Vec<&str> = block
            .split('\n')
            .filter(|line| !line.trim().is_empty())
            .collect();
        if block_lines.is_empty() {
            continue;
        }
        let code = is_preformatted(&block_lines);
        let room = RepeatedChrome::MAX_LINES_PER_FRAME - lines.len();
        lines.extend(block_lines.into_iter().take(room).map(|line| (line, code)));
    }
    let total = lines.len();
    lines
        .into_iter()
        .enumerate()
        .filter(|&(at, (line, code))| {
            !code
                && if chat {
                    is_channel_name(line)
                } else {
                    at < RepeatedChrome::EDGE_TOP || at + RepeatedChrome::EDGE_BOTTOM >= total
                }
        })
        .map(|(_, (line, _))| line)
        .collect()
}

/// A chat app's channel name: "# general", "#launch-plan".
fn is_channel_name(line: &str) -> bool {
    let line = line.trim();
    line.starts_with('#') && line.split_whitespace().count() <= 4
}

/// A token that is only an icon the reader misread: box drawing and
/// geometric shapes, private-use characters, U+FFFD.
fn is_icon(token: &str) -> bool {
    token.chars().all(|ch| {
        matches!(
            ch,
            '\u{2500}'..='\u{25FF}'
                | '\u{E000}'..='\u{F8FF}'
                | '\u{F0000}'..='\u{FFFFD}'
                | '\u{100000}'..='\u{10FFFD}'
                | '\u{FFFD}'
        )
    })
}

fn token_spans(line: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = None;
    for (at, ch) in line.char_indices() {
        match (ch.is_whitespace(), start) {
            (false, None) => start = Some(at),
            (true, Some(from)) => {
                spans.push((from, at));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        spans.push((from, line.len()));
    }
    spans
}

/// The words of a line as the many-frame rule compares them: its tokens,
/// without icons.
fn words_of(line: &str) -> Vec<String> {
    line.split_whitespace()
        .filter(|token| !is_icon(token))
        .map(str::to_owned)
        .collect()
}

/// Whether `ch` is a mark an app puts before a window's title: a status or
/// progress glyph (✳, a braille spinner, ●, ⏺), never a letter, a digit or
/// a bracket.
#[must_use]
pub fn is_title_mark(ch: char) -> bool {
    matches!(
        ch,
        '*' | '\u{00b7}'
            | '\u{2022}'
            | '\u{2027}'
            | '\u{2219}'
            | '\u{22c5}'
            | '\u{23e9}'..='\u{23fa}'
            | '\u{25a0}'..='\u{25ff}'
            | '\u{2600}'..='\u{27bf}'
            | '\u{2800}'..='\u{28ff}'
            | '\u{2b50}'..='\u{2b55}'
            | '\u{1f300}'..='\u{1faff}'
    ) || ch.is_whitespace()
}

/// A window title without the status marks an app puts before it ("✳ Fix
/// rounding", "⠐ Fix rounding", "● tax.rs").
#[must_use]
pub fn without_title_marks(title: &str) -> &str {
    title.trim_start_matches(is_title_mark).trim_end()
}

/// A window title as the many-frame rule tells documents apart: lower case,
/// without a status mark, an unread count or "Edited", and with every run
/// of digits as `#`, so "(3) Inbox" and "(4) Inbox" are one document and a
/// counter in a title never makes a page look like many.
#[must_use]
pub fn title_key(title: &str) -> String {
    let text = without_title_marks(title);
    let lower = text.to_lowercase();
    let mut lower = lower.as_str();
    for end in [
        " \u{2014} edited",
        " - edited",
        " (modified)",
        " [modified]",
        " \u{2022} edited",
    ] {
        if let Some(stripped) = lower.strip_suffix(end) {
            lower = stripped;
        }
    }
    let mut key = String::with_capacity(lower.len());
    let mut in_digits = false;
    for ch in lower.chars() {
        if ch.is_ascii_digit() {
            if !in_digits {
                key.push('#');
            }
            in_digits = true;
        } else {
            in_digits = false;
            key.push(ch);
        }
    }
    let key = key.trim_start_matches("(#) ").trim();
    key.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fmt::Write as _;

    const CHROME: Option<&str> = Some("com.google.Chrome");
    const VSCODE: Option<&str> = Some("com.microsoft.VSCode");
    const SLACK_APP: Option<&str> = Some("com.tinyspeck.slackmacgap");

    fn window(app: Option<&str>) -> Window<'_> {
        Window {
            app,
            title: None,
            url: None,
        }
    }

    fn apart(content: &str, app: Option<&str>) -> Option<(String, String)> {
        set_apart(content, &window(app), None).map(|found| (found.kept.into_owned(), found.moved))
    }

    #[test]
    fn tab_strips_by_their_close_buttons_favicons_and_titles() {
        for line in [
            "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Chan\u{2026}",
            // The same strip without the ellipsis: pinned tabs at its start.
            "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Channel) - Northwind - Slack",
            "Per-seat or tiered? How to p... X Stripe Docs Inbox (12) - sam@example.c... \u{d7} hippocampus/README.md ... X",
            "0 General user models, explain... X 0 Stripe Docs +",
            "Pricing notes \u{d7} Stripe Docs \u{d7} Inbox \u{d7}",
            // One close button, three tabs led by favicons, no ellipsis.
            "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen # #launch - Slack E Q4 planning - Google Do",
            // Close buttons read as x, X or a circled x.
            "N How We Price Team Plans - Nor x G per seat vs tiered pricing - Go x +",
            "Stripe Docs x Inbox (12) x Pricing notes x",
            "Rounding half to even X Northwind - Calendar X Q4 planning X",
            "Rounding half to even \u{2297} Northwind - Calendar \u{2297} Q4 planning \u{2297} +",
            "tax.rs \u{d7} cart.rs \u{d7} main.rs \u{d7}",
        ] {
            assert!(is_tab_strip(line, None), "{line}");
        }
    }

    #[test]
    fn sums_sizes_and_formulas_are_not_tab_strips() {
        for line in [
            "1920 \u{d7} 1080",
            "Width \u{d7} Height",
            "Width \u{d7} Height \u{d7} Depth",
            "3 \u{d7} 4 = 12",
            "Image 1920 \u{d7} 1080...",
            "The box is 2 x 4 feet",
            "Go to the next page...",
            "Dimensions: 24 \u{d7} 18 \u{d7} 2 inches",
            "Storage Bin, 15 \u{d7} 10 \u{d7} 6 Inches",
            "Area = length \u{d7} width \u{d7} height",
            "Cost = price \u{d7} quantity \u{d7} (1 \u{2212} discount)",
            "Matrix product: A \u{d7} B \u{d7} C",
            "Choose Plan X or Plan Y",
        ] {
            assert!(!is_tab_strip(line, None), "{line}");
        }
    }

    #[test]
    fn the_windows_own_title_among_other_tabs_is_the_strip() {
        let title = title_start("Rounding half to even \u{b7} Dev Notes");
        assert_eq!(title, Some("Rounding half to even"));
        // No close buttons at all: the title, then two more titles.
        assert!(is_tab_strip(
            "Rounding half to even \u{b7} Dev Notes Northwind - Calendar Q4 planning - Google Docs",
            title
        ));
        // Safari: titles apart by wide gaps.
        assert!(is_tab_strip(
            "Pricing notes    Stripe Docs    Inbox (12)",
            title_start("Stripe Docs")
        ));
        // The page's heading, or the heading and a byline, is not.
        assert!(!is_tab_strip("Rounding half to even", title));
        assert!(!is_tab_strip(
            "Rounding half to even - Dev Notes Weekly",
            title
        ));
        assert!(!is_tab_strip(
            "Rounding half to even is how banks round",
            title
        ));
    }

    #[test]
    fn addresses_and_address_bars() {
        for token in [
            "pricingnotes.example/team-plans/per-seat-or-tiered",
            "https://example.org",
            "calendar.google.com",
            "localhost:3000/dashboard",
            "vidtube.example/watch?v=gum-explained",
        ] {
            assert!(is_address(token), "{token}");
        }
        for token in [
            "README.md",
            "e.g.",
            "U.S.",
            "sam@example.com",
            "v1.2.3",
            "3.14",
        ] {
            assert!(!is_address(token), "{token}");
        }
        assert!(is_address_bar(
            "< > C 8 pricingnotes.example/team-plans/per-seat-or-tiered \u{2606} \u{25a1} \u{2261}"
        ));
        assert!(is_address_bar(
            "\u{304f} C 8 vidtube.example/watch?v=gum-explained"
        ));
        assert!(is_address_bar("Not Secure localhost:3000/dashboard"));
        assert!(is_address_bar("Q Search Google or type a URL"));
        assert!(!is_address_bar(
            "Read more at pricingnotes.example/team-plans today"
        ));
        assert!(!is_address_bar("Visit example.com for details"));
    }

    #[test]
    fn bookmarks_bars_and_toolbars() {
        assert!(is_bookmarks_bar("Gmail YouTube Maps News All Bookmarks"));
        assert!(is_bookmarks_bar("Apple iCloud Google Reading List"));
        assert!(!is_bookmarks_bar("How to sync bookmarks between Macs"));
        assert!(is_toolbar("< > C \u{2606}"));
        assert!(is_toolbar("+"));
        assert!(!is_toolbar("Q3 KPI review"));
        assert!(!is_toolbar("OK"));
        for formula in [
            "y = mx + b",
            "a\u{b2} + b\u{b2} = c\u{b2}",
            "ok :)",
            "1 / 2",
        ] {
            assert!(!is_toolbar(formula), "{formula}");
        }
    }

    #[test]
    fn menu_rows_search_tabs_and_lone_buttons() {
        for line in [
            "File Edit View Insert Format Tools Extensions Help",
            "File Edit View Insert Format Data Tools Extensions Help",
            "File Edit View Insert Format Slide Arrange Tools Extensions Help",
            "File Home Insert Draw Design Layout References Review View Help",
        ] {
            assert!(is_menu_row(line), "{line}");
        }
        for line in [
            "Edit the file, then view it",
            "File Edit View",
            "Home Design Review Data",
            "View Insert Format Tools and more",
        ] {
            assert!(!is_menu_row(line), "{line}");
        }
        for line in [
            "All Images Videos News Shopping Short videos More Tools",
            "AI Mode All Images Videos News More Tools",
            "All Search Copilot Images Videos Maps News More",
        ] {
            assert!(is_search_tabs(line), "{line}");
        }
        for line in [
            "All images are free to use",
            "Images Videos News More",
            "All More Tools Settings",
        ] {
            assert!(!is_search_tabs(line), "{line}");
        }
        for line in ["Share", "Sign in", "\u{2606} Share"] {
            assert!(is_lone_button(line), "{line}");
        }
        for line in [
            "Share your thoughts below",
            "Sign in to comment",
            "Shared with me",
            // As often a page's own heading.
            "Get started",
            "Subscribe",
        ] {
            assert!(!is_lone_button(line), "{line}");
        }
    }

    #[test]
    fn a_sites_menu_ends_in_its_button_and_a_heading_is_not_one() {
        for line in [
            "Dev Notes Articles Topics About Subscribe",
            "Pricing Notes Guides Case studies Calculator Sign in Subscribe",
            "Product Solutions Resources Pricing Sign in Get started",
        ] {
            assert!(is_site_menu(line), "{line}");
        }
        for line in [
            "How to Sign in",
            "Why You Should Subscribe",
            "Click here to Subscribe",
            "Weekly Pricing Notes, Subscribe",
            "Notes Subscribe",
            "Docs Pricing notes Roadmap Design system Analytics",
            "Read the notes before you subscribe",
        ] {
            assert!(!is_site_menu(line), "{line}");
        }
    }

    #[test]
    fn messages_receipts_and_its_message_box() {
        for line in ["Delivered", "Read", "Read 2:21 PM", "Read Yesterday"] {
            assert!(is_receipt(line), "{line}");
        }
        for line in [
            "Read the doc before 3",
            "Delivered the printouts",
            "Read 2 chapters",
        ] {
            assert!(!is_receipt(line), "{line}");
        }
        let chat = "Sam Lee\nAre we still on for 3?\nSee you there\nDelivered\niMessage";
        let (kept, moved) = apart(chat, Some(MESSAGES)).expect("chrome found");
        assert_eq!(kept, "Sam Lee\nAre we still on for 3?\nSee you there");
        assert_eq!(moved, "Delivered\niMessage");
        // A reply "Read" above the last message stays; one receipt sits
        // under the last message.
        let replies = "Sam Lee\nDid you finish the book?\nRead\nNice\nDelivered\niMessage";
        let (kept, moved) = apart(replies, Some(MESSAGES)).expect("chrome found");
        assert_eq!(kept, "Sam Lee\nDid you finish the book?\nRead\nNice");
        assert_eq!(moved, "Delivered\niMessage");
        let two = "Sam Lee\nDid you read it?\nRead\nDelivered\niMessage";
        let (kept, _) = apart(two, Some(MESSAGES)).expect("chrome found");
        assert_eq!(kept, "Sam Lee\nDid you read it?\nRead");
    }

    #[test]
    fn a_web_apps_menus_leave_only_near_the_top_of_a_browser() {
        let content = "Q4 planning\nFile Edit View Insert Format Tools Extensions Help\nShare\nGoals\nShip the rounding fix.";
        let titled = Window {
            app: CHROME,
            title: Some("Q4 planning - Google Docs"),
            url: None,
        };
        let found = set_apart(content, &titled, None).expect("chrome found");
        assert_eq!(found.kept, "Q4 planning\nGoals\nShip the rounding fix.");
        assert_eq!(
            found.moved,
            "File Edit View Insert Format Tools Extensions Help\nShare"
        );
        // In other apps, and below a browser's first lines, the words stay.
        assert_eq!(apart(content, Some("com.apple.Notes")), None);
        let mut low = String::new();
        for n in 0..TOP_LINES {
            let _ = writeln!(low, "Line {n}");
        }
        low.push_str("File Edit View Insert Format Tools Extensions Help\nShare");
        assert_eq!(apart(&low, CHROME), None);
    }

    #[test]
    fn a_title_bar_with_its_star_leaves_and_the_documents_name_stays() {
        let content = "Q4 planning \u{2606}\nQ4 planning\nFile Edit View Insert Format Tools Extensions Help\nGoals";
        let titled = Window {
            app: CHROME,
            title: Some("Q4 planning - Google Docs"),
            url: None,
        };
        let found = set_apart(content, &titled, None).expect("chrome found");
        assert_eq!(found.kept, "Q4 planning\nGoals");
        assert_eq!(
            found.moved,
            "Q4 planning \u{2606}\nFile Edit View Insert Format Tools Extensions Help"
        );
        assert!(!found.contiguous(), "the name stays between moved lines");
    }

    #[test]
    fn editor_and_slack_chrome() {
        assert!(is_editor_chrome("EXPLORER"));
        assert!(is_editor_chrome("\u{4e09} EXPLORER"));
        assert!(is_editor_chrome(
            "main 0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust"
        ));
        assert!(is_editor_chrome("apps > agent > src > retention_worker.rs"));
        assert!(is_editor_chrome("src > cart > tax.rs"));
        assert!(is_editor_chrome(
            "PROBLEMS OUTPUT DEBUG CONSOLE TERMINAL PORTS"
        ));
        for line in [
            "OUTPUT is written to stdout",
            "if a > b > c { return; }",
            "let explorer = Explorer::new();",
            "## TIMELINE",
            "- OUTPUT",
            "System Settings > Privacy > Accessibility",
            "assert low > mid > high",
        ] {
            assert!(!is_editor_chrome(line), "{line}");
        }
        assert!(is_slack_message_box("Message #launch-plan", None));
        assert!(is_slack_message_box("Message Maya Chen", None));
        assert!(is_slack_message_box(
            "Message launch-plan",
            Some("launch-plan (Channel) - Northwind - Slack")
        ));
        for line in [
            "Message me when the build is green.",
            "Message received",
            "Message sent",
            "Message me later",
        ] {
            assert!(!is_slack_message_box(line, None), "{line}");
        }
        assert!(is_slack_top("4 Drafts & sent", 3));
        assert!(is_slack_top("\u{2606} Channels", 4));
        assert!(is_slack_top(
            "Northwind Studio > \u{304f} Q Search Northwind Studio D",
            0
        ));
        assert!(!is_slack_top("Search is down for everyone", 0));
        assert!(!is_slack_top(
            "Search results look wrong for long queries",
            1
        ));
    }

    #[test]
    fn set_apart_moves_the_edges_and_keeps_blocks() {
        let content = "Tab one \u{d7} Tab two \u{d7}\n< > C example.org/page \u{2606}\nHeading\nFirst line of the page.\n\nSecond block.";
        let found = set_apart(content, &window(CHROME), None).expect("chrome found");
        assert_eq!(
            found.kept,
            "Heading\nFirst line of the page.\n\nSecond block."
        );
        assert!(matches!(found.kept, Cow::Borrowed(_)));
        assert!(found.contiguous());
        assert_eq!(
            found.moved,
            "Tab one \u{d7} Tab two \u{d7}\n< > C example.org/page \u{2606}"
        );
        assert_eq!(apart("Heading\nBody", CHROME), None);
        assert_eq!(apart(content, Some("com.apple.Notes")), None);
        assert_eq!(apart(content, Some("com.apple.Terminal")), None);
    }

    #[test]
    fn a_terminal_loses_only_a_coding_assistants_status_line_and_empty_box() {
        let text = "\u{23fa} Update(src/tax.rs)\n  \u{23bf} Updated src/tax.rs with 2 additions\n\u{256d}\u{2500}\u{2500}\u{256e}\n\u{2502} > \u{2502}\n\u{2570}\u{2500}\u{2500}\u{256f}\n  \u{23f5}\u{23f5} accept edits on (shift+tab to cycle)";
        let (kept, moved) = apart(text, Some("com.apple.Terminal")).unwrap();
        assert_eq!(
            kept,
            "\u{23fa} Update(src/tax.rs)\n  \u{23bf} Updated src/tax.rs with 2 additions"
        );
        assert!(
            moved.ends_with("accept edits on (shift+tab to cycle)"),
            "{moved}"
        );
        // A shell's own output is kept as read.
        assert_eq!(
            apart("$ cargo test\nok\n>", Some("com.apple.Terminal")),
            None
        );
    }

    #[test]
    fn below_the_top_a_browser_line_is_never_chrome_by_one_frame() {
        let mut content = String::from("Title\n");
        for n in 0..10 {
            let _ = writeln!(content, "Line {n}");
        }
        content.push_str("Tab one \u{d7} Tab two \u{d7}");
        assert_eq!(apart(&content, CHROME), None);
    }

    #[test]
    fn an_editor_and_slack_lose_only_their_edges() {
        let code = "EXPLORER\nsrc > cart > tax.rs\nfn main() {}\nOUTLINE\nTIMELINE\nlet x = 1;\nOUTLINE\nLn 3, Col 9 UTF-8";
        let (kept, moved) = apart(code, VSCODE).unwrap();
        assert_eq!(kept, "fn main() {}\nOUTLINE\nTIMELINE\nlet x = 1;");
        assert_eq!(
            moved,
            "EXPLORER\nsrc > cart > tax.rs\nOUTLINE\nLn 3, Col 9 UTF-8"
        );
        let chat = "Threads\nMaya Chen 10:42 AM\nMore\nShipping today.\n\nMessage #launch-plan";
        let (kept, moved) = apart(chat, SLACK_APP).unwrap();
        assert_eq!(kept, "Maya Chen 10:42 AM\nMore\nShipping today.");
        assert_eq!(moved, "Threads\nMessage #launch-plan");
    }

    #[test]
    fn a_tab_strip_read_over_two_lines_leaves_whole() {
        let content = "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen\n\u{d7} # #launch - Slack \u{d7} +\nRounding half to even\nRound half up looks fair.";
        let (kept, moved) = apart(content, CHROME).unwrap();
        assert_eq!(kept, "Rounding half to even\nRound half up looks fair.");
        assert_eq!(
            moved,
            "D Rounding half to even \u{b7} Dev No \u{d7} 31 Northwind - Calen\n\u{d7} # #launch - Slack \u{d7} +"
        );
    }

    #[test]
    fn web_apps_and_side_bars_lose_their_navigation() {
        let gmail = Window {
            app: CHROME,
            title: Some("Re: Invoice 1042 - sam@northwind.example - Northwind Mail"),
            url: Some("https://mail.google.com/mail/u/0/#inbox/FMfcgzQ"),
        };
        let text = "Gmail Q Search mail\nCompose\nInbox 1,204\nStarred\nSnoozed\nSent\nDrafts 3\nMore\nRe: Invoice 1042 Inbox \u{d7}\nThanks for sending this over.";
        let found = set_apart(text, &gmail, None).unwrap();
        assert_eq!(
            found.kept,
            "Re: Invoice 1042 Inbox \u{d7}\nThanks for sending this over."
        );
        let notes = Window {
            app: Some("com.apple.Notes"),
            title: Some("Launch checklist"),
            url: None,
        };
        let text = "iCloud\nAll iCloud 42\nNotes 38\nQuick Notes 4\nLaunch checklist\nBeta group told about 0.4";
        let found = set_apart(text, &notes, None).unwrap();
        assert_eq!(found.kept, "Launch checklist\nBeta group told about 0.4");
        // A note of its own short lines keeps them all.
        assert!(set_apart("Groceries\nMilk\nEggs", &notes, None).is_none());
    }

    fn frames<'a>(pages: &'a [(&'a str, &'a str)]) -> Vec<Frame<'a>> {
        pages
            .iter()
            .map(|(title, text)| Frame {
                title: Some(title),
                text,
            })
            .collect()
    }

    #[test]
    fn a_line_shown_under_three_titles_is_learned_and_one_that_changes_is_not() {
        let pages = [
            (
                "Pricing",
                "Docs Pricing Blog\n\u{25cf} Home\nPer-seat pricing is easy.",
            ),
            (
                "Billing",
                "Docs Pricing Blog\nHome\nAnnual billing saves money.",
            ),
            (
                "Seats",
                "Docs  Pricing  Blog\nHome\nA seat minimum is a compromise.",
            ),
        ];
        let learned = RepeatedChrome::learn(frames(&pages), CHROME);
        assert!(learned.contains("Docs Pricing Blog"));
        assert!(!learned.contains("Home"), "a lone word is never learned");
        assert!(!learned.contains("Per-seat pricing is easy."));
        assert_eq!(learned.len(), 1);
    }

    #[test]
    fn a_line_under_one_title_is_never_learned() {
        let pages = [
            ("Notes", "Shared paragraph that stays put"),
            ("Notes", "Shared paragraph that stays put"),
            ("Notes", "Shared paragraph that stays put"),
            ("(2) Notes", "Shared paragraph that stays put"),
        ];
        assert!(RepeatedChrome::learn(frames(&pages), None).is_empty());
    }

    #[test]
    fn a_line_in_fewer_than_half_the_frames_is_not_learned() {
        let mut pages: Vec<(&str, &str)> = vec![
            ("a", "Shared nav line\nOne"),
            ("b", "Shared nav line\nTwo"),
            ("c", "Shared nav line\nThree"),
        ];
        pages.extend(std::iter::repeat_n(("d", "Something else\nFour"), 4));
        assert!(RepeatedChrome::learn(frames(&pages), None).is_empty());
    }

    #[test]
    fn a_learned_start_comes_off_a_line_and_its_words_stay() {
        let pages = [
            ("a", "# general\nx one"),
            ("b", "# general\ny two"),
            ("c", "# general\nz three"),
        ];
        let learned = RepeatedChrome::learn(frames(&pages), SLACK_APP);
        assert_eq!(
            learned.split_start("       # general Pushed the new onboarding flow."),
            Some(("# general", "Pushed the new onboarding flow."))
        );
        assert_eq!(learned.split_start("# general"), None, "nothing after it");
        assert_eq!(
            learned.split_start("# general 12"),
            None,
            "no word after it"
        );
        let content = "# general Pushed the flow.\nToday";
        let found = set_apart(content, &window(SLACK_APP), Some(&learned)).unwrap();
        assert_eq!(found.kept, "Pushed the flow.\nToday");
        assert_eq!(found.moved, "# general");
        assert!(!found.contiguous());
    }

    #[test]
    fn a_chat_app_learns_only_its_channel_names() {
        let pages = [
            (
                "launch (Channel)",
                "# general\nMaya Chen 10:42 AM\nsounds good\nthanks!",
            ),
            (
                "design (Channel)",
                "# general\nMaya Chen 10:42 AM\nsounds good\nthanks!",
            ),
            (
                "pricing (Channel)",
                "# general\nMaya Chen 10:42 AM\nsounds good\nthanks!",
            ),
        ];
        let learned = RepeatedChrome::learn(frames(&pages), SLACK_APP);
        assert!(learned.contains("# general"));
        assert!(!learned.contains("sounds good"));
        assert!(!learned.contains("Maya Chen 10:42 AM"));
        assert_eq!(learned.len(), 1);
    }

    #[test]
    fn code_is_never_learned() {
        let pages = [
            (
                "tax.rs",
                "use std::collections::HashMap;\nuse serde::Deserialize;\nfn a() {}",
            ),
            (
                "api.rs",
                "use std::collections::HashMap;\nuse serde::Deserialize;\nfn b() {}",
            ),
            (
                "ledger.rs",
                "use std::collections::HashMap;\nuse serde::Deserialize;\nfn c() {}",
            ),
        ];
        assert!(RepeatedChrome::learn(frames(&pages), VSCODE).is_empty());
    }

    #[test]
    fn classified_frames_are_not_learned_from() {
        let pages = [
            ("a", "Shared nav line\n\n\u{1e}\nchrome"),
            ("b", "Shared nav line\n\n\u{1e}\nchrome"),
            ("c", "Shared nav line\n\n\u{1e}\nchrome"),
        ];
        assert!(RepeatedChrome::learn(frames(&pages), CHROME).is_empty());
    }

    #[test]
    fn titles_are_keyed_without_counts_and_marks() {
        assert_eq!(
            title_key("(3) Inbox - Gmail"),
            title_key("(12) Inbox - Gmail")
        );
        assert_eq!(
            title_key("\u{25cf} main.rs \u{2014} app"),
            title_key("main.rs \u{2014} app")
        );
        assert_eq!(
            title_key("\u{2733} Fix rounding in tax.rs"),
            title_key("\u{2810} Fix rounding in tax.rs")
        );
        assert_eq!(title_key("Notes \u{2014} Edited"), "notes");
        assert_ne!(title_key("Pricing"), title_key("Billing"));
        assert_eq!(without_title_marks("\u{2733} Fix rounding"), "Fix rounding");
        assert_eq!(without_title_marks("(3) Inbox"), "(3) Inbox");
        assert_eq!(without_title_marks("~/hippo-work"), "~/hippo-work");
    }
}
