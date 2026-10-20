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

    public init(kindsWithMoments: Set<SidebarPlace> = [], workingOn: [String] = [], hasMoreWorkingOn: Bool = false) {
        self.kindsWithMoments = kindsWithMoments
        self.workingOn = workingOn
        self.hasMoreWorkingOn = hasMoreWorkingOn
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
}
