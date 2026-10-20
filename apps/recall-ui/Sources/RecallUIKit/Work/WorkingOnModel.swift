import Foundation

/// One group of Working On's Show All (SPEC 3.3).
public struct WorkingOnGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Worked on in the last 7 days of use.
        case thisWeek
        /// Before that, while any of its moments are kept.
        case earlier
        /// Hidden by the person, or named like something personal: closed
        /// by default.
        case notShown
    }

    public let kind: Kind
    public let items: [WorkItem]

    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .thisWeek: WorkCopy.thisWeek
        case .earlier: WorkCopy.earlier
        case .notShown: WorkCopy.notShownInSidebar(count: items.count)
        }
    }
}

/// What the sidebar's Working On section lists (SPEC 2.3): the items the
/// work read puts there, without the ones the person hid and with personal
/// names they chose to show, five at most, in the read's order (most time
/// this week first).
public struct WorkingOnSidebar: Equatable, Sendable {
    public let items: [WorkItem]
    /// Show All appears when there are more items than shown, or any are
    /// hidden.
    public let showsAll: Bool
    /// How many items Show All holds, for VoiceOver.
    public let total: Int

    /// `shown`: names that look personal the person chose Show in Sidebar
    /// for (the window keeps them, keyed, beside its hides).
    public init(_ snapshot: WorkSnapshot, hidden: Set<String> = [], shown: Set<String> = []) {
        let listed = snapshot.items.filter { $0.inSidebar(hidden: hidden, shown: shown) }
        items = Array(listed.prefix(SidebarModel.maxWorkingOnRows))
        total = snapshot.items.count
        showsAll = snapshot.items.count > items.count
    }

    /// The ids the sidebar model takes (`SidebarModel.workingOn`).
    public var ids: [String] { items.map(\.id) }
}

/// Working On, all of it (SPEC 3.3, SPEC-DELTA 2): every project and
/// document by name as a card, in This week, Earlier, and what isn't in the
/// sidebar. It reads the work read when it opens and every two minutes
/// while shown, and again after any delete.
@MainActor
public final class WorkingOnModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var snapshot: WorkSnapshot = .empty
    /// What the field filters names by.
    @Published public var filter = ""

    private let reader: any WorkReader
    private let days: Int

    public init(reader: any WorkReader, days: Int = 90) {
        self.reader = reader
        self.days = days
    }

    /// Read again. A read that fails keeps what was shown, and says so only
    /// when there was nothing.
    public func reload() async {
        do {
            let snapshot = try await reader.work(days: days)
            self.snapshot = snapshot
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            if snapshot.items.isEmpty { state = .failed }
        }
    }

    /// The groups to show, filtered by the field, with the person's hides
    /// and the personal names they showed.
    public func groups(hidden: Set<String>, shown: Set<String> = []) -> [WorkingOnGroup] {
        Self.groups(snapshot.items.filter { Self.matches($0, filter) }, hidden: hidden, shown: shown)
    }

    /// Items as Show All groups them: hidden and personal ones apart, then
    /// this week's and earlier ones, in the read's order.
    public static func groups(_ items: [WorkItem], hidden: Set<String>, shown: Set<String> = []) -> [WorkingOnGroup] {
        let notShown = items.filter { $0.isKeptOut(hidden: hidden, shown: shown) }
        let listed = items.filter { !$0.isKeptOut(hidden: hidden, shown: shown) }
        return [
            WorkingOnGroup(kind: .thisWeek, items: listed.filter { $0.weekMinutes > 0 }),
            WorkingOnGroup(kind: .earlier, items: listed.filter { $0.weekMinutes == 0 }),
            WorkingOnGroup(kind: .notShown, items: notShown),
        ].filter { !$0.items.isEmpty }
    }

    /// Whether a name matches what was typed, ignoring case and accents.
    public static func matches(_ item: WorkItem, _ filter: String) -> Bool {
        let wanted = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return true }
        return item.name.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Why an item isn't in the sidebar, in Show All's words.
    public static func whyNotShown(_ item: WorkItem, hidden: Set<String>, shown: Set<String> = []) -> String? {
        if hidden.contains(item.id) { return WorkCopy.youHidIt }
        if item.looksPersonal, !shown.contains(item.id) { return WorkCopy.looksPersonal }
        return nil
    }
}
