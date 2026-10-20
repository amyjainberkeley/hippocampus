import Foundation

/// A page the window shows: one of its places, or a Working On item's page.
public enum WindowPage: Hashable, Sendable {
    case place(RecallPlace)
    /// A Working On item, by its id (never its name).
    case item(String)

    /// The sidebar row that is selected while this page shows: Show All
    /// for Working On; nil for an item the sidebar doesn't list.
    public func sidebarRow(listing items: [String]) -> SidebarRow? {
        switch self {
        case let .place(place):
            if place == .workingOn { return .showAll }
            return place.sidebarPlace.map(SidebarRow.place)
        case let .item(id):
            return items.contains(id) ? .workItem(id) : nil
        }
    }

    /// The page a sidebar row opens.
    public init(row: SidebarRow) {
        switch row {
        case let .place(place): self = .place(RecallPlace(place))
        case let .workItem(id): self = .item(id)
        case .showAll: self = .place(.workingOn)
        }
    }

    /// Every memory page has the field; About You, AI Tools and Privacy
    /// have none (SPEC 2.8).
    public var hasField: Bool {
        switch self {
        case let .place(place): place.hasField
        case .item: true
        }
    }

    /// A Working On page or Show All: the field searches what you're
    /// working on.
    public var isWorkingOn: Bool {
        switch self {
        case .item: true
        case let .place(place): place == .workingOn
        }
    }
}

/// Where the window is: the page, what is typed in the field and what is
/// selected, so Back returns to the page and row you came from (SPEC 2.10).
public struct WindowLocation: Equatable, Sendable {
    public var page: WindowPage
    public var query: String
    public var selectedMoment: UInt64?

    public init(page: WindowPage, query: String = "", selectedMoment: UInt64? = nil) {
        self.page = page
        self.query = query
        self.selectedMoment = selectedMoment
    }
}

/// Back and Forward (⌘[ and ⌘]) between pages, keeping the selection.
public struct NavigationHistory: Equatable, Sendable {
    /// The most pages Back remembers.
    public static let limit = 50

    public private(set) var back: [WindowLocation] = []
    public private(set) var forward: [WindowLocation] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// The window is leaving `current` for another page: Back returns to it,
    /// and Forward is cleared.
    public mutating func leave(_ current: WindowLocation) {
        if back.last != current { back.append(current) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// Back from `current`: the page before, or nil at the start.
    public mutating func goBack(from current: WindowLocation) -> WindowLocation? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        return previous
    }

    /// Forward from `current`: the page Back left, or nil.
    public mutating func goForward(from current: WindowLocation) -> WindowLocation? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        return next
    }

    /// A Working On item that is gone is never returned to.
    public mutating func forget(item id: String) {
        back.removeAll { $0.page == .item(id) }
        forward.removeAll { $0.page == .item(id) }
    }
}

/// Where the window opens (SPEC 2.16): on the page you left if that was less
/// than an hour ago, otherwise on Today. Links and the Ask panel go where
/// they say. Kept with the window's settings: a place's name or an item's
/// id, never a name.
public struct WindowOpening: @unchecked Sendable {
    /// How long the page you left is kept.
    public static let keepFor: TimeInterval = 60 * 60

    enum Key {
        static let page = "window.lastPage"
        static let leftAt = "window.lastPageLeftAt"
    }

    /// The window's own settings; nil keeps nothing (previews, renders and
    /// tests that don't ask).
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public static let shared = WindowOpening(defaults: .standard)

    /// The page to open on now.
    public func page(now: Date = Date()) -> WindowPage {
        guard let defaults,
              let raw = defaults.string(forKey: Key.page),
              let left = defaults.object(forKey: Key.leftAt) as? Double,
              now.timeIntervalSince1970 - left < Self.keepFor,
              now.timeIntervalSince1970 >= left - 60
        else { return .place(.today) }
        return Self.page(raw) ?? .place(.today)
    }

    /// The window is on `page` now (or is closing on it).
    public func remember(_ page: WindowPage, now: Date = Date()) {
        guard let defaults else { return }
        defaults.set(Self.raw(page), forKey: Key.page)
        defaults.set(now.timeIntervalSince1970, forKey: Key.leftAt)
    }

    static func raw(_ page: WindowPage) -> String {
        switch page {
        case let .place(place): "place:\(place.rawValue)"
        case let .item(id): "item:\(id)"
        }
    }

    static func page(_ raw: String) -> WindowPage? {
        if raw.hasPrefix("place:") {
            return RecallPlace(rawValue: String(raw.dropFirst(6))).map(WindowPage.place)
        }
        if raw.hasPrefix("item:") {
            let id = String(raw.dropFirst(5))
            return RecallLaunchRequest.isWorkItemId(id) ? .item(id) : nil
        }
        return nil
    }
}
