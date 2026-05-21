import Foundation

public enum FilterPill: String, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case appSafari
    case today
    case lastHour
    case hasUrl

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appSafari: return "App: Safari"
        case .today: return "Today"
        case .lastHour: return "Last hour"
        case .hasUrl: return "Has URL"
        }
    }
}

public struct FilterState: Equatable, Sendable {
    public private(set) var active: Set<FilterPill> = []

    public init() {}

    public mutating func toggle(_ pill: FilterPill) {
        if active.contains(pill) {
            active.remove(pill)
        } else {
            if pill == .today { active.remove(.lastHour) }
            if pill == .lastHour { active.remove(.today) }
            active.insert(pill)
        }
    }

    public func isActive(_ pill: FilterPill) -> Bool {
        active.contains(pill)
    }

    public var anyActive: Bool { !active.isEmpty }

    public var appFilter: String? {
        isActive(.appSafari) ? "com.apple.Safari" : nil
    }

    public func timeFromUs(now: Date = Date()) -> UInt64? {
        if isActive(.lastHour) {
            return UInt64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
        }
        if isActive(.today) {
            let start = Calendar.current.startOfDay(for: now)
            return UInt64(start.timeIntervalSince1970 * 1_000_000)
        }
        return nil
    }

    public var hasUrl: Bool { isActive(.hasUrl) }
}
