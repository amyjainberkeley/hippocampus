import Foundation

/// The person's choice to show their calendar (SPEC-DELTA 5). It lives in
/// the app's own defaults (`ai.hippocampus`), which the window shares since
/// it runs inside the app's bundle: Preferences › General and Today's Show
/// Calendar write it, and every read checks it first. It is unset until the
/// person chooses, and nothing is read before then.
public struct CalendarSetting: Sendable {
    /// The defaults key. The app keeps the same one (HippocampusKit's
    /// `CalendarSetting`), and a test holds the two together.
    public static let key = "ai.hippocampus.calendar.show"

    private let storage: Storage

    /// The choice in `defaults`: the app's own, unless a test says otherwise.
    public init(defaults: UserDefaults = .standard) {
        storage = Storage(defaults: defaults, choice: nil)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    /// A choice kept in memory only, for tests and pictures: nothing is
    /// written to disk.
    public static func inMemory(_ choice: Bool? = nil) -> CalendarSetting {
        CalendarSetting(storage: Storage(defaults: nil, choice: choice))
    }

    /// Nil until the person chooses; then whether they turned it on.
    public var choice: Bool? { storage.choice }

    /// Whether the person turned it on.
    public var isOn: Bool { choice == true }

    /// Keeps the person's choice.
    public func set(_ on: Bool) {
        storage.set(on)
    }

    private final class Storage: @unchecked Sendable {
        private let defaults: UserDefaults?
        private let lock = NSLock()
        private var memory: Bool?

        init(defaults: UserDefaults?, choice: Bool?) {
            self.defaults = defaults
            self.memory = choice
        }

        var choice: Bool? {
            if let defaults { return defaults.object(forKey: CalendarSetting.key) as? Bool }
            return lock.withLock { memory }
        }

        func set(_ on: Bool) {
            if let defaults {
                defaults.set(on, forKey: CalendarSetting.key)
            } else {
                lock.withLock { memory = on }
            }
        }
    }
}
