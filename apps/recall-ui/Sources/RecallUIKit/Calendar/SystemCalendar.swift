import Foundation

/// What macOS lets Hippocampus do with calendars right now.
public enum CalendarPermission: Equatable, Sendable {
    /// macOS hasn't asked the person yet.
    case notDetermined
    /// Events may be read.
    case fullAccess
    /// Events may only be added, not read ("Add Only" in System Settings).
    case addOnly
    /// The person said no, or took it back in System Settings.
    case denied
    /// This Mac doesn't let apps read calendars: it is managed, or Screen
    /// Time limits it.
    case restricted
}

/// The calendar on this Mac, as `SystemCalendar` reads it. The window's is
/// `EventKitCalendarStore`; tests and pictures pass a fake, so nothing asks
/// the real system for access.
public protocol CalendarStore: Sendable {
    /// What macOS allows now. Never asks.
    func permission() -> CalendarPermission
    /// Asks macOS for full access to events. Only `SystemCalendar.turnOn()`
    /// calls it, when the person turns the calendar on.
    func requestFullAccess() async throws -> Bool
    /// The events overlapping `interval`: only their title, time, calendar's
    /// name and location. Nothing unless full access is allowed.
    func events(in interval: DateInterval) throws -> [CalendarEvent]
}

/// The person's own calendar, read-only, through EventKit (SPEC-DELTA 5). It
/// reads only once the person has turned it on and macOS allows it, so a
/// denial, a restriction or access taken back later simply reads nothing:
/// Today drops its bars, and Preferences says how to turn it back on. Only
/// `turnOn()`, which a person's click calls, ever asks macOS.
public final class SystemCalendar: CalendarReader, @unchecked Sendable {
    /// The longest time read at once: a year, the most "when did I last
    /// meet" looks back. A longer request keeps its latest year.
    public static let longestRead: TimeInterval = 366 * 86_400
    /// The most events one read gives back.
    public static let mostEvents = 2_000

    private let store: any CalendarStore
    private let setting: CalendarSetting

    public init(store: any CalendarStore, setting: CalendarSetting = CalendarSetting()) {
        self.store = store
        self.setting = setting
    }

    /// The window's calendar: EventKit, with the choice in the app's own
    /// defaults. Demo Memory reads its made-up week instead
    /// (`DemoMemoryMode.calendarReader(fallback:)`), and the synthetic preview
    /// a `FixtureCalendar`.
    public static func live() -> SystemCalendar {
        SystemCalendar(store: EventKitCalendarStore.shared, setting: CalendarSetting())
    }

    public func access() async -> CalendarAccess {
        Self.access(choice: setting.choice, permission: store.permission())
    }

    /// The person's choice first, then what macOS allows.
    public static func access(choice: Bool?, permission: CalendarPermission) -> CalendarAccess {
        guard choice == true else { return .notAsked }
        switch permission {
        case .fullAccess: return .allowed
        case .notDetermined: return .notAsked
        case .addOnly, .denied, .restricted: return .denied
        }
    }

    public func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        guard await access() == .allowed else { return [] }
        let read = Self.bounded(interval)
        return Array(
            try store.events(in: read)
                .filter { $0.end > $0.start && $0.start < read.end && $0.end > read.start }
                .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
                .prefix(Self.mostEvents)
        )
    }

    /// `interval`, cut to its latest `longestRead`.
    static func bounded(_ interval: DateInterval) -> DateInterval {
        guard interval.duration > longestRead else { return interval }
        return DateInterval(start: interval.end.addingTimeInterval(-longestRead), end: interval.end)
    }

    /// Turns the calendar on, as Today's Show Calendar does: the person's
    /// choice is kept, and macOS is asked only if it never has been. When
    /// macOS said no before, it won't ask again, so this returns `.denied`
    /// and Preferences says how to allow it in System Settings.
    @discardableResult
    public func turnOn() async -> CalendarAccess {
        setting.set(true)
        if store.permission() == .notDetermined {
            _ = try? await store.requestFullAccess()
        }
        return await access()
    }

    /// Turns it off: nothing is read until the person turns it back on.
    public func turnOff() {
        setting.set(false)
    }

    /// Where the person allows Hippocampus to read calendars again.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!
}
