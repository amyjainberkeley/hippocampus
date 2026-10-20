import Foundation

/// The kinds of moment, from one set of rules: History's lenses in Library
/// (Documents, Code, Conversations; SPEC-DELTA 1) and the six words and
/// colours of Today's day strip (SPEC 2.14) both read them here, so a moment
/// in VS Code is "Code" on the strip, in the legend and in Library alike.
///
/// The kind of work an app means is the agent's own table (`CATALOG` and
/// `kind_for_host` in core/brain/src/apps.rs), mirrored because the window
/// reads moments, not the agent's sessions. `MomentKindsTests` holds the two
/// tables equal, so they can never drift apart. Nothing here is guessed from
/// what a window said: only its app, its page's host and, for a browser
/// without a page address, the ending its title carries.
public enum MomentKinds {
    /// The agent's app table, in its order: bundle id and the kind of work
    /// it means. Ids are compared without regard to case, as the agent does.
    public static let catalog: [(bundleId: String, kind: WorkKind)] = [
        ("com.tinyspeck.slackmacgap", .communication),
        ("com.apple.MobileSMS", .communication),
        ("com.apple.mail", .communication),
        ("com.microsoft.Outlook", .communication),
        ("com.hnc.Discord", .communication),
        ("net.whatsapp.WhatsApp", .communication),
        ("ru.keepcoder.Telegram", .communication),
        ("com.superhuman.electron", .communication),
        ("us.zoom.xos", .meetings),
        ("com.microsoft.teams2", .meetings),
        ("com.microsoft.teams", .meetings),
        ("com.apple.FaceTime", .meetings),
        ("com.cisco.webexmeetingsapp", .meetings),
        ("com.microsoft.VSCode", .code),
        ("com.todesktop.230313mzl4w4u92", .code),
        ("com.apple.dt.Xcode", .code),
        ("com.apple.Terminal", .code),
        ("com.googlecode.iterm2", .code),
        ("com.mitchellh.ghostty", .code),
        ("dev.warp.Warp-Stable", .code),
        ("dev.zed.Zed", .code),
        ("com.jetbrains.intellij", .code),
        ("com.jetbrains.pycharm", .code),
        ("com.google.android.studio", .code),
        ("com.microsoft.VSCodeInsiders", .code),
        ("com.vscodium", .code),
        ("com.exafunction.windsurf", .code),
        ("com.sublimetext.4", .code),
        ("net.kovidgoyal.kitty", .code),
        ("com.github.wez.wezterm", .code),
        ("org.alacritty", .code),
        ("co.zeit.hyper", .code),
        ("com.apple.iphonesimulator", .code),
        ("com.docker.docker", .code),
        ("com.postmanlabs.mac", .code),
        ("com.github.GitHubClient", .code),
        ("com.apple.Notes", .writing),
        ("com.apple.TextEdit", .writing),
        ("com.apple.iWork.Pages", .writing),
        ("com.microsoft.Word", .writing),
        ("md.obsidian", .writing),
        ("notion.id", .writing),
        ("com.ulyssesapp.mac", .writing),
        ("net.shinyfrog.bear", .writing),
        ("com.google.Chrome", .research),
        ("com.google.Chrome.beta", .research),
        ("com.google.Chrome.dev", .research),
        ("com.google.Chrome.canary", .research),
        ("org.chromium.Chromium", .research),
        ("com.apple.Safari", .research),
        ("com.apple.SafariTechnologyPreview", .research),
        ("company.thebrowser.Browser", .research),
        ("com.brave.Browser", .research),
        ("com.microsoft.edgemac", .research),
        ("org.mozilla.firefox", .research),
        ("company.thebrowser.dia", .research),
        ("com.operasoftware.Opera", .research),
        ("com.vivaldi.Vivaldi", .research),
        ("com.kagi.kagimacOS", .research),
        ("app.zen-browser.zen", .research),
        ("com.apple.iBooksX", .research),
        ("com.apple.news", .research),
        ("com.apple.Preview", .research),
        ("com.readdle.PDFExpert-Mac", .research),
        ("com.figma.Desktop", .design),
        ("com.bohemiancoding.sketch3", .design),
        ("com.adobe.Photoshop", .design),
        ("com.openai.chat", .ai),
        ("com.openai.codex", .ai),
        ("com.anthropic.claudefordesktop", .ai),
        ("com.anthropic.claude-code", .ai),
        ("ai.perplexity.mac", .ai),
        ("com.apple.iCal", .planning),
        ("com.apple.reminders", .planning),
        ("com.culturedcode.ThingsMac", .planning),
        ("com.linear", .planning),
        ("com.apple.iWork.Numbers", .planning),
        ("com.microsoft.Excel", .planning),
        ("com.apple.iWork.Keynote", .writing),
        ("com.microsoft.Powerpoint", .writing),
        ("com.spotify.client", .media),
        ("com.apple.Music", .media),
        ("com.apple.TV", .media),
        ("com.apple.podcasts", .media),
        ("com.apple.QuickTimePlayerX", .media),
        ("com.apple.Photos", .media),
        ("com.apple.finder", .other),
        ("com.apple.systempreferences", .other),
        ("com.apple.ActivityMonitor", .other),
        ("com.apple.AppStore", .other),
        ("com.apple.calculator", .other),
        ("com.apple.AddressBook", .other),
        ("com.apple.Maps", .other),
        ("com.apple.weather", .other),
        ("com.apple.clock", .other),
        ("com.apple.shortcuts", .other),
        ("com.apple.Console", .other),
        ("com.apple.DiskUtility", .other),
        ("com.apple.keychainaccess", .other),
        ("com.apple.Passwords", .other),
        ("com.apple.freeform", .design),
        ("com.1password.1password", .other),
        ("com.raycast.macos", .other),
        ("com.adobe.illustrator", .design),
        ("com.canva.CanvaDesktop", .design),
        ("com.microsoft.onenote.mac", .writing),
        ("com.todoist.mac.Todoist", .planning),
        ("com.flexibits.fantastical2.mac", .planning),
        ("org.whispersystems.signal-desktop", .communication),
        ("org.telegram.desktop", .communication),
        ("desktop.WhatsApp", .communication),
        ("com.facebook.archon", .communication),
        ("com.tencent.xinWeChat", .communication),
        ("com.readdle.smartemail-Mac", .communication),
    ]

    private static let kindsById: [String: WorkKind] = Dictionary(
        catalog.map { ($0.bundleId.lowercased(), $0.kind) }, uniquingKeysWith: { first, _ in first })

    /// The web browsers in the table: a moment in one is a web page unless
    /// its page says it is mail, a document, code or a call.
    public static let browsers: [String] = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "company.thebrowser.dia", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
        "app.zen-browser.zen",
    ]

    private static let browserIds = Set(browsers.map { $0.lowercased() })

    /// PDF readers: their windows are documents (SPEC 3.12.1), though the
    /// agent counts Preview and PDF Expert as reading.
    public static let pdfReaders: [String] = [
        "com.apple.Preview", "com.readdle.PDFExpert-Mac", "com.adobe.Acrobat.Pro", "com.adobe.Reader",
    ]

    /// Spreadsheets: documents too (SPEC 3.12.1), though the agent counts
    /// them as planning.
    public static let spreadsheets: [String] = ["com.apple.iWork.Numbers", "com.microsoft.Excel"]

    /// Mail apps: Conversations' "Email".
    public static let mailApps: [String] = [
        "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.smartemail-Mac",
    ]

    /// Whether `bundleId` is a web browser.
    public static func isBrowser(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return browserIds.contains(bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The kind of work an app means (`apps::kind`): other when the table
    /// does not list it.
    public static func workKind(bundleId: String?) -> WorkKind {
        guard let id = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty
        else { return .other }
        return kindsById[id] ?? .other
    }

    /// The kind of work, refined by the page for a browser
    /// (`apps::kind_for_host`): mail, chat, documents, code hosts, calls and
    /// AI tools in a tab count as those.
    public static func workKind(bundleId: String?, host: String?) -> WorkKind {
        let base = workKind(bundleId: bundleId)
        guard base == .research, var host = host?.lowercased(), !host.isEmpty else { return base }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        func `is`(_ suffix: String) -> Bool { host == suffix || host.hasSuffix("." + suffix) }
        if ["mail.google.com", "outlook.live.com", "outlook.office.com", "app.slack.com", "discord.com",
            "web.whatsapp.com"].contains(where: `is`) {
            return .communication
        }
        if ["meet.google.com", "zoom.us", "teams.microsoft.com"].contains(where: `is`) { return .meetings }
        if ["docs.google.com", "notion.so", "coda.io", "quip.com", "dropbox.com"].contains(where: `is`) {
            return .writing
        }
        if ["github.com", "gitlab.com", "vercel.com", "localhost", "stackblitz.com"].contains(where: `is`) {
            return .code
        }
        if ["chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai"].contains(where: `is`) { return .ai }
        if ["figma.com", "canva.com"].contains(where: `is`) { return .design }
        if ["calendar.google.com", "linear.app", "asana.com", "trello.com", "sheets.google.com"]
            .contains(where: `is`) {
            return .planning
        }
        if ["youtube.com", "netflix.com", "spotify.com"].contains(where: `is`) { return .media }
        return base
    }

    /// A moment's kind of work: its app, and its page's host in a browser.
    public static func workKind(of hit: Hit) -> WorkKind {
        workKind(bundleId: hit.appBundleId, host: hit.url.flatMap(host(of:)))
    }

    /// The host of an http(s) address, lowercased, without its port or
    /// `www.` (`apps::host_of`). Nil for anything else.
    public static func host(of url: String) -> String? {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest: Substring
        if lower.lowercased().hasPrefix("https://") {
            rest = lower.dropFirst(8)
        } else if lower.lowercased().hasPrefix("http://") {
            rest = lower.dropFirst(7)
        } else {
            return nil
        }
        guard let authority = rest.split(whereSeparator: { "/?#".contains($0) }).first,
              let name = authority.split(separator: ":").first
        else { return nil }
        var host = name.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// For a browser moment with no page address, what its title's ending
    /// says the page is ("Q4 planning - Google Docs", "Inbox (3) - Gmail").
    /// Nil when it says nothing; a title is never read for more than that.
    static func titleKind(_ hit: Hit) -> WorkKind? {
        guard isBrowser(hit.appBundleId), hit.url?.isEmpty ?? true,
              let title = hit.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let documents = [" - Google Docs", " - Google Sheets", " - Google Slides", " \u{2013} Figma", " - Figma"]
        if documents.contains(where: { title.hasSuffix($0) }) { return .writing }
        let mail = [" - Gmail", " - Outlook"]
        if mail.contains(where: { title.hasSuffix($0) }) { return .communication }
        if title.hasSuffix(" - Slack") { return .communication }
        return nil
    }
}

/// The day strip's six kinds, in the sidebar's words (SPEC 2.14): the
/// agent's ten kinds of work fold into them, so the legend says Code,
/// Documents, Conversations, Web Pages, Calls and Other, never Writing,
/// Design or Research.
public enum StripKind: String, CaseIterable, Sendable, Hashable {
    case code, documents, conversations, webPages, calls, other

    public init(_ kind: WorkKind) {
        switch kind {
        case .code: self = .code
        case .writing, .design, .planning: self = .documents
        case .communication, .ai: self = .conversations
        case .research: self = .webPages
        case .meetings: self = .calls
        case .media, .other: self = .other
        }
    }

    /// The legend's word.
    public var title: String {
        switch self {
        case .code: NavigationCopy.code
        case .documents: NavigationCopy.documents
        case .conversations: NavigationCopy.conversations
        case .webPages: NavigationCopy.webPages
        case .calls: UserFacingCopy.Overview.calls
        case .other: UserFacingCopy.Overview.other
        }
    }
}

/// One of History's lenses in Library (SPEC-DELTA 1): History's own rows and
/// detail, filtered by kind, like Photos' Media Types. There is no separate
/// data, and nothing History doesn't have.
public enum LibraryLens: String, CaseIterable, Sendable, Hashable, Identifiable {
    case documents, code, conversations

    public var id: String { rawValue }

    /// Its row in the sidebar.
    public var place: SidebarPlace {
        switch self {
        case .documents: .documents
        case .code: .code
        case .conversations: .conversations
        }
    }

    /// The lens a sidebar place is, when it is one of these three.
    public init?(place: SidebarPlace) {
        guard let lens = Self.allCases.first(where: { $0.place == place }) else { return nil }
        self = lens
    }

    /// Whether `hit` is one of this lens's moments.
    public func includes(_ hit: Hit) -> Bool {
        Self.lens(of: hit) == self
    }

    /// The lens a moment belongs to, if any. Docs, notes, slides, designs,
    /// sheets and PDFs are documents; editors, terminals and code hosts are
    /// code; chats, mail and AI chats are conversations. Planning tools
    /// (calendars, to-do lists), calls, media and plain web pages are none.
    public static func lens(of hit: Hit) -> LibraryLens? {
        let id = hit.appBundleId?.lowercased() ?? ""
        if MomentKinds.pdfReaders.contains(where: { $0.lowercased() == id })
            || MomentKinds.spreadsheets.contains(where: { $0.lowercased() == id }) {
            return .documents
        }
        let kind = MomentKinds.titleKind(hit) ?? MomentKinds.workKind(of: hit)
        switch kind {
        case .writing, .design: return .documents
        case .code: return .code
        case .communication, .ai: return .conversations
        case .planning:
            // Google Sheets is a document; a calendar or a to-do list isn't.
            if let host = hit.url.flatMap(MomentKinds.host(of:)), host == "sheets.google.com" { return .documents }
            return nil
        case .meetings, .research, .media, .other:
            return nil
        }
    }

    /// The apps whose every moment belongs to this lens, for a browse the
    /// memory filters itself (at most 32, the reader's limit). Browsers are
    /// read on their own and kept by their page.
    public var apps: [String] {
        let native = MomentKinds.catalog.filter { entry in
            !MomentKinds.isBrowser(entry.bundleId) && Self.nativeLens(entry.kind) == self
        }.map(\.bundleId)
        switch self {
        case .documents: return native + MomentKinds.pdfReaders.filter { !native.contains($0) }
            + MomentKinds.spreadsheets.filter { !native.contains($0) }
        case .code, .conversations: return native
        }
    }

    private static func nativeLens(_ kind: WorkKind) -> LibraryLens? {
        switch kind {
        case .writing, .design: .documents
        case .code: .code
        case .communication, .ai: .conversations
        case .meetings, .research, .planning, .media, .other: nil
        }
    }

    /// The page's title: the sidebar's word.
    public var title: String { place.title }
}

/// Conversations' chips: what kind of conversation a row is.
public enum ConversationFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case all, chat, email, ai

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: LibraryCopy.Conversations.all
        case .chat: LibraryCopy.Conversations.chat
        case .email: LibraryCopy.Conversations.email
        case .ai: LibraryCopy.Conversations.ai
        }
    }

    /// Whether a conversation moment passes the chip.
    public func includes(_ hit: Hit) -> Bool {
        guard self != .all else { return true }
        return Self.kind(of: hit) == self
    }

    /// Chat, email or AI, for a moment in Conversations.
    public static func kind(of hit: Hit) -> ConversationFilter {
        let id = hit.appBundleId?.lowercased() ?? ""
        if MomentKinds.mailApps.contains(where: { $0.lowercased() == id }) { return .email }
        let kind = MomentKinds.titleKind(hit) ?? MomentKinds.workKind(of: hit)
        if kind == .ai { return .ai }
        if let host = hit.url.flatMap(MomentKinds.host(of:)),
           ["mail.google.com", "outlook.live.com", "outlook.office.com"].contains(where: {
               host == $0 || host.hasSuffix("." + $0)
           }) {
            return .email
        }
        if let title = hit.windowTitle, MomentKinds.isBrowser(hit.appBundleId),
           title.hasSuffix(" - Gmail") || title.hasSuffix(" - Outlook") {
            return .email
        }
        return .chat
    }
}
