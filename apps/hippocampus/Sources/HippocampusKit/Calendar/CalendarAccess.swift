// SPDX-License-Identifier: Apache-2.0
//
// CalendarAccess.swift — the calendar's switch and macOS's answer, in the
// menu-bar app (SPEC-DELTA 5). The window keeps its own copy of the switch
// and the reader (RecallUIKit `CalendarSetting`, `SystemCalendar`), since the
// two share no Swift package; the same defaults key joins them.

import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// The person's choice to show their calendar, in the app's own defaults
/// (`ai.hippocampus`). The window reads the same key, since it runs inside
/// the app's bundle. Unset until the person chooses; nothing is read before.
public struct CalendarSetting: Sendable {
    /// The defaults key, the same as RecallUIKit's `CalendarSetting.key`.
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

/// One meeting, as Ask uses it: its title and its time, nothing else.
public struct CalendarMeeting: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    /// A holiday, a trip or a birthday: never a meeting Ask names.
    public let isAllDay: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// The calendar on this Mac, as the app uses it: Preferences asks macOS
/// through it, and Ask reads meetings' titles and times. The real one is
/// `EventKitCalendarAccess`; tests and pictures pass a fake, so nothing asks
/// the real system for access.
public protocol CalendarAccessStore: Sendable {
    /// What macOS allows now. Never asks.
    func permission() -> CalendarPermission
    /// Asks macOS for full access to events. Only Preferences' switch calls
    /// it, when the person turns the calendar on.
    func requestFullAccess() async throws -> Bool
    /// The meetings overlapping `interval`. Nothing unless full access is
    /// allowed.
    func meetings(in interval: DateInterval) throws -> [CalendarMeeting]
}

/// A calendar with a fixed answer from macOS, for pictures: it never touches
/// EventKit, never asks, and reads only the meetings it is given.
public struct FixedCalendarAccess: CalendarAccessStore {
    public let fixed: CalendarPermission
    public let fixtures: [CalendarMeeting]

    public init(_ permission: CalendarPermission, meetings: [CalendarMeeting] = []) {
        fixed = permission
        fixtures = meetings
    }

    public func permission() -> CalendarPermission { fixed }

    public func requestFullAccess() async throws -> Bool { false }

    public func meetings(in interval: DateInterval) throws -> [CalendarMeeting] {
        guard fixed == .fullAccess else { return [] }
        return fixtures.filter { $0.start < interval.end && $0.end > interval.start }
    }
}

/// The app's calendar: EventKit, read-only. `meeting(from:)` is the one place
/// an event is read, for its title and time; who is invited, the organizer,
/// notes, links and places are never read, and a test holds this file to
/// that. The `EKEventStore` is made only when macOS is asked or once it
/// allows reading, never before: making one can start the calendar's services.
public final class EventKitCalendarAccess: CalendarAccessStore, @unchecked Sendable {
    public static let shared = EventKitCalendarAccess()

    private let lock = NSLock()
    /// One read at a time.
    private let readLock = NSLock()
    #if canImport(EventKit)
    private var store: EKEventStore?
    /// What macOS allowed when `store` was made.
    private var madeWith: CalendarPermission?
    #endif

    public init() {}

    public func permission() -> CalendarPermission {
        #if canImport(EventKit)
        Self.permission(EKEventStore.authorizationStatus(for: .event))
        #else
        .restricted
        #endif
    }

    public func requestFullAccess() async throws -> Bool {
        #if canImport(EventKit)
        let store = eventStore(for: permission())
        return try await store.requestFullAccessToEvents()
        #else
        false
        #endif
    }

    public func meetings(in interval: DateInterval) throws -> [CalendarMeeting] {
        #if canImport(EventKit)
        let permission = permission()
        guard permission == .fullAccess else {
            // Taken back, or never given: a store made earlier is let go, so
            // reading starts fresh once it is allowed again.
            lock.withLock { self.store = nil; self.madeWith = nil }
            return []
        }
        let store = eventStore(for: permission)
        return readLock.withLock {
            let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
            return store.events(matching: predicate).compactMap(Self.meeting(from:))
        }
        #else
        []
        #endif
    }

    #if canImport(EventKit)
    /// What macOS's answer means here. Anything new reads nothing.
    static func permission(_ status: EKAuthorizationStatus) -> CalendarPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .addOnly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// The one place an event is read: its title and its time. A cancelled
    /// event, or one without a title or a time, isn't kept.
    static func meeting(from event: EKEvent) -> CalendarMeeting? {
        guard event.status != .canceled,
              let start = event.startDate, let end = event.endDate, end > start
        else { return nil }
        let title = (event.title ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return CalendarMeeting(title: String(title.prefix(200)), start: start, end: end, isAllDay: event.isAllDay)
    }

    /// The store, made again whenever macOS's answer has changed since it was
    /// made: one made before reading was allowed may not see the events.
    private func eventStore(for permission: CalendarPermission) -> EKEventStore {
        lock.withLock {
            if let store, madeWith == permission { return store }
            let made = EKEventStore()
            store = made
            madeWith = permission
            return made
        }
    }
    #endif
}
