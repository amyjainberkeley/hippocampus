//! App names and the kind of work an app usually means.

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
    ("com.tinyspeck.slackmacgap", "Slack", WorkKind::Communication),
    ("com.apple.MobileSMS", "Messages", WorkKind::Communication),
    ("com.apple.mail", "Mail", WorkKind::Communication),
    ("com.microsoft.Outlook", "Outlook", WorkKind::Communication),
    ("com.hnc.Discord", "Discord", WorkKind::Communication),
    ("net.whatsapp.WhatsApp", "WhatsApp", WorkKind::Communication),
    ("ru.keepcoder.Telegram", "Telegram", WorkKind::Communication),
    ("com.superhuman.electron", "Superhuman", WorkKind::Communication),
    ("us.zoom.xos", "Zoom", WorkKind::Meetings),
    ("com.microsoft.teams2", "Teams", WorkKind::Meetings),
    ("com.apple.FaceTime", "FaceTime", WorkKind::Meetings),
    ("com.microsoft.VSCode", "VS Code", WorkKind::Code),
    ("com.todesktop.230313mzl4w4u92", "Cursor", WorkKind::Code),
    ("com.apple.dt.Xcode", "Xcode", WorkKind::Code),
    ("com.apple.Terminal", "Terminal", WorkKind::Code),
    ("com.googlecode.iterm2", "iTerm", WorkKind::Code),
    ("com.mitchellh.ghostty", "Ghostty", WorkKind::Code),
    ("dev.warp.Warp-Stable", "Warp", WorkKind::Code),
    ("dev.zed.Zed", "Zed", WorkKind::Code),
    ("com.jetbrains.intellij", "IntelliJ IDEA", WorkKind::Code),
    ("com.github.GitHubClient", "GitHub Desktop", WorkKind::Code),
    ("com.apple.Notes", "Notes", WorkKind::Writing),
    ("com.apple.TextEdit", "TextEdit", WorkKind::Writing),
    ("com.apple.iWork.Pages", "Pages", WorkKind::Writing),
    ("com.microsoft.Word", "Word", WorkKind::Writing),
    ("md.obsidian", "Obsidian", WorkKind::Writing),
    ("notion.id", "Notion", WorkKind::Writing),
    ("com.ulyssesapp.mac", "Ulysses", WorkKind::Writing),
    ("net.shinyfrog.bear", "Bear", WorkKind::Writing),
    ("com.google.Chrome", "Chrome", WorkKind::Research),
    ("com.apple.Safari", "Safari", WorkKind::Research),
    ("company.thebrowser.Browser", "Arc", WorkKind::Research),
    ("com.brave.Browser", "Brave", WorkKind::Research),
    ("com.microsoft.edgemac", "Edge", WorkKind::Research),
    ("org.mozilla.firefox", "Firefox", WorkKind::Research),
    ("company.thebrowser.dia", "Dia", WorkKind::Research),
    ("com.apple.Preview", "Preview", WorkKind::Research),
    ("com.readdle.PDFExpert-Mac", "PDF Expert", WorkKind::Research),
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
    ("com.apple.finder", "Finder", WorkKind::Other),
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

/// Readable app name.
#[must_use]
pub fn name(bundle_id: &str) -> String {
    CATALOG
        .iter()
        .find(|(id, _, _)| id.eq_ignore_ascii_case(bundle_id))
        .map(|(_, name, _)| (*name).to_owned())
        .unwrap_or_else(|| {
            let last = bundle_id.rsplit('.').find(|part| !part.is_empty()).unwrap_or(bundle_id);
            let mut chars = last.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        })
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
    if is("mail.google.com") || is("outlook.live.com") || is("outlook.office.com") || is("app.slack.com") || is("discord.com") || is("web.whatsapp.com") {
        WorkKind::Communication
    } else if is("meet.google.com") || is("zoom.us") || is("teams.microsoft.com") {
        WorkKind::Meetings
    } else if is("docs.google.com") || is("notion.so") || is("coda.io") || is("quip.com") || is("dropbox.com") {
        WorkKind::Writing
    } else if is("github.com") || is("gitlab.com") || is("vercel.com") || is("localhost") || is("stackblitz.com") {
        WorkKind::Code
    } else if is("chatgpt.com") || is("claude.ai") || is("gemini.google.com") || is("perplexity.ai") {
        WorkKind::Ai
    } else if is("figma.com") || is("canva.com") {
        WorkKind::Design
    } else if is("calendar.google.com") || is("linear.app") || is("asana.com") || is("trello.com") || is("sheets.google.com") {
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
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"))?;
    let host = rest.split(['/', '?', '#']).next()?.split(':').next()?.to_ascii_lowercase();
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
        assert_eq!(kind("com.microsoft.VSCode"), WorkKind::Code);
        assert_eq!(kind_for("com.google.Chrome", Some("https://mail.google.com/mail/u/0")), WorkKind::Communication);
        assert_eq!(kind_for("com.google.Chrome", Some("https://docs.google.com/document/d/x")), WorkKind::Writing);
        assert_eq!(kind_for("com.google.Chrome", Some("https://en.wikipedia.org/wiki/Hippocampus")), WorkKind::Research);
        assert_eq!(kind_for("com.apple.Notes", Some("https://github.com")), WorkKind::Writing);
        assert_eq!(host_of("https://www.Example.com:8443/a?b"), Some("example.com".into()));
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
            assert_eq!(kind_for_host("com.google.Chrome", host.as_deref()), kind_for("com.google.Chrome", Some(url)), "{url}");
        }
        assert_eq!(kind_for_host("com.apple.Safari", None), WorkKind::Research);
        assert_eq!(kind_for_host("com.apple.Safari", Some("WWW.Figma.com")), WorkKind::Design);
        assert_eq!(WorkKind::Ai.label(), "AI tools");
        assert_eq!(WorkKind::ALL.len(), 10);
        assert!(WorkKind::ALL.windows(2).all(|pair| pair[0] < pair[1]), "declaration order");
    }
}
