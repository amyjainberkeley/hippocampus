//! App names and the kind of work an app usually means.
//!
//! [`name`] is the one table of app names: captions use it, and the window
//! reads it through the FFI (`mci_brain_ffi_app_name`), so a row's caption
//! and the app named under it always agree.

use serde::{Deserialize, Serialize};

/// A coarse kind of work, for the day's breakdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkKind {
    /// Chat, mail, messages.
    Communication,
    /// Calls and meetings.
    Meetings,
    /// Editors, terminals, developer tools.
    Code,
    /// Documents, notes, writing.
    Writing,
    /// Browsing and reading.
    Research,
    /// Design and drawing.
    Design,
    /// AI tools.
    Ai,
    /// Calendars, tasks, spreadsheets, planning.
    Planning,
    /// Music, video.
    Media,
    /// Everything else.
    Other,
}

impl WorkKind {
    /// Every kind, in declaration order (the order ties are broken in).
    pub const ALL: [Self; 10] = [
        Self::Communication,
        Self::Meetings,
        Self::Code,
        Self::Writing,
        Self::Research,
        Self::Design,
        Self::Ai,
        Self::Planning,
        Self::Media,
        Self::Other,
    ];

    /// The name in JSON (`communication`, `ai`, …).
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Communication => "communication",
            Self::Meetings => "meetings",
            Self::Code => "code",
            Self::Writing => "writing",
            Self::Research => "research",
            Self::Design => "design",
            Self::Ai => "ai",
            Self::Planning => "planning",
            Self::Media => "media",
            Self::Other => "other",
        }
    }

    /// Label for people.
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Self::Communication => "Communication",
            Self::Meetings => "Meetings",
            Self::Code => "Code",
            Self::Writing => "Writing",
            Self::Research => "Research",
            Self::Design => "Design",
            Self::Ai => "AI tools",
            Self::Planning => "Planning",
            Self::Media => "Media",
            Self::Other => "Other",
        }
    }
}

const CATALOG: &[(&str, &str, WorkKind)] = &[
    (
        "com.tinyspeck.slackmacgap",
        "Slack",
        WorkKind::Communication,
    ),
    ("com.apple.MobileSMS", "Messages", WorkKind::Communication),
    ("com.apple.mail", "Mail", WorkKind::Communication),
    ("com.microsoft.Outlook", "Outlook", WorkKind::Communication),
    ("com.hnc.Discord", "Discord", WorkKind::Communication),
    ("net.whatsapp.WhatsApp", "WhatsApp", WorkKind::Communication),
    ("ru.keepcoder.Telegram", "Telegram", WorkKind::Communication),
    (
        "com.superhuman.electron",
        "Superhuman",
        WorkKind::Communication,
    ),
    ("us.zoom.xos", "Zoom", WorkKind::Meetings),
    (
        "com.microsoft.teams2",
        "Microsoft Teams",
        WorkKind::Meetings,
    ),
    ("com.microsoft.teams", "Microsoft Teams", WorkKind::Meetings),
    ("com.apple.FaceTime", "FaceTime", WorkKind::Meetings),
    ("com.cisco.webexmeetingsapp", "Webex", WorkKind::Meetings),
    ("com.microsoft.VSCode", "VS Code", WorkKind::Code),
    ("com.todesktop.230313mzl4w4u92", "Cursor", WorkKind::Code),
    ("com.apple.dt.Xcode", "Xcode", WorkKind::Code),
    ("com.apple.Terminal", "Terminal", WorkKind::Code),
    ("com.googlecode.iterm2", "iTerm", WorkKind::Code),
    ("com.mitchellh.ghostty", "Ghostty", WorkKind::Code),
    ("dev.warp.Warp-Stable", "Warp", WorkKind::Code),
    ("dev.zed.Zed", "Zed", WorkKind::Code),
    ("com.jetbrains.intellij", "IntelliJ IDEA", WorkKind::Code),
    ("com.jetbrains.pycharm", "PyCharm", WorkKind::Code),
    (
        "com.google.android.studio",
        "Android Studio",
        WorkKind::Code,
    ),
    ("com.microsoft.VSCodeInsiders", "VS Code", WorkKind::Code),
    ("com.vscodium", "VSCodium", WorkKind::Code),
    ("com.exafunction.windsurf", "Windsurf", WorkKind::Code),
    ("com.sublimetext.4", "Sublime Text", WorkKind::Code),
    ("net.kovidgoyal.kitty", "kitty", WorkKind::Code),
    ("com.github.wez.wezterm", "WezTerm", WorkKind::Code),
    ("org.alacritty", "Alacritty", WorkKind::Code),
    ("co.zeit.hyper", "Hyper", WorkKind::Code),
    ("com.apple.iphonesimulator", "Simulator", WorkKind::Code),
    ("com.docker.docker", "Docker", WorkKind::Code),
    ("com.postmanlabs.mac", "Postman", WorkKind::Code),
    ("com.github.GitHubClient", "GitHub", WorkKind::Code),
    ("com.apple.Notes", "Notes", WorkKind::Writing),
    ("com.apple.TextEdit", "TextEdit", WorkKind::Writing),
    ("com.apple.iWork.Pages", "Pages", WorkKind::Writing),
    ("com.microsoft.Word", "Word", WorkKind::Writing),
    ("md.obsidian", "Obsidian", WorkKind::Writing),
    ("notion.id", "Notion", WorkKind::Writing),
    ("com.ulyssesapp.mac", "Ulysses", WorkKind::Writing),
    ("net.shinyfrog.bear", "Bear", WorkKind::Writing),
    ("com.google.Chrome", "Chrome", WorkKind::Research),
    ("com.google.Chrome.beta", "Chrome", WorkKind::Research),
    ("com.google.Chrome.dev", "Chrome", WorkKind::Research),
    ("com.google.Chrome.canary", "Chrome", WorkKind::Research),
    ("org.chromium.Chromium", "Chromium", WorkKind::Research),
    ("com.apple.Safari", "Safari", WorkKind::Research),
    (
        "com.apple.SafariTechnologyPreview",
        "Safari",
        WorkKind::Research,
    ),
    ("company.thebrowser.Browser", "Arc", WorkKind::Research),
    ("com.brave.Browser", "Brave", WorkKind::Research),
    (
        "com.microsoft.edgemac",
        "Microsoft Edge",
        WorkKind::Research,
    ),
    ("org.mozilla.firefox", "Firefox", WorkKind::Research),
    ("company.thebrowser.dia", "Dia", WorkKind::Research),
    ("com.operasoftware.Opera", "Opera", WorkKind::Research),
    ("com.vivaldi.Vivaldi", "Vivaldi", WorkKind::Research),
    ("com.kagi.kagimacOS", "Orion", WorkKind::Research),
    ("app.zen-browser.zen", "Zen", WorkKind::Research),
    ("com.apple.iBooksX", "Books", WorkKind::Research),
    ("com.apple.news", "News", WorkKind::Research),
    ("com.apple.Preview", "Preview", WorkKind::Research),
    (
        "com.readdle.PDFExpert-Mac",
        "PDF Expert",
        WorkKind::Research,
    ),
    ("com.figma.Desktop", "Figma", WorkKind::Design),
    ("com.bohemiancoding.sketch3", "Sketch", WorkKind::Design),
    ("com.adobe.Photoshop", "Photoshop", WorkKind::Design),
    ("com.openai.chat", "ChatGPT", WorkKind::Ai),
    ("com.openai.codex", "Codex", WorkKind::Ai),
    ("com.anthropic.claudefordesktop", "Claude", WorkKind::Ai),
    ("com.anthropic.claude-code", "Claude Code", WorkKind::Ai),
    ("ai.perplexity.mac", "Perplexity", WorkKind::Ai),
    ("com.apple.iCal", "Calendar", WorkKind::Planning),
    ("com.apple.reminders", "Reminders", WorkKind::Planning),
    ("com.culturedcode.ThingsMac", "Things", WorkKind::Planning),
    ("com.linear", "Linear", WorkKind::Planning),
    ("com.apple.iWork.Numbers", "Numbers", WorkKind::Planning),
    ("com.microsoft.Excel", "Excel", WorkKind::Planning),
    ("com.apple.iWork.Keynote", "Keynote", WorkKind::Writing),
    ("com.microsoft.Powerpoint", "PowerPoint", WorkKind::Writing),
    ("com.spotify.client", "Spotify", WorkKind::Media),
    ("com.apple.Music", "Music", WorkKind::Media),
    ("com.apple.TV", "TV", WorkKind::Media),
    ("com.apple.podcasts", "Podcasts", WorkKind::Media),
    (
        "com.apple.QuickTimePlayerX",
        "QuickTime Player",
        WorkKind::Media,
    ),
    ("com.apple.Photos", "Photos", WorkKind::Media),
    ("com.apple.finder", "Finder", WorkKind::Other),
    (
        "com.apple.systempreferences",
        "System Settings",
        WorkKind::Other,
    ),
    (
        "com.apple.ActivityMonitor",
        "Activity Monitor",
        WorkKind::Other,
    ),
    ("com.apple.AppStore", "App Store", WorkKind::Other),
    ("com.apple.calculator", "Calculator", WorkKind::Other),
    ("com.apple.AddressBook", "Contacts", WorkKind::Other),
    ("com.apple.Maps", "Maps", WorkKind::Other),
    ("com.apple.weather", "Weather", WorkKind::Other),
    ("com.apple.clock", "Clock", WorkKind::Other),
    ("com.apple.shortcuts", "Shortcuts", WorkKind::Other),
    ("com.apple.Console", "Console", WorkKind::Other),
    ("com.apple.DiskUtility", "Disk Utility", WorkKind::Other),
    (
        "com.apple.keychainaccess",
        "Keychain Access",
        WorkKind::Other,
    ),
    ("com.apple.Passwords", "Passwords", WorkKind::Other),
    ("com.apple.freeform", "Freeform", WorkKind::Design),
    ("com.1password.1password", "1Password", WorkKind::Other),
    ("com.raycast.macos", "Raycast", WorkKind::Other),
    ("com.adobe.illustrator", "Illustrator", WorkKind::Design),
    ("com.canva.CanvaDesktop", "Canva", WorkKind::Design),
    ("com.microsoft.onenote.mac", "OneNote", WorkKind::Writing),
    ("com.todoist.mac.Todoist", "Todoist", WorkKind::Planning),
    (
        "com.flexibits.fantastical2.mac",
        "Fantastical",
        WorkKind::Planning,
    ),
    (
        "org.whispersystems.signal-desktop",
        "Signal",
        WorkKind::Communication,
    ),
    ("org.telegram.desktop", "Telegram", WorkKind::Communication),
    ("desktop.WhatsApp", "WhatsApp", WorkKind::Communication),
    ("com.facebook.archon", "Messenger", WorkKind::Communication),
    ("com.tencent.xinWeChat", "WeChat", WorkKind::Communication),
    (
        "com.readdle.smartemail-Mac",
        "Spark",
        WorkKind::Communication,
    ),
];

/// Names by the last part of a bundle id, for apps the catalog does not list
/// by their whole id ("com.example.seed.github" is GitHub).
const NAMES_BY_LAST_PART: &[(&str, &str)] = &[
    ("chrome", "Chrome"),
    ("github", "GitHub"),
    ("linear", "Linear"),
    ("notion", "Notion"),
    ("safari", "Safari"),
    ("slack", "Slack"),
    ("terminal", "Terminal"),
    ("vscode", "VS Code"),
    ("xcode", "Xcode"),
];

/// System surfaces that are not work: the lock screen, screen saver, Dock,
/// Control Center, notifications, Spotlight and Hippocampus itself.
#[must_use]
pub fn is_noise(bundle_id: &str) -> bool {
    const NOISE: &[&str] = &[
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.screensaver",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.usernotificationcenter",
        "com.apple.spotlight",
        "com.apple.systemuiserver",
        "com.apple.securityagent",
        "com.apple.windowmanager",
        "ai.hippocampus",
    ];
    let lowered = bundle_id.to_ascii_lowercase();
    NOISE.contains(&lowered.as_str())
}

/// The app's name when this table knows it: by its whole bundle id, or by
/// the last part of it. `None` when [`name`] could only make one from the
/// bundle id.
#[must_use]
pub fn known_name(bundle_id: &str) -> Option<&'static str> {
    let bundle_id = bundle_id.trim();
    if let Some((_, name, _)) = CATALOG
        .iter()
        .find(|(id, _, _)| id.eq_ignore_ascii_case(bundle_id))
    {
        return Some(name);
    }
    let last = bundle_id.rsplit('.').next()?.to_ascii_lowercase();
    NAMES_BY_LAST_PART
        .iter()
        .find(|(part, _)| *part == last)
        .map(|(_, name)| *name)
}

/// Readable app name: the table's ([`known_name`]), else one made from the
/// last part of the bundle id (`com.example.focus_writer` is "Focus
/// Writer"), else "Unknown app".
#[must_use]
pub fn name(bundle_id: &str) -> String {
    if let Some(name) = known_name(bundle_id) {
        return name.to_owned();
    }
    let last = bundle_id
        .trim()
        .rsplit('.')
        .find(|part| !part.is_empty())
        .unwrap_or_default();
    let words: Vec<String> = last
        .split(['-', '_', ' '])
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        })
        .collect();
    if words.is_empty() {
        "Unknown app".to_owned()
    } else {
        words.join(" ")
    }
}

/// The kind of work an app usually means. A browser counts as research
/// unless the page says otherwise (see [`kind_for`]).
#[must_use]
pub fn kind(bundle_id: &str) -> WorkKind {
    CATALOG
        .iter()
        .find(|(id, _, _)| id.eq_ignore_ascii_case(bundle_id))
        .map_or(WorkKind::Other, |(_, _, kind)| *kind)
}

/// Kind of work, refined by the page for browsers: mail, chat, docs, code
/// hosts, meetings and AI tools in a tab count as those.
#[must_use]
pub fn kind_for(bundle_id: &str, url: Option<&str>) -> WorkKind {
    kind_for_host(bundle_id, url.and_then(host_of).as_deref())
}

/// [`kind_for`] from a page's host (as [`host_of`] gives it, and as a
/// session note stores it) rather than its URL.
#[must_use]
pub fn kind_for_host(bundle_id: &str, host: Option<&str>) -> WorkKind {
    let base = kind(bundle_id);
    if base != WorkKind::Research {
        return base;
    }
    let Some(host) = host.map(str::to_ascii_lowercase) else {
        return base;
    };
    let host = host.strip_prefix("www.").unwrap_or(&host);
    let is = |suffix: &str| host == suffix || host.ends_with(&format!(".{suffix}"));
    if is("mail.google.com")
        || is("outlook.live.com")
        || is("outlook.office.com")
        || is("app.slack.com")
        || is("discord.com")
        || is("web.whatsapp.com")
    {
        WorkKind::Communication
    } else if is("meet.google.com") || is("zoom.us") || is("teams.microsoft.com") {
        WorkKind::Meetings
    } else if is("docs.google.com")
        || is("notion.so")
        || is("coda.io")
        || is("quip.com")
        || is("dropbox.com")
    {
        WorkKind::Writing
    } else if is("github.com")
        || is("gitlab.com")
        || is("vercel.com")
        || is("localhost")
        || is("stackblitz.com")
    {
        WorkKind::Code
    } else if is("chatgpt.com") || is("claude.ai") || is("gemini.google.com") || is("perplexity.ai")
    {
        WorkKind::Ai
    } else if is("figma.com") || is("canva.com") {
        WorkKind::Design
    } else if is("calendar.google.com")
        || is("linear.app")
        || is("asana.com")
        || is("trello.com")
        || is("sheets.google.com")
    {
        WorkKind::Planning
    } else if is("youtube.com") || is("netflix.com") || is("spotify.com") {
        WorkKind::Media
    } else {
        base
    }
}

/// Host of an http(s) URL, lowercased, without port or `www.`.
#[must_use]
pub fn host_of(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let host = rest
        .split(['/', '?', '#'])
        .next()?
        .split(':')
        .next()?
        .to_ascii_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host).to_owned();
    (!host.is_empty()).then_some(host)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_kinds() {
        assert_eq!(name("com.tinyspeck.slackmacgap"), "Slack");
        assert_eq!(name("com.example.widgetmaker"), "Widgetmaker");
        assert_eq!(name("com.apple.systempreferences"), "System Settings");
        assert_eq!(name("com.apple.ActivityMonitor"), "Activity Monitor");
        assert_eq!(name("com.apple.AppStore"), "App Store");
        assert_eq!(name("com.example.my-app"), "My App");
        assert_eq!(name("com.example.focus_writer"), "Focus Writer");
        assert_eq!(name("com.mci.demo.seed.github"), "GitHub");
        assert_eq!(name(""), "Unknown app");
        assert_eq!(known_name("com.example.widgetmaker"), None);
        assert_eq!(known_name("com.apple.Notes"), Some("Notes"));
        assert_eq!(kind("com.microsoft.VSCode"), WorkKind::Code);
        assert_eq!(
            kind_for(
                "com.google.Chrome",
                Some("https://mail.google.com/mail/u/0")
            ),
            WorkKind::Communication
        );
        assert_eq!(
            kind_for(
                "com.google.Chrome",
                Some("https://docs.google.com/document/d/x")
            ),
            WorkKind::Writing
        );
        assert_eq!(
            kind_for(
                "com.google.Chrome",
                Some("https://en.wikipedia.org/wiki/Hippocampus")
            ),
            WorkKind::Research
        );
        assert_eq!(
            kind_for("com.apple.Notes", Some("https://github.com")),
            WorkKind::Writing
        );
        assert_eq!(
            host_of("https://www.Example.com:8443/a?b"),
            Some("example.com".into())
        );
    }

    #[test]
    fn a_stored_host_gives_the_same_kind_as_its_url() {
        for url in [
            "https://mail.google.com/mail/u/0",
            "https://www.figma.com/file/x",
            "https://claude.ai/chat/1",
            "https://en.wikipedia.org/wiki/Hippocampus",
            "https://github.com/a/b",
        ] {
            let host = host_of(url);
            assert_eq!(
                kind_for_host("com.google.Chrome", host.as_deref()),
                kind_for("com.google.Chrome", Some(url)),
                "{url}"
            );
        }
        assert_eq!(kind_for_host("com.apple.Safari", None), WorkKind::Research);
        assert_eq!(
            kind_for_host("com.apple.Safari", Some("WWW.Figma.com")),
            WorkKind::Design
        );
        assert_eq!(WorkKind::Ai.label(), "AI tools");
        assert_eq!(WorkKind::ALL.len(), 10);
        assert!(
            WorkKind::ALL.windows(2).all(|pair| pair[0] < pair[1]),
            "declaration order"
        );
    }
}
