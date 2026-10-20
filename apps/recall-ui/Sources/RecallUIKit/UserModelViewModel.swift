import Combine
import Foundation

/// The three lists on You (contract model-page.md section 2, RULINGS I7).
public enum ModelPageList: String, CaseIterable, Sendable {
    /// "What your AI can be told about you"
    case shared
    /// "Not sent unless your AI looks it up"
    case keptBack
    /// "Not seen lately": neither sent nor served.
    case notSeenLately
}

/// One row on You: an item, or the place an item forgotten in this window
/// stood ("Forgotten. Undo", RULINGS I8).
public enum ModelItemRow: Equatable, Sendable, Identifiable {
    case item(ModelItem)
    case forgotten(ModelItem)

    public var id: Int64 {
        switch self {
        case let .item(item), let .forgotten(item): item.id
        }
    }

    public var item: ModelItem {
        switch self {
        case let .item(item), let .forgotten(item): item
        }
    }
}

/// The items of one group, in the agent's order.
public struct ModelItemGroup: Equatable, Sendable, Identifiable {
    public let group: ModelItem.Group
    public var rows: [ModelItemRow]

    public var id: String { group.rawValue }
    /// Nil for a group the window has no title for: shown last, untitled.
    public var title: String? { UserModelGrouping.title(group) }
}

/// Groups a list's items in the order the page shows them (contract
/// model-page.md section 4): Working on, How you work, Skills, People, Where
/// you got stuck, then any group the window has no title for. Inside a group
/// the agent's order is kept.
public enum UserModelGrouping {
    /// The Working On item a line names exactly, as a whole word, ignoring
    /// case: "trailhead-shop ›" after the line (SPEC 3.7). The longest name
    /// wins, so "Trailhead pricing v3" beats "Trailhead".
    public static func item(named text: String, among items: [WorkItem]) -> WorkItem? {
        items.filter { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 3, let range = text.range(of: name, options: [.caseInsensitive]) else {
                return false
            }
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            func isWordCharacter(_ character: Character?) -> Bool {
                guard let character else { return false }
                return character.isLetter || character.isNumber || character == "-" || character == "_"
            }
            return !isWordCharacter(before) && !isWordCharacter(after)
        }
        .max { $0.name.count < $1.name.count }
    }

    public static let order: [ModelItem.Group] = [.workingOn, .howYouWork, .skills, .people, .struggles, .other]

    public static func groups(_ items: [ModelItem]) -> [ModelItemGroup] {
        order.compactMap { group in
            let rows = items.filter { $0.group == group }.map(ModelItemRow.item)
            return rows.isEmpty ? nil : ModelItemGroup(group: group, rows: rows)
        }
    }

    public static func title(_ group: ModelItem.Group) -> String? {
        switch group {
        // "Working On" means one thing in the window: the sidebar's items (SPEC 3.7).
        case .workingOn: UserFacingCopy.You.projectsAndGoals
        case .howYouWork: UserFacingCopy.groupHowYouWork
        case .skills: UserFacingCopy.groupSkills
        case .people: UserFacingCopy.groupPeople
        case .struggles: UserFacingCopy.groupStruggles
        case .other: nil
        }
    }
}

/// You: what Hippocampus understands about the person, in the exact words an
/// AI is given, with "Right" and "Forget" (spec-recall S4 and S6 as amended by
/// RULINGS I7, I8 and I10, and the model-page contract).
///
/// A verdict is written at once (`VerdictInbox`). "Right" shows "You confirmed
/// this" at once. "Forget" leaves "Forgotten. Undo" where the item stood; Undo
/// is offered while the agent has not taken the file. Verdicts the agent has
/// not applied yet stay laid over every read.
@MainActor
public final class UserModelViewModel: ObservableObject {
    public typealias Phase = UnderstandingFeed<Int, ModelPage>.Phase

    /// What the page shows when there is nothing to list, or the model is off.
    public enum State: Equatable, Sendable {
        case loading
        case unavailable
        /// Nothing learned yet, and the model can learn.
        case nothingLearned
        /// Nothing learned, because Apple Intelligence is off or cannot run here.
        case needsModel
        case ready
    }

    /// The last verdict could not be saved, so nothing changed
    /// (`UserFacingCopy.verdictNotSaved`).
    @Published public private(set) var verdictFailed = false
    @Published private var confirmedHere: Set<Int64> = []
    @Published private var forgottenHere: [Int64: Forgotten] = [:]

    public let feed: UnderstandingFeed<Int, ModelPage>
    private let verdicts: VerdictInbox
    private var feedChanges: AnyCancellable?
    private var deletionObserver: AnyCancellable?

    private struct Forgotten: Equatable {
        let item: ModelItem
        let given: VerdictInbox.Given
        let list: ModelPageList
        /// Where it stood among its group's rows, "Forgotten" rows included,
        /// when it was forgotten. Putting the rows back in this order, lowest
        /// first, puts each where it stood.
        let index: Int
    }

    /// `verdicts` has no default: the app passes the inbox the agent applies,
    /// and the preview one that writes nothing (`VerdictInbox(directory: nil)`).
    public init(
        understanding: UnderstandingReader,
        verdicts: VerdictInbox,
        deletions: MemoryDeletionSignal = .shared
    ) {
        self.verdicts = verdicts
        feed = UnderstandingFeed(deletions: deletions) { _ in
            try await understanding.modelPage()
        }
        feedChanges = feed.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        deletionObserver = deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                // What was deleted took what was learned from it.
                MainActor.assumeIsolated { self?.forgottenHere = [:] }
            }
    }

    public var phase: Phase { feed.phase }

    /// The page, with this window's verdicts laid over it.
    public var page: ModelPage? {
        guard var page = feed.value else { return nil }
        page.shared = overlay(page.shared)
        page.keptBack = overlay(page.keptBack)
        page.notSeenLately = overlay(page.notSeenLately)
        return page
    }

    public var state: State {
        switch feed.phase {
        case .idle, .loading: return .loading
        case .unavailable: return .unavailable
        case .ready:
            guard let page else { return .loading }
            let empty = page.shared.isEmpty && page.keptBack.isEmpty && page.notSeenLately.isEmpty
                && forgottenHere.isEmpty
            guard empty else { return .ready }
            return page.modelStatus.state == .unavailable ? .needsModel : .nothingLearned
        }
    }

    /// Items show, but Apple Intelligence is off, so nothing new is learned:
    /// one footer line says so.
    public var modelIsOff: Bool {
        state == .ready && page?.modelStatus.state == .unavailable
    }

    public func reload() async {
        await feed.load(0)
    }

    /// One list's groups, with "Forgotten. Undo" where a forgotten item stood.
    public func groups(_ list: ModelPageList) -> [ModelItemGroup] {
        guard let page else { return [] }
        var groups = UserModelGrouping.groups(Self.items(list, of: page))
        let forgotten = forgottenHere.values
            .filter { $0.list == list }
            .sorted { ($0.index, $0.item.id) < ($1.index, $1.item.id) }
        for entry in forgotten {
            if let at = groups.firstIndex(where: { $0.group == entry.item.group }) {
                let index = min(entry.index, groups[at].rows.count)
                groups[at].rows.insert(.forgotten(entry.item), at: index)
            } else {
                groups.append(ModelItemGroup(group: entry.item.group, rows: [.forgotten(entry.item)]))
                let order = UserModelGrouping.order
                groups.sort { order.firstIndex(of: $0.group)! < order.firstIndex(of: $1.group)! }
            }
        }
        return groups
    }

    /// "Right": written at once, and the item says "You confirmed this".
    public func confirm(_ item: ModelItem) {
        do {
            try verdicts.give(.confirm, id: item.id)
            verdictFailed = false
            confirmedHere.insert(item.id)
        } catch {
            verdictFailed = true
        }
    }

    /// "Forget": written at once; "Forgotten. Undo" stays where it stood.
    public func forget(_ item: ModelItem) {
        guard let page, forgottenHere[item.id] == nil else { return }
        guard let list = ModelPageList.allCases.first(where: { Self.items($0, of: page).contains { $0.id == item.id } })
        else { return }
        let rows = groups(list).first { $0.group == item.group }?.rows ?? []
        let index = rows.firstIndex { $0.id == item.id } ?? rows.count
        do {
            let given = try verdicts.give(.reject, id: item.id)
            verdictFailed = false
            confirmedHere.remove(item.id)
            forgottenHere[item.id] = Forgotten(item: item, given: given, list: list, index: index)
        } catch {
            verdictFailed = true
        }
    }

    /// Undo is offered only while the agent has not taken the verdict.
    public func canUndo(_ item: ModelItem) -> Bool {
        forgottenHere[item.id].map { verdicts.canUndo($0.given) } ?? false
    }

    /// Bring a forgotten item back. False once the agent has taken it.
    @discardableResult
    public func undo(_ item: ModelItem) -> Bool {
        guard let entry = forgottenHere[item.id], verdicts.undo(entry.given) else { return false }
        forgottenHere[item.id] = nil
        Task { await feed.refresh() }
        return true
    }

    private func overlay(_ items: [ModelItem]) -> [ModelItem] {
        items.compactMap { item in
            guard forgottenHere[item.id] == nil else { return nil }
            guard confirmedHere.contains(item.id) else { return item }
            var confirmed = item
            confirmed.basis = .confirmed
            return confirmed
        }
    }

    private static func items(_ list: ModelPageList, of page: ModelPage) -> [ModelItem] {
        switch list {
        case .shared: page.shared
        case .keptBack: page.keptBack
        case .notSeenLately: page.notSeenLately
        }
    }
}
