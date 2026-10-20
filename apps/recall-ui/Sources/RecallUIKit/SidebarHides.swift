import CryptoKit
import Foundation

/// The person's tidying of the sidebar (SPEC 2.11): what they hid, what they
/// showed from the View menu, Hide Working On, and the few things said only
/// once. Kept with the window's settings, never in memory.
///
/// A Working On item is kept by its id only. The id is the agent's keyed
/// hash of the item's kind and name (`WorkItem.id`): stable on this Mac and
/// meaningless anywhere else, so the settings file never holds a project's
/// name. Anything that is not an id's shape is refused.
public final class SidebarHides: @unchecked Sendable {
    /// What is hidden and shown, read at once.
    public struct Choices: Equatable, Sendable {
        /// Working On items hidden from the sidebar, by id.
        public var hiddenItems: Set<String> = []
        /// Working On items whose names look personal that the person
        /// showed in the sidebar anyway (Show in Sidebar), by id.
        public var shownItems: Set<String> = []
        /// Library kinds hidden from the sidebar.
        public var hiddenKinds: Set<SidebarPlace> = []
        /// Library kinds shown from the View menu before they hold anything.
        public var shownKinds: Set<SidebarPlace> = []
        /// View › Hide Working On: the section is collapsed to its header,
        /// so project names come off screen before a screen share.
        public var workingOnHidden = false
        /// Library collapsed to its header (the system disclosure).
        public var libraryCollapsed = false

        public init(hiddenItems: Set<String> = [], shownItems: Set<String> = [],
                    hiddenKinds: Set<SidebarPlace> = [], shownKinds: Set<SidebarPlace> = [],
                    workingOnHidden: Bool = false, libraryCollapsed: Bool = false) {
            self.hiddenItems = hiddenItems
            self.shownItems = shownItems
            self.hiddenKinds = hiddenKinds
            self.shownKinds = shownKinds
            self.workingOnHidden = workingOnHidden
            self.libraryCollapsed = libraryCollapsed
        }
    }

    /// Every key this keeps, in the window's defaults. The window and the
    /// menu-bar app share one bundle, so each key says it is the window's.
    enum Key {
        static let hiddenItems = "window.sidebar.hiddenItems"
        static let shownItems = "window.sidebar.shownItems"
        static let hiddenKinds = "window.sidebar.hiddenKinds"
        static let shownKinds = "window.sidebar.shownKinds"
        static let workingOnHidden = "window.sidebar.workingOnHidden"
        static let libraryCollapsed = "window.sidebar.libraryCollapsed"
        static let footnoteSaid = "window.sidebar.workingOnFootnoteSaid"
        static let sidebarLineSaid = "window.sidebar.newSidebarLineSaid"
        static let firstForgetSaid = "window.forget.firstSaid"
        static let rowAnnounced = "window.sidebar.rowAnnounced"
        static let appearedKinds = "window.sidebar.appearedKinds."
        static let all = [hiddenItems, shownItems, hiddenKinds, shownKinds, workingOnHidden, libraryCollapsed]
    }

    /// The most items kept hidden; the oldest go first.
    public static let maxHiddenItems = 500

    /// The window's own; nil keeps everything in memory (previews, renders
    /// and tests never touch a real defaults domain).
    public static let shared = SidebarHides(defaults: .standard)

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memory: [String: Any] = [:]

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    // MARK: Reading

    public var choices: Choices {
        Choices(
            hiddenItems: Set(strings(Key.hiddenItems).filter(RecallLaunchRequest.isWorkItemId)),
            shownItems: Set(strings(Key.shownItems).filter(RecallLaunchRequest.isWorkItemId)),
            hiddenKinds: Set(strings(Key.hiddenKinds).compactMap(SidebarPlace.init(rawValue:))
                .filter(\.isLibraryKind)),
            shownKinds: Set(strings(Key.shownKinds).compactMap(SidebarPlace.init(rawValue:))
                .filter(\.isLibraryKind)),
            workingOnHidden: bool(Key.workingOnHidden),
            libraryCollapsed: bool(Key.libraryCollapsed)
        )
    }

    // MARK: Hiding and showing

    /// Hide a Working On item from the sidebar. Only an id is kept; a name
    /// (anything not an id's shape) is refused.
    @discardableResult
    public func hide(item id: String) -> Bool {
        guard RecallLaunchRequest.isWorkItemId(id) else { return false }
        var items = strings(Key.hiddenItems).filter { $0 != id }
        items.append(id)
        set(Array(items.suffix(Self.maxHiddenItems)), for: Key.hiddenItems)
        set(strings(Key.shownItems).filter { $0 != id }, for: Key.shownItems)
        return true
    }

    /// Show a Working On item in the sidebar: a hidden one again, or one
    /// whose name looks personal, which the person chose to show (SPEC 3.2).
    /// Only an id is kept.
    public func show(item id: String) {
        set(strings(Key.hiddenItems).filter { $0 != id }, for: Key.hiddenItems)
        guard RecallLaunchRequest.isWorkItemId(id) else { return }
        var shown = strings(Key.shownItems).filter { $0 != id }
        shown.append(id)
        set(Array(shown.suffix(Self.maxHiddenItems)), for: Key.shownItems)
    }

    /// Hide one of Library's kinds (right-click › Hide from Sidebar).
    public func hide(kind: SidebarPlace) {
        guard kind.isLibraryKind else { return }
        set(Array(Set(strings(Key.hiddenKinds) + [kind.rawValue])).sorted(), for: Key.hiddenKinds)
        set(strings(Key.shownKinds).filter { $0 != kind.rawValue }, for: Key.shownKinds)
    }

    /// Show one of Library's kinds (View › Sidebar ▸, checked), even before
    /// it holds anything.
    public func show(kind: SidebarPlace) {
        guard kind.isLibraryKind else { return }
        set(strings(Key.hiddenKinds).filter { $0 != kind.rawValue }, for: Key.hiddenKinds)
        set(Array(Set(strings(Key.shownKinds) + [kind.rawValue])).sorted(), for: Key.shownKinds)
    }

    /// View › Hide Working On and Show Working On.
    public func setWorkingOnHidden(_ hidden: Bool) {
        set(hidden, for: Key.workingOnHidden)
    }

    public func setLibraryCollapsed(_ collapsed: Bool) {
        set(collapsed, for: Key.libraryCollapsed)
    }

    /// View › Sidebar ▸ Reset Sidebar: every hide and show goes; the rows
    /// follow what they hold again.
    public func reset() {
        for key in Key.all { remove(key) }
    }

    // MARK: Said once

    /// Working On's footnote, said the first time the section appears.
    /// True the first time it is asked for, false after.
    public func takeFootnote() -> Bool {
        takeOnce(Key.footnoteSaid)
    }

    /// Whether the one-time line about the new sidebar is still to be said.
    public var sidebarLineDue: Bool { !bool(Key.sidebarLineSaid) }

    /// The person pressed OK on the line about the new sidebar.
    public func sidebarLineSaid() { set(true, for: Key.sidebarLineSaid) }

    /// The line said the first time anyone forgets (SPEC 3.11). True the
    /// first time it is asked for, false after.
    public var firstForgetDue: Bool { !bool(Key.firstForgetSaid) }

    public func firstForgetSaid() { set(true, for: Key.firstForgetSaid) }

    /// VoiceOver says the first new sidebar row once, ever (SPEC 2.15).
    /// True the first time it is asked for, false after.
    public func takeRowAnnouncement() -> Bool {
        takeOnce(Key.rowAnnounced)
    }

    // MARK: Kinds that have appeared

    /// Library's kinds that have held something in this memory: a row that
    /// has appeared stays, so its key's page is one click away tomorrow too.
    /// Kept per memory by a hash of its path, never the path.
    public func appearedKinds(memory: String) -> Set<SidebarPlace> {
        Set(strings(Key.appearedKinds + Self.memoryKey(memory)).compactMap(SidebarPlace.init(rawValue:))
            .filter(\.isLibraryKind))
    }

    /// Remembers that `kinds` have held something in `memory`, and returns
    /// every kind that ever has.
    @discardableResult
    public func noteAppeared(_ kinds: Set<SidebarPlace>, memory: String) -> Set<SidebarPlace> {
        let known = appearedKinds(memory: memory)
        let all = known.union(kinds.filter(\.isLibraryKind))
        if all != known {
            set(all.map(\.rawValue).sorted(), for: Key.appearedKinds + Self.memoryKey(memory))
        }
        return all
    }

    /// A short hash of a memory's path: the settings name no folder.
    static func memoryKey(_ memory: String) -> String {
        SHA256.hash(data: Data(memory.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Storage

    private func strings(_ key: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let defaults { return defaults.stringArray(forKey: key) ?? [] }
        return memory[key] as? [String] ?? []
    }

    private func bool(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let defaults { return defaults.bool(forKey: key) }
        return memory[key] as? Bool ?? false
    }

    private func set(_ value: Any, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let defaults {
            defaults.set(value, forKey: key)
        } else {
            memory[key] = value
        }
    }

    private func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let defaults {
            defaults.removeObject(forKey: key)
        } else {
            memory[key] = nil
        }
    }

    private func takeOnce(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let said = defaults?.bool(forKey: key) ?? (memory[key] as? Bool ?? false)
        guard !said else { return false }
        if let defaults { defaults.set(true, forKey: key) } else { memory[key] = true }
        return true
    }
}
