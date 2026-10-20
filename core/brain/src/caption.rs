//! Captions: one short plain line saying what a moment was about.
//!
//! "Looking up how to type accents on a Mac", "Working on tax.rs in
//! trailhead-shop", "Chatting in #launch-plan". The on-device model writes one
//! when it can, and [`accept`] decides whether its line may be shown;
//! otherwise [`fallback`] makes one from the window title, the app and the
//! page address, with a few plain verbs. Every caption:
//!
//! - is grounded: each word that says what the moment was about comes from
//!   the moment's own title, address, app name or text. Only the verbs and
//!   small joining words in the lists below may come from elsewhere
//!   ([`is_grounded`]). A model's line must also name something the title
//!   does not, or the caption made from the title stays;
//! - claims no activity the moment does not show: a window beside the one in
//!   use is named where it was open ("#launch, open in Slack"), and "On a
//!   call" needs a call's own window;
//! - says nothing about the person: no pronouns, no feelings, and no guess
//!   about their work life, health, money, relationships or who they are
//!   ([`crate::sensitive`]). A model's line that touches one is not used
//!   ([`about_the_person`]), and the model is not asked about a moment that
//!   does ([`is_sensitive`]); the fallback only restates the title, which the
//!   row shows anyway;
//! - passes the secret check stored text passes ([`contains_secret`]).
//!
//! Nothing here reads the network or the person's other moments.

use std::collections::HashSet;

use crate::apps::{self, WorkKind};
use crate::chrome::without_title_marks;
use crate::redaction::ocr_secrets::contains_secret;
use crate::sensitive::sensitive_area;

/// The longest caption, in characters.
pub const MAX_CHARS: usize = 80;

/// The longest window name a caption quotes, in characters. A row shows its
/// caption on one line, so a longer name is cut short inside its quotes.
pub const MAX_NAME_CHARS: usize = 40;

/// What a caption may be made from: one moment's own window.
#[derive(Debug, Clone, Copy, Default)]
pub struct Moment<'a> {
    /// The app's bundle id.
    pub app: Option<&'a str>,
    /// The window title.
    pub title: Option<&'a str>,
    /// The page address, when the moment has one.
    pub url: Option<&'a str>,
    /// What the person was reading: the moment's cleaned `main`.
    pub text: &'a str,
    /// The window was beside the one in use (read by the whole-screen pass,
    /// `screen_context`), not the one in use.
    pub beside: bool,
}

/// Words that join the words of a caption, which need no grounding.
const JOINERS: &[&str] = &[
    "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "from", "with", "about",
    "into", "over", "up", "out", "by", "as", "via", "new", "how", "what", "why", "when", "where",
    "which", "who", "it", "its", "this", "that", "these", "those", "some", "more", "next", "all",
    "between", "through", "before", "after", "around",
];

/// Plain verbs a caption may start with, which need no grounding.
const VERBS: &[&str] = &[
    "looking",
    "reading",
    "writing",
    "planning",
    "designing",
    "editing",
    "reviewing",
    "checking",
    "watching",
    "searching",
    "chatting",
    "messaging",
    "working",
    "comparing",
    "browsing",
    "coding",
    "debugging",
    "setting",
    "organizing",
    "drafting",
    "updating",
    "building",
    "testing",
    "fixing",
    "learning",
    "researching",
    "studying",
    "scheduling",
    "filling",
    "preparing",
    "sorting",
    "going",
    "catching",
    "listening",
    "running",
    "asking",
    "answering",
    "replying",
    "sharing",
    "exploring",
    "trying",
    "adding",
    "making",
    "creating",
    "starting",
    "finishing",
    "using",
    "opening",
    "configuring",
    "installing",
    "deploying",
    "merging",
    "refactoring",
    "documenting",
    "sketching",
    "outlining",
    "summarizing",
    "translating",
    "taking",
    "following",
    "tracking",
    "typing",
    "practicing",
    "calling",
    "talking",
    "naming",
    "renaming",
    "cleaning",
    "picking",
    "choosing",
    "noting",
    "listing",
    "laying",
    "mapping",
];

/// General words for what is on a screen, which need no grounding.
pub(crate) const GENERIC: &[&str] = &[
    "page",
    "pages",
    "site",
    "doc",
    "docs",
    "document",
    "documents",
    "email",
    "emails",
    "mail",
    "message",
    "messages",
    "chat",
    "call",
    "video",
    "videos",
    "article",
    "notes",
    "note",
    "file",
    "files",
    "code",
    "list",
    "settings",
    "tab",
    "tabs",
    "inbox",
    "thread",
    "threads",
    "post",
    "draft",
    "changes",
    "details",
    "options",
    "tasks",
    "task",
    "link",
    "links",
    "results",
    "calendar",
];

/// Words that point at a person. A caption describes the screen, not them.
const PERSON_WORDS: &[&str] = &[
    "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself", "he", "him", "his",
    "she", "her", "hers", "they", "them", "their", "theirs", "we", "us", "our", "ours",
];

/// Starts of words about a person's feelings, work life, health, money,
/// relationships or identity, beside [`crate::sensitive`]'s whole words. A
/// model's caption with one is not used.
const SENSITIVE_STARTS: &[&str] = &[
    "job",
    "career",
    "resume",
    "résumé",
    "salary",
    "unemploy",
    "layoff",
    "hiring",
    "debt",
    "loan",
    "mortgage",
    "bankrupt",
    "financ",
    "health",
    "sick",
    "illness",
    "disease",
    "diagnos",
    "symptom",
    "therap",
    "medic",
    "pregnan",
    "depress",
    "anxi",
    "dating",
    "relationship",
    "boyfriend",
    "girlfriend",
    "husband",
    "divorce",
    "breakup",
    "religio",
    "pray",
    "politic",
    "ethnic",
    "racial",
    "immigra",
    "gender",
    "sexual",
    "lesbian",
    "queer",
    "transgender",
    "identity",
    "worr",
    "stress",
    "frustrat",
    "lonel",
    "struggl",
    "afraid",
    "upset",
    "anxious",
    "scared",
    "nervous",
    "overwhelm",
    "heartbr",
    "grief",
    "grieving",
];

/// Feelings and personal words that are whole words only: "illustration",
/// "visual" and "broken" are fine.
const SENSITIVE_WORDS: &[&str] = &[
    "ill", "visa", "gay", "wife", "broke", "sad", "angry", "hurt",
];

/// Words of a call or a meeting. A caption says one only with a call's own
/// window ([`in_a_call`]).
const CALL_WORDS: &[&str] = &[
    "call",
    "calls",
    "meeting",
    "meetings",
    "huddle",
    "huddles",
    "webinar",
    "webinars",
    "standup",
    "standups",
    "conference",
];

/// Site and product names a window title often ends with; the fallback
/// leaves them out of what it restates.
pub(crate) const TITLE_SUFFIXES: &[&str] = &[
    "google chrome",
    "chrome",
    "safari",
    "arc",
    "mozilla firefox",
    "firefox",
    "microsoft edge",
    "brave",
    "google search",
    "google docs",
    "google sheets",
    "google slides",
    "google calendar",
    "google drive",
    "gmail",
    "youtube",
    "notion",
    "figma",
    "github",
    "wikipedia",
    "stack overflow",
    "medium",
    "reddit",
    "linkedin",
    "slack",
    "discord",
    "visual studio code",
    "cursor",
    "zed",
    "xcode",
    "claude",
    "chatgpt",
    "microsoft teams",
    "teams",
    "zoom",
];

/// Titles that name no page: a new tab, a start page, a site's home.
pub(crate) const BLANK_PAGES: &[&str] = &[
    "new tab",
    "new window",
    "new private tab",
    "private browsing",
    "start page",
    "start",
    "favorites",
    "favourites",
    "home",
    "google",
    "youtube",
    "untitled",
    "untitled document",
    "untitled spreadsheet",
    "untitled presentation",
    "about:blank",
    "blank page",
    "zoom workplace",
    "zoom",
];

/// A mailbox's name, which says no message: "Going through email".
const MAILBOXES: &[&str] = &[
    "inbox",
    "all inboxes",
    "sent",
    "sent messages",
    "sent mail",
    "drafts",
    "archive",
    "all mail",
    "junk",
    "spam",
    "trash",
    "deleted messages",
    "flagged",
    "vips",
    "starred",
    "important",
    "snoozed",
    "scheduled",
    "outbox",
    "mail",
];

/// Slack's views that are not one channel or person.
const SLACK_VIEWS: &[&str] = &[
    "threads",
    "activity",
    "dms",
    "direct messages",
    "later",
    "saved items",
    "drafts & sent",
    "inbox",
    "home",
    "search",
    "channels",
    "canvases",
    "lists",
    "files",
    "mentions & reactions",
    "unreads",
    "people",
    "apps",
    "more",
];

/// Search pages: the host, and the address parameter that holds the query.
const SEARCH_PAGES: &[(&str, &str)] = &[
    ("google.com", "q"),
    ("bing.com", "q"),
    ("duckduckgo.com", "q"),
    ("search.brave.com", "q"),
    ("kagi.com", "q"),
    ("perplexity.ai", "q"),
    ("youtube.com", "search_query"),
    ("ecosia.org", "q"),
];

/// Title endings of search result pages.
pub(crate) const SEARCH_TITLE_ENDS: &[&str] = &[
    " - Google Search",
    " - Bing",
    " at DuckDuckGo",
    " - Brave Search",
    " - Kagi Search",
    " - YouTube",
];

// ---------------------------------------------------------------------------
// Fallback
// ---------------------------------------------------------------------------

/// A caption made from the title, the app and the address, without a model.
/// `None` for the lock screen and other surfaces that are not work, for a
/// window with nothing to say, for an app known only by its bundle id with
/// nothing more than its title to say, and for a line the secret check
/// stops.
#[must_use]
pub fn fallback(moment: &Moment<'_>) -> Option<String> {
    let app = moment.app.unwrap_or_default();
    if app.is_empty() || apps::is_noise(app) {
        return None;
    }
    let known = apps::known_name(app);
    let name = known.map_or_else(|| apps::name(app), str::to_owned);
    let host = moment.url.and_then(apps::host_of).unwrap_or_default();
    let raw_title = without_title_marks(moment.title.unwrap_or_default());
    let segments = title_segments(raw_title, &name);
    // The window's own name, unless it only names the app, the site or a
    // blank page.
    let window = segments
        .first()
        .filter(|first| !says_nothing(first, &name))
        .cloned();
    if moment.beside {
        return beside(moment, window.as_deref(), &name, known.is_some(), &host);
    }
    if let Some(query) = search_query(moment) {
        return finish(&format!("Looking up {}", lower_question(&query)));
    }
    let using = || format!("Using {name}");
    let line = match apps::kind_for(app, moment.url) {
        WorkKind::Code if crate::reading::TERMINAL_APPS.contains(&app) => match &window {
            Some(title) if !looks_like_a_shell_title(title) => {
                format!("Working in {name}: {}", cut_name(title))
            }
            _ => format!("Working in {name}"),
        },
        WorkKind::Code if is_host(&host, "github.com") => {
            github(raw_title, window.as_deref()).unwrap_or_else(|| "Browsing GitHub".to_owned())
        }
        WorkKind::Code => match (window.as_deref(), segments.get(1)) {
            (Some(file), Some(project)) if !says_nothing(project, &name) => {
                format!("Working on {} in {}", cut_name(file), cut_name(project))
            }
            (Some(file), _) => format!("Working on {}", cut_name(file)),
            _ => using(),
        },
        WorkKind::Writing => match window.or_else(|| first_heading(moment.text)) {
            Some(title) => format!("Working on {}", named(&title)),
            None => using(),
        },
        WorkKind::Communication => {
            communication(app, &name, &host, moment.title, window.as_deref())
        }
        WorkKind::Meetings => meetings(moment, &name, &host, raw_title),
        WorkKind::Design => {
            window.map_or_else(using, |title| format!("Designing {}", named(&title)))
        }
        WorkKind::Ai => match window.filter(|title| !is_generic_ai_title(title)) {
            Some(title) => format!("Asking {} about {}", ai_name(&name, &host), named(&title)),
            None => format!("Using {}", ai_name(&name, &host)),
        },
        WorkKind::Planning
            if app == "com.apple.iCal"
                || is_host(&host, "calendar.google.com")
                || app == "com.flexibits.fantastical2.mac" =>
        {
            "Checking the calendar".to_owned()
        }
        WorkKind::Planning => window.map_or_else(using, |title| {
            format!("Working on {}", named(without_issue_key(&title)))
        }),
        WorkKind::Media
            if is_host(&host, "youtube.com")
                || is_host(&host, "netflix.com")
                || app == "com.apple.TV" =>
        {
            window.map_or_else(
                || format!("Browsing in {name}"),
                |title| format!("Watching {}", named(&title)),
            )
        }
        WorkKind::Media => format!("Listening in {name}"),
        WorkKind::Research if crate::chrome::is_browser(Some(app)) => window.map_or_else(
            || format!("Browsing in {name}"),
            |title| format!("Reading {}", named(&title)),
        ),
        WorkKind::Research => {
            window.map_or_else(using, |title| format!("Reading {}", named(&title)))
        }
        WorkKind::Other => {
            // An app known only by its bundle id: the title is the row's
            // headline already, and "in Widgetmaker" would be a guess.
            known?;
            window.map_or_else(using, |title| format!("{} in {name}", cut_name(&title)))
        }
    };
    finish(&line)
}

/// A window beside the one in use: where it was open, never what was done
/// in it. `None` when it has no name of its own, or its app is known only
/// by its bundle id.
fn beside(
    moment: &Moment<'_>,
    window: Option<&str>,
    name: &str,
    known: bool,
    host: &str,
) -> Option<String> {
    if !known {
        return None;
    }
    let raw = moment.title.unwrap_or_default();
    let slack_like = moment.app == Some("com.tinyspeck.slackmacgap")
        || is_host(host, "app.slack.com")
        || moment.app == Some("com.hnc.Discord");
    let label = slack_like
        .then(|| slack_place(raw))
        .flatten()
        .or_else(|| window.map(quoted))?;
    finish(&format!("{label}, open in {name}"))
}

/// Slack's channel ("#launch") or person ("Sam Lee") a title names.
fn slack_place(raw: &str) -> Option<String> {
    if let Some(channel) = raw
        .split(" (Channel)")
        .next()
        .filter(|_| raw.contains(" (Channel)"))
    {
        let channel = channel.trim().trim_start_matches('#');
        return (!channel.is_empty()).then(|| format!("#{channel}"));
    }
    raw.split(" (DM)")
        .next()
        .filter(|_| raw.contains(" (DM)"))
        .map(|person| person.trim().to_owned())
        .filter(|person| !person.is_empty())
}

fn communication(
    app: &str,
    name: &str,
    host: &str,
    full_title: Option<&str>,
    title: Option<&str>,
) -> String {
    let raw = without_title_marks(full_title.unwrap_or_default());
    if app == "com.tinyspeck.slackmacgap"
        || is_host(host, "app.slack.com")
        || app == "com.hnc.Discord"
    {
        if raw.to_lowercase().starts_with("huddle") {
            return format!("On a call in {name}");
        }
        if raw.contains(" (Channel)") {
            if let Some(channel) = slack_place(raw) {
                return format!("Chatting in {channel}");
            }
        }
        if let Some(person) = raw.split(" (DM)").next().filter(|_| raw.contains(" (DM)")) {
            return format!("Chatting with {}", cut_name(person.trim()));
        }
        // Threads, Activity, an inbox, a search: no one channel or person.
        return match title {
            Some(title) if !is_slack_view(title) => format!("Chatting in {}", named(title)),
            _ => format!("Using {name}"),
        };
    }
    let mail = matches!(
        app,
        "com.apple.mail"
            | "com.microsoft.Outlook"
            | "com.superhuman.electron"
            | "com.readdle.smartemail-Mac"
    ) || is_host(host, "mail.google.com")
        || host.starts_with("outlook.");
    if mail {
        return match title.map(without_reply_marks) {
            Some(subject) if !subject.is_empty() && !is_mailbox(subject) => {
                format!("Reading the email {}", quoted(subject))
            }
            _ => "Going through email".to_owned(),
        };
    }
    title.map_or_else(
        || format!("Using {name}"),
        |title| format!("Messaging {}", cut_name(title)),
    )
}

/// Calls and meetings: "On a call" only with a call's own window;
/// otherwise the app or the service in the tab is in use.
fn meetings(moment: &Moment<'_>, name: &str, host: &str, raw_title: &str) -> String {
    let service = if is_host(host, "meet.google.com") {
        "Google Meet"
    } else if is_host(host, "zoom.us") {
        "Zoom"
    } else if is_host(host, "teams.microsoft.com") {
        "Microsoft Teams"
    } else {
        name
    };
    if in_a_call(moment) {
        return format!("On a call in {service}");
    }
    // Teams: "Chat | Sam Lee | Microsoft Teams".
    let parts: Vec<&str> = raw_title.split(" | ").map(str::trim).collect();
    if parts.len() >= 3 && parts[0].eq_ignore_ascii_case("chat") && !parts[1].is_empty() {
        return format!("Chatting with {}", cut_name(parts[1]));
    }
    format!("Using {service}")
}

/// Whether the moment's own window is a call: Zoom's meeting window, a
/// Google Meet room, a Teams meeting or call, a Slack huddle.
#[must_use]
pub fn in_a_call(moment: &Moment<'_>) -> bool {
    let title = without_title_marks(moment.title.unwrap_or_default()).to_lowercase();
    let host = moment.url.and_then(apps::host_of).unwrap_or_default();
    match moment.app.unwrap_or_default() {
        "us.zoom.xos" => {
            title.starts_with("zoom meeting")
                || title.starts_with("zoom webinar")
                || title.contains("'s zoom meeting")
                || title.contains("\u{2019}s zoom meeting")
        }
        "com.microsoft.teams2" | "com.microsoft.teams" => {
            title.starts_with("meeting")
                || title.starts_with("call ")
                || title.contains("| meeting")
                || title.contains("meeting with")
        }
        "com.tinyspeck.slackmacgap" => title.starts_with("huddle"),
        _ if is_host(&host, "meet.google.com") => moment.url.is_some_and(is_meet_room),
        _ if is_host(&host, "zoom.us") => moment
            .url
            .is_some_and(|url| url.contains("/j/") || url.contains("/wc/")),
        _ => false,
    }
}

/// A Google Meet room's address: "meet.google.com/abc-defg-hij".
fn is_meet_room(url: &str) -> bool {
    let path = url
        .split("meet.google.com/")
        .nth(1)
        .unwrap_or_default()
        .split(['?', '#', '/'])
        .next()
        .unwrap_or_default();
    let parts: Vec<&str> = path.split('-').collect();
    parts.len() == 3
        && parts.iter().all(|part| {
            (3..=4).contains(&part.len()) && part.bytes().all(|b| b.is_ascii_lowercase())
        })
}

/// GitHub's pull requests and issues: "Round half to even by sam-lee · Pull
/// Request #42 · northwind/trailhead-shop".
fn github(raw_title: &str, window: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = raw_title.split(" \u{00b7} ").map(str::trim).collect();
    if parts.len() >= 3 {
        let repo = parts[parts.len() - 1]
            .rsplit('/')
            .next()
            .unwrap_or_default();
        let what = parts[0]
            .rsplit_once(" by ")
            .map_or(parts[0], |(what, _)| what);
        let kind = parts[1].to_lowercase();
        if kind.starts_with("pull request") {
            return Some(format!("Reviewing {} in {repo}", quoted(what)));
        }
        if kind.starts_with("issue") {
            return Some(format!("Reading the issue {} in {repo}", quoted(what)));
        }
    }
    // A repository's own page: "northwind/trailhead-shop: A shop for …".
    let first = window?;
    let path = first.split(": ").next().unwrap_or(first);
    let (owner, repo) = path.split_once('/')?;
    (!owner.contains(' ') && !repo.contains(' ') && !repo.is_empty())
        .then(|| format!("Browsing {repo} on GitHub"))
}

/// A tracker issue's title without its key: "NW-412 Fix rounding" is "Fix
/// rounding".
fn without_issue_key(title: &str) -> &str {
    let mut words = title.splitn(2, ' ');
    let key = words.next().unwrap_or_default();
    let rest = words
        .next()
        .unwrap_or_default()
        .trim_start_matches(['-', ':', ' ']);
    let is_key = key.split_once('-').is_some_and(|(team, number)| {
        !team.is_empty()
            && team
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
            && !number.is_empty()
            && number.bytes().all(|b| b.is_ascii_digit())
    });
    if is_key && !rest.is_empty() {
        rest
    } else {
        title
    }
}

/// An email subject without its reply and forward marks: "Fwd: Re: Launch
/// plan" is "Launch plan".
fn without_reply_marks(subject: &str) -> &str {
    let mut rest = subject.trim();
    loop {
        let lower = rest.to_lowercase();
        let Some(mark) = ["re:", "fwd:", "fw:", "aw:", "wg:", "tr:"]
            .iter()
            .find(|mark| lower.starts_with(**mark))
        else {
            return rest;
        };
        rest = rest[mark.len()..].trim_start();
    }
}

fn is_mailbox(subject: &str) -> bool {
    let lower = subject.trim().to_lowercase();
    let lower = lower.split(" (").next().unwrap_or(&lower).trim();
    MAILBOXES.contains(&lower)
}

fn is_slack_view(title: &str) -> bool {
    let lower = title.trim().to_lowercase();
    let lower = lower.split(" (").next().unwrap_or(&lower).trim();
    SLACK_VIEWS.contains(&lower) || lower.starts_with("huddle") || lower.starts_with("search")
}

/// Whether a window title's part names no page of its own: the app's or a
/// site's name ("Notes", "Zoom Workplace", "Activity Monitor (All
/// Processes)"), or a blank page ("New Tab").
fn says_nothing(part: &str, app_name: &str) -> bool {
    let lower = part.trim().to_lowercase();
    let bare = lower.split(" (").next().unwrap_or(&lower).trim();
    let app = app_name.to_lowercase();
    bare.is_empty()
        || bare == app
        || BLANK_PAGES.contains(&bare)
        || TITLE_SUFFIXES.contains(&bare)
        || bare
            .strip_prefix(&app)
            .is_some_and(|rest| ["workplace", "home", "app"].contains(&rest.trim()))
}

/// The first line of a document's text, as its name: two to eight words, at
/// most [`MAX_NAME_CHARS`] characters, not a sentence.
pub(crate) fn first_heading(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    let words = line.split_whitespace().count();
    ((1..=8).contains(&words)
        && line.chars().count() <= MAX_NAME_CHARS
        && !line.ends_with(['.', '?', '!', ':', ','])
        && line.chars().any(char::is_alphabetic))
    .then(|| line.to_owned())
}

fn is_host(host: &str, site: &str) -> bool {
    host == site || host.ends_with(&format!(".{site}"))
}

/// The query of a search page, from its address or its title.
fn search_query(moment: &Moment<'_>) -> Option<String> {
    if let Some(url) = moment.url {
        if let Some(host) = apps::host_of(url) {
            for &(site, key) in SEARCH_PAGES {
                let is_results = site != "youtube.com" || url.contains("/results");
                if is_host(&host, site) && is_results {
                    if let Some(query) = query_parameter(url, key) {
                        return Some(query);
                    }
                }
            }
        }
    }
    let title = moment.title?.trim();
    SEARCH_TITLE_ENDS.iter().find_map(|end| {
        let query = title.strip_suffix(end)?.trim();
        // " - YouTube" ends every video title too; only a results page
        // address says it was a search, so the title alone does not count.
        (*end != " - YouTube" && !query.is_empty()).then(|| query.to_owned())
    })
}

/// The decoded value of `key` in the address's query string.
fn query_parameter(url: &str, key: &str) -> Option<String> {
    let query = url.split_once('?')?.1.split('#').next()?;
    let value = query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=')?;
        (name == key).then_some(value)
    })?;
    let decoded = percent_decode(&value.replace('+', " "));
    let decoded = decoded.split_whitespace().collect::<Vec<_>>().join(" ");
    (!decoded.is_empty()).then_some(decoded)
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' && at + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[at + 1..at + 3]).ok();
            if let Some(value) = hex.and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                out.push(value);
                at += 3;
                continue;
            }
        }
        out.push(bytes[at]);
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The parts of a window title worth restating: without the status mark an
/// app puts before it, an unread count or "Edited", and without the app's or
/// a site's name at the end. Split at " - ", " — ", " – ", " | " and " · ".
pub(crate) fn title_segments(title: &str, app_name: &str) -> Vec<String> {
    let mut text = without_title_marks(title);
    if text.starts_with('(') {
        if let Some((count, rest)) = text[1..].split_once(')') {
            if !count.is_empty() && count.chars().all(|ch| ch.is_ascii_digit() || ch == '+') {
                text = rest.trim_start();
            }
        }
    }
    let mut segments: Vec<String> = Vec::new();
    let mut rest = text;
    loop {
        let next = [" - ", " \u{2014} ", " \u{2013} ", " | ", " \u{00b7} "]
            .iter()
            .filter_map(|sep| rest.find(sep).map(|at| (at, sep.len())))
            .min();
        let Some((at, len)) = next else {
            segments.push(rest.trim().to_owned());
            break;
        };
        segments.push(rest[..at].trim().to_owned());
        rest = &rest[at + len..];
    }
    let app_lower = app_name.to_lowercase();
    while segments.len() > 1 {
        let last = segments
            .last()
            .map(|s| s.to_lowercase())
            .unwrap_or_default();
        let is_name =
            last == app_lower || TITLE_SUFFIXES.contains(&last.as_str()) || last == "edited";
        if is_name {
            segments.pop();
        } else {
            break;
        }
    }
    segments.retain(|segment| !segment.is_empty() && segment.chars().any(char::is_alphanumeric));
    segments
}

/// A window's own name inside a caption. A question in sentence case reads
/// on as part of the sentence ("Reading how to type accents on a Mac"); any
/// other name keeps its own words and capitals inside curly quotes, as a
/// document's name is written in a sentence ("Working on “Q4 planning”"), so
/// a title never reads as a run of capitals.
fn named(title: &str) -> String {
    if is_question(title) {
        lower_question(&cut_name(title))
    } else {
        quoted(title)
    }
}

/// A name in curly quotes, cut short inside them past [`MAX_NAME_CHARS`].
fn quoted(name: &str) -> String {
    format!("\u{201c}{}\u{201d}", cut_name(name))
}

/// A name of at most [`MAX_NAME_CHARS`] characters, cut between words with
/// an ellipsis.
fn cut_name(name: &str) -> String {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.chars().count() <= MAX_NAME_CHARS {
        return name;
    }
    let cut: String = name.chars().take(MAX_NAME_CHARS - 1).collect();
    let cut = cut.rfind(' ').map_or(cut.as_str(), |at| &cut[..at]);
    format!(
        "{}\u{2026}",
        cut.trim_end_matches([',', ':', ';', ' ', '-', '\u{b7}'])
    )
}

const QUESTION: [&str; 13] = [
    "How", "What", "Why", "When", "Where", "Which", "Who", "Can", "Should", "Is", "Are", "Do",
    "Does",
];

/// A title that asks a question in sentence case: it starts with a question
/// word, and fewer than half of its other words (but "I") start with a
/// capital. "How We Built Our Pricing Page" and "Do Not Disturb settings
/// explained" are names, not questions.
fn is_question(text: &str) -> bool {
    let mut words = text.split_whitespace();
    if !QUESTION.contains(&words.next().unwrap_or_default()) {
        return false;
    }
    let rest: Vec<&str> = words
        .filter(|word| *word != "I" && word.chars().any(char::is_alphabetic))
        .collect();
    let capitals = rest
        .iter()
        .filter(|word| word.chars().next().is_some_and(char::is_uppercase))
        .count();
    capitals * 2 < rest.len() || rest.is_empty()
}

/// A question title reads as part of the sentence: "How to type…" becomes
/// "how to type…" after "Reading" or "Looking up".
fn lower_question(text: &str) -> String {
    if QUESTION.contains(&text.split_whitespace().next().unwrap_or_default()) {
        let mut chars = text.chars();
        chars
            .next()
            .map(|ch| ch.to_lowercase().collect::<String>() + chars.as_str())
            .unwrap_or_default()
    } else {
        text.to_owned()
    }
}

fn looks_like_a_shell_title(title: &str) -> bool {
    let lower = title.to_lowercase();
    title.contains('@')
        || title.starts_with('~')
        || title.starts_with('/')
        || ["zsh", "bash", "fish", "-zsh", "-bash"].contains(&lower.as_str())
}

fn is_generic_ai_title(title: &str) -> bool {
    let lower = title.to_lowercase();
    [
        "new chat",
        "claude",
        "chatgpt",
        "perplexity",
        "gemini",
        "new conversation",
        "codex",
    ]
    .contains(&lower.as_str())
}

/// The AI tool's name: the app's, or the site's for a browser tab.
fn ai_name(app_name: &str, host: &str) -> String {
    match host {
        "claude.ai" => "Claude".to_owned(),
        "chatgpt.com" => "ChatGPT".to_owned(),
        "gemini.google.com" => "Gemini".to_owned(),
        "perplexity.ai" => "Perplexity".to_owned(),
        _ => app_name.to_owned(),
    }
}

/// One line, at most [`MAX_CHARS`] characters cut between words, starting
/// with a capital, unless the secret check stops it.
fn finish(line: &str) -> Option<String> {
    let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut line = if line.chars().count() > MAX_CHARS {
        // Room for the ellipsis, and for the closing quote of a name cut short.
        let cut: String = line.chars().take(MAX_CHARS - 2).collect();
        let cut = cut.rfind(' ').map_or(cut.as_str(), |at| &cut[..at]);
        let mut cut = format!(
            "{}\u{2026}",
            cut.trim_end_matches([',', ':', ';', ' ', '-'])
        );
        if cut.matches('\u{201c}').count() > cut.matches('\u{201d}').count() {
            cut.push('\u{201d}');
        }
        cut
    } else {
        line
    };
    if let Some(first) = line.chars().next() {
        let upper: String = first.to_uppercase().collect();
        line.replace_range(..first.len_utf8(), &upper);
    }
    (!line.trim().is_empty() && !contains_secret(&line)).then_some(line)
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/// A line the model wrote, as it may be shown: one line of two to ten words
/// and at most [`MAX_CHARS`] characters, without quotes or a final period,
/// starting with a capital. `None` when the moment is beside the window in
/// use or in a sensitive area; when the line says something about the
/// person, is not grounded in the moment, names nothing the title does not
/// (the caption made from the title says it as well), speaks of a call the
/// moment does not show, or holds a secret pattern.
#[must_use]
pub fn accept(line: &str, moment: &Moment<'_>) -> Option<String> {
    let line = line.lines().find(|line| !line.trim().is_empty())?;
    let line = line
        .trim()
        .trim_matches([
            '"', '\'', '\u{201c}', '\u{201d}', '\u{2018}', '\u{2019}', '`',
        ])
        .trim()
        .trim_end_matches(['.', '!', '\u{3002}'])
        .trim();
    let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
    let words = line.split_whitespace().count();
    if !(2..=10).contains(&words) || line.chars().count() > MAX_CHARS {
        return None;
    }
    if moment.beside
        || about_the_person(&line)
        || is_sensitive(moment)
        || contains_secret(&line)
        || !is_grounded(&line, moment)
        || !names_something_new(&line, moment)
        || (mentions_a_call(&line) && !in_a_call(moment))
    {
        return None;
    }
    Some(capitalized(&line))
}

fn capitalized(line: &str) -> String {
    let mut chars = line.chars();
    chars
        .next()
        .map(|ch| ch.to_uppercase().collect::<String>() + chars.as_str())
        .unwrap_or_default()
}

/// Whether the caption points at the person or touches their feelings, work
/// life, health, money, relationships, beliefs or identity.
#[must_use]
pub fn about_the_person(caption: &str) -> bool {
    sensitive_area(caption).is_some()
        || words(caption).any(|word| {
            let word = word.trim_end_matches("'s").trim_end_matches("\u{2019}s");
            PERSON_WORDS.contains(&word)
                || SENSITIVE_WORDS.contains(&word)
                || SENSITIVE_STARTS.iter().any(|start| word.starts_with(start))
        })
}

/// Whether the moment itself is in a sensitive area: its title, address or
/// text. The model is not asked about it, and none of its lines is used.
#[must_use]
pub fn is_sensitive(moment: &Moment<'_>) -> bool {
    [moment.title, moment.url, Some(moment.text)]
        .into_iter()
        .flatten()
        .any(|part| sensitive_area(part).is_some())
}

/// Whether a line speaks of a call or a meeting.
fn mentions_a_call(line: &str) -> bool {
    words(line).any(|word| CALL_WORDS.contains(&word.as_str()))
}

/// The words of a caption that say what the moment was about: not a verb,
/// a joining word or a general word for a screen.
fn content_words(caption: &str) -> Vec<String> {
    words(caption)
        .filter(|word| {
            let has_digit = word.chars().any(|ch| ch.is_ascii_digit());
            has_digit
                || (word.chars().count() >= 3
                    && !JOINERS.contains(&word.as_str())
                    && !VERBS.contains(&word.as_str())
                    && !GENERIC.contains(&word.as_str())
                    && !PERSON_WORDS.contains(&word.as_str()))
        })
        .collect()
}

/// Whether the line names at least one thing, and something the window's
/// title, address and app name do not: otherwise the caption made from the
/// title says it as well.
fn names_something_new(caption: &str, moment: &Moment<'_>) -> bool {
    let content = content_words(caption);
    if content.is_empty() {
        return false;
    }
    let mut said = String::new();
    for part in [moment.title, moment.url].into_iter().flatten() {
        said.push_str(part);
        said.push('\n');
    }
    if let Some(app) = moment.app {
        said.push_str(&apps::name(app));
    }
    let said = said.to_lowercase();
    let stems: HashSet<String> = words(&said).map(|word| stem(&word)).collect();
    content.iter().any(|word| !stems.contains(&stem(word)))
}

/// Whether every word of `caption` that says what the moment was about comes
/// from the moment: its title, address, app name or text. Verbs, joining words
/// and general words for a screen ([`VERBS`], [`JOINERS`], [`GENERIC`]) need
/// not. A word matches when its stem matches a source word's stem, or, from
/// five letters, when a source word holds it.
#[must_use]
pub fn is_grounded(caption: &str, moment: &Moment<'_>) -> bool {
    let mut sources = String::new();
    for part in [moment.title, moment.url, Some(moment.text)]
        .into_iter()
        .flatten()
    {
        sources.push_str(part);
        sources.push('\n');
    }
    if let Some(app) = moment.app {
        sources.push_str(&apps::name(app));
    }
    let lower = sources.to_lowercase();
    let stems: HashSet<String> = words(&lower).map(|word| stem(&word)).collect();
    words(caption).all(|word| {
        let has_digit = word.chars().any(|ch| ch.is_ascii_digit());
        if !has_digit
            && (word.chars().count() < 3
                || JOINERS.contains(&word.as_str())
                || VERBS.contains(&word.as_str())
                || GENERIC.contains(&word.as_str()))
        {
            return true;
        }
        stems.contains(&stem(&word))
            || (word.chars().count() >= 5 && lower.contains(word.as_str()))
            || (has_digit && lower.contains(word.as_str()))
    })
}

/// The lower-case words of `text`: runs of letters, digits and apostrophes.
fn words(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|ch: char| !(ch.is_alphanumeric() || ch == '\'' || ch == '\u{2019}' || ch == '.'))
        .map(|word| word.trim_matches(|ch: char| ch == '.' || ch == '\'' || ch == '\u{2019}'))
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
}

/// A rough stem, so "planning" matches "plan" and "layouts" matches "layout".
fn stem(word: &str) -> String {
    let mut word = word
        .trim_end_matches("'s")
        .trim_end_matches("\u{2019}s")
        .to_owned();
    for suffix in ["ing", "ed", "es", "s"] {
        if word.len() > suffix.len() + 2 && word.ends_with(suffix) {
            word.truncate(word.len() - suffix.len());
            break;
        }
    }
    let bytes = word.as_bytes();
    if bytes.len() >= 4
        && bytes[bytes.len() - 1] == bytes[bytes.len() - 2]
        && !b"aeiou".contains(&bytes[bytes.len() - 1])
    {
        word.pop();
    }
    if word.len() > 3 && word.ends_with('e') {
        word.pop();
    }
    word
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stems_match_the_forms_a_caption_uses() {
        assert_eq!(stem("planning"), stem("plan"));
        assert_eq!(stem("layouts"), stem("layout"));
        assert_eq!(stem("writing"), stem("write"));
        assert_eq!(stem("designed"), stem("design"));
    }

    #[test]
    fn percent_decoding_reads_a_query() {
        assert_eq!(
            query_parameter("https://www.google.com/search?q=type+accents%3F&oq=x", "q").as_deref(),
            Some("type accents?")
        );
        assert_eq!(
            query_parameter("https://www.google.com/search?oq=x", "q"),
            None
        );
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn titles_lose_counts_marks_and_app_names() {
        assert_eq!(title_segments("(3) Inbox - Gmail", "Chrome"), vec!["Inbox"]);
        assert_eq!(
            title_segments(
                "\u{25cf} tax.rs \u{2014} trailhead-shop \u{2014} Visual Studio Code",
                "VS Code"
            ),
            vec!["tax.rs", "trailhead-shop"]
        );
        assert_eq!(
            title_segments("launch-plan (Channel) - Northwind Studio - Slack", "Slack"),
            vec!["launch-plan (Channel)", "Northwind Studio"]
        );
        assert_eq!(
            title_segments(
                "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{d7}40",
                "Terminal"
            ),
            vec!["Fix rounding in tax.rs", "claude", "160\u{d7}40"]
        );
        assert_eq!(
            title_segments("\u{2810} Fix rounding in tax.rs", "Terminal"),
            vec!["Fix rounding in tax.rs"]
        );
    }

    #[test]
    fn questions_are_in_sentence_case() {
        assert!(is_question("How to type accents on a Mac"));
        assert!(is_question("Should you charge per seat?"));
        assert!(!is_question("How We Built Our Pricing Page"));
        assert!(!is_question("Do Not Disturb settings explained"));
        assert!(!is_question("Who We Are"));
    }

    #[test]
    fn long_names_are_cut_inside_their_quotes() {
        let name = quoted("The surprisingly long history of rounding rules in accounting");
        assert!(name.ends_with("\u{2026}\u{201d}"), "{name}");
        assert!(name.chars().count() <= MAX_NAME_CHARS + 2, "{name}");
    }
}
