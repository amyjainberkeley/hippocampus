import Foundation

/// A fixed place the sidebar has a row for (SPEC 2.2 with SPEC-DELTA 1):
/// Today; History and the kinds of moment people already know, each a lens
/// over History; and the pinned About You, AI Tools and Privacy.
public enum SidebarPlace: String, CaseIterable, Sendable, Identifiable {
    case today
    case history
    case webPages
    case documents
    case code
    case conversations
    case lookedUp
    case aboutYou
    case aiTools
    case privacy

    public var id: String { rawValue }

    /// The row's name.
    public var title: String {
        switch self {
        case .today: NavigationCopy.today
        case .history: NavigationCopy.history
        case .webPages: NavigationCopy.webPages
        case .documents: NavigationCopy.documents
        case .code: NavigationCopy.code
        case .conversations: NavigationCopy.conversations
        case .lookedUp: NavigationCopy.lookedUp
        case .aboutYou: NavigationCopy.aboutYou
        case .aiTools: NavigationCopy.aiTools
        case .privacy: NavigationCopy.privacy
        }
    }

    /// The row's SF Symbol, drawn monochrome at the system size.
    public var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .history: "clock"
        case .webPages: "globe"
        case .documents: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .conversations: "bubble.left.and.bubble.right"
        case .lookedUp: "text.magnifyingglass"
        case .aboutYou: "person.crop.circle"
        case .aiTools: "cable.connector"
        case .privacy: "hand.raised"
        }
    }

    /// Its ⌘ key. Keys never move: a row that isn't shown yet keeps its key,
    /// which opens the page with its empty state. Privacy has none; it opens
    /// from its row and from the status menu (SPEC-DELTA 1).
    public var key: Character? {
        switch self {
        case .today: "1"
        case .history: "2"
        case .webPages: "3"
        case .documents: "4"
        case .code: "5"
        case .conversations: "6"
        case .lookedUp: "7"
        case .aboutYou: "8"
        case .aiTools: "9"
        case .privacy: nil
        }
    }

    /// The place ⌘`key` opens, shown or not.
    public init?(key: Character) {
        guard let place = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = place
    }

    /// Library's kinds, after History, in order. Each shows History's own
    /// rows and detail filtered by kind, like Photos' Media Types: there is
    /// no separate data, and nothing History doesn't have.
    public static let libraryKinds: [SidebarPlace] = [.webPages, .documents, .code, .conversations, .lookedUp]

    /// The pinned group, set apart at the bottom.
    public static let pinned: [SidebarPlace] = [.aboutYou, .aiTools, .privacy]

    /// Whether this is one of Library's kinds.
    public var isLibraryKind: Bool { Self.libraryKinds.contains(self) }
}

/// One row of the sidebar.
public enum SidebarRow: Hashable, Sendable, Identifiable {
    /// A fixed place.
    case place(SidebarPlace)
    /// A Working On item, by its id (never its name, which can be private).
    case workItem(String)
    /// Working On's Show All.
    case showAll

    public var id: String {
        switch self {
        case let .place(place): "place:\(place.rawValue)"
        case let .workItem(id): "item:\(id)"
        case .showAll: "showAll"
        }
    }
}

/// The sidebar's sections, top to bottom.
public enum SidebarSection: String, Sendable {
    /// Today.
    case top
    /// Working On's items, then Show All.
    case workingOn
    /// History, then the kinds that hold something.
    case library
    /// About You, AI Tools and Privacy, pinned at the bottom.
    case pinned
}

/// One section and its rows.
public struct SidebarGroup: Equatable, Sendable {
    public let section: SidebarSection
    public let rows: [SidebarRow]

    public init(section: SidebarSection, rows: [SidebarRow]) {
        self.section = section
        self.rows = rows
    }
}

/// One Working On item as the sidebar draws it (SPEC 2.3, SPEC-DELTA 2):
/// its name, its kind's symbol, and the moment whose kept screenshot is its
/// little picture.
public struct SidebarWorkItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: WorkItem.Kind
    public let name: String
    /// When it was last worked on, in microseconds since the epoch.
    public let lastUs: UInt64
    /// Its newest moment with a kept screenshot; nil draws the kind's symbol.
    public let thumbnailMoment: UInt64?
    /// For code, the folder it seems to be in, with `~` for home: where its
    /// Context for This Folder… starts.
    public let folderGuess: String?

    public init(id: String, kind: WorkItem.Kind, name: String, lastUs: UInt64, thumbnailMoment: UInt64? = nil,
                folderGuess: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.lastUs = lastUs
        self.thumbnailMoment = thumbnailMoment
        self.folderGuess = folderGuess
    }

    public init(_ item: WorkItem) {
        self.init(id: item.id, kind: item.kind, name: item.name, lastUs: item.lastUs,
                  thumbnailMoment: item.thumbnailMoment, folderGuess: item.folderGuess)
    }

    /// The kind's SF Symbol, monochrome (SPEC 2.2).
    public var systemImage: String {
        switch kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .design: "paintbrush.pointed"
        case .spreadsheet: "tablecells"
        }
    }
}

/// What the sidebar shows, from what the window last read (SPEC 2.2, 2.3,
/// SPEC-DELTA 1). Rows appear the first time they hold something; their keys
/// never move.
public struct SidebarModel: Equatable, Sendable {
    /// Working On shows at most this many items.
    public static let maxWorkingOnRows = 5

    /// Library's kinds that hold something now. A kind's row appears only
    /// once it has something.
    public var kindsWithMoments: Set<SidebarPlace>
    /// Working On's items for the sidebar, in order, by id.
    public var workingOn: [String]
    /// Whether Working On has more items than it shows, or hides some.
    public var hasMoreWorkingOn: Bool
    /// How each item in `workingOn` is drawn, by id.
    public var items: [String: SidebarWorkItem]
    /// Every item Working On has, shown in the sidebar or not, for Show All's
    /// VoiceOver count.
    public var allItemCount: Int
    /// Rows with the one kind of badge: a blue dot that means "this needs
    /// you" (SPEC 2.5). Only About You and AI Tools carry one.
    public var badges: Set<SidebarPlace>

    public init(kindsWithMoments: Set<SidebarPlace> = [], workingOn: [String] = [], hasMoreWorkingOn: Bool = false,
                items: [String: SidebarWorkItem] = [:], allItemCount: Int? = nil, badges: Set<SidebarPlace> = []) {
        self.kindsWithMoments = kindsWithMoments
        self.workingOn = workingOn
        self.hasMoreWorkingOn = hasMoreWorkingOn
        self.items = items
        self.allItemCount = allItemCount ?? workingOn.count
        self.badges = badges.intersection([.aboutYou, .aiTools])
    }

    /// The sections with rows, top to bottom. Working On appears with its
    /// first item; Library always has History; the pinned group is always
    /// there.
    public var groups: [SidebarGroup] {
        var groups = [SidebarGroup(section: .top, rows: [.place(.today)])]
        let items = workingOn.prefix(Self.maxWorkingOnRows).map(SidebarRow.workItem)
        if !items.isEmpty {
            let more = hasMoreWorkingOn || workingOn.count > Self.maxWorkingOnRows
            groups.append(SidebarGroup(section: .workingOn, rows: items + (more ? [.showAll] : [])))
        }
        let kinds = SidebarPlace.libraryKinds.filter(kindsWithMoments.contains).map(SidebarRow.place)
        groups.append(SidebarGroup(section: .library, rows: [.place(.history)] + kinds))
        groups.append(SidebarGroup(section: .pinned, rows: SidebarPlace.pinned.map(SidebarRow.place)))
        return groups
    }

    /// Every row, top to bottom.
    public var rows: [SidebarRow] { groups.flatMap(\.rows) }

    /// The sidebar from a `work` read, the kinds that hold something and
    /// the person's tidying (SPEC 2.3, 2.11): the items the agent puts in
    /// the sidebar, without those hidden from it; the kinds that hold
    /// something or were shown from the View menu, without those hidden.
    public static func make(
        snapshot: WorkSnapshot, kinds: Set<SidebarPlace>, hides: SidebarHides.Choices,
        badges: Set<SidebarPlace> = []
    ) -> SidebarModel {
        // Lane C's rule (SPEC 2.3, 3.2): the agent's sidebar items, without
        // those hidden, with names that look personal only once shown.
        let listed = snapshot.items.filter { $0.inSidebar(hidden: hides.hiddenItems, shown: hides.shownItems) }
        let shown = Array(listed.prefix(maxWorkingOnRows))
        let more = listed.count > shown.count
            || snapshot.items.contains { !$0.inSidebar(hidden: hides.hiddenItems, shown: hides.shownItems) }
        let visibleKinds = kinds.union(hides.shownKinds).subtracting(hides.hiddenKinds)
            .intersection(SidebarPlace.libraryKinds)
        var details: [String: SidebarWorkItem] = [:]
        for item in shown { details[item.id] = SidebarWorkItem(item) }
        return SidebarModel(kindsWithMoments: visibleKinds, workingOn: shown.map(\.id), hasMoreWorkingOn: more,
                            items: details, allItemCount: snapshot.items.count, badges: badges)
    }
}

/// Which of Library's kinds hold something (SPEC-DELTA 1): a kind's row
/// appears once History has a moment of that kind. Read from the apps
/// History holds moments of, Working On's own read, and whether a search
/// with a page address was seen. Nothing here reads a moment's text.
public enum LibraryKinds {
    /// Browsers: what was read in them is a web page.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "com.kagi.kagimacOS", "org.chromium.Chromium",
    ]

    /// Editors and terminals: code.
    public static let codeApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.sublimetext.4", "com.exafunction.windsurf",
        "com.panic.Nova", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.goland",
        "com.jetbrains.rustrover", "com.jetbrains.WebStorm", "com.google.android.studio",
    ]

    /// Docs, notes, slides, PDFs, designs and spreadsheets: documents.
    public static let documentApps: Set<String> = [
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.microsoft.Word",
        "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.Notes", "com.apple.Preview",
        "com.apple.TextEdit", "com.figma.Desktop", "notion.id", "md.obsidian", "net.shinyfrog.bear",
        "com.adobe.Acrobat.Pro", "com.adobe.Reader", "com.lukilabs.lukiapp", "com.apple.freeform",
    ]

    /// Chats, mail and AI chats: conversations.
    public static let conversationApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.apple.mail", "net.whatsapp.WhatsApp",
        "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.Outlook", "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.facebook.archon",
    ]

    /// The kinds the apps in `apps` make, with Working On's read (pages are
    /// web pages; items are code or documents) and whether a search with a
    /// page address was seen (Looked Up).
    public static func kinds(apps: [ObservedApp], snapshot: WorkSnapshot = .empty,
                             sawSearch: Bool = false) -> Set<SidebarPlace> {
        var kinds = Set<SidebarPlace>()
        for app in apps where app.count > 0 {
            let id = app.appBundleId
            if browsers.contains(id) { kinds.insert(.webPages) }
            if codeApps.contains(id) || id.hasPrefix("com.jetbrains.") { kinds.insert(.code) }
            if documentApps.contains(id) { kinds.insert(.documents) }
            if conversationApps.contains(id) { kinds.insert(.conversations) }
        }
        if !snapshot.pages.isEmpty { kinds.insert(.webPages) }
        for item in snapshot.items {
            kinds.insert(item.kind == .code ? .code : .documents)
            if item.alongside.contains(where: { $0.kind == "search" }) { kinds.insert(.lookedUp) }
            if item.alongside.contains(where: { $0.kind == "ai_chat" }) { kinds.insert(.conversations) }
        }
        if sawSearch { kinds.insert(.lookedUp) }
        return kinds
    }
}

/// What the sidebar shows now, and what waits to be shown (SPEC 2.3, 2.13):
/// a new order or a new item is applied only when the pointer is outside the
/// sidebar and no sidebar row has keyboard focus, so nothing ever moves under
/// the pointer. Reads keep coming in the meantime; the newest waits.
public struct SidebarUpdates: Equatable, Sendable {
    /// What the sidebar draws.
    public private(set) var shown: SidebarModel
    /// The newest read, waiting for the pointer and focus to leave.
    public private(set) var waiting: SidebarModel?
    /// The pointer is over the sidebar.
    public private(set) var pointerInside = false
    /// A sidebar row has keyboard focus.
    public private(set) var focusInside = false

    public init(shown: SidebarModel = SidebarModel()) {
        self.shown = shown
    }

    /// Whether a change may be drawn now.
    public var isFree: Bool { !pointerInside && !focusInside }

    /// A new read. Drawn at once while the pointer and focus are elsewhere;
    /// otherwise it waits. Returns whether what is drawn changed.
    @discardableResult
    public mutating func receive(_ model: SidebarModel) -> Bool {
        guard model != shown else {
            waiting = nil
            return false
        }
        guard isFree else {
            waiting = model
            return false
        }
        shown = model
        waiting = nil
        return true
    }

    /// A change the person made (hiding a row, Reset Sidebar): drawn at
    /// once, since the person asked for it.
    public mutating func apply(_ model: SidebarModel) {
        shown = model
        waiting = nil
    }

    /// The pointer came in or went out. Leaving draws what waited.
    @discardableResult
    public mutating func pointer(inside: Bool) -> Bool {
        pointerInside = inside
        return drawWaiting()
    }

    /// Keyboard focus came into the sidebar or went out of it.
    @discardableResult
    public mutating func focus(inside: Bool) -> Bool {
        focusInside = inside
        return drawWaiting()
    }

    private mutating func drawWaiting() -> Bool {
        guard isFree, let waiting else { return false }
        self.waiting = nil
        guard waiting != shown else { return false }
        shown = waiting
        return true
    }
}
