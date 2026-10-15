// SPDX-License-Identifier: Apache-2.0
import CoreServices
import Foundation

/// Why Hippocampus was opened, read once at launch (spec-shell S7). Only a
/// launch by the person opens the window. A login, a relaunch after an
/// update or a restart, a link and a Preferences request stay in the menu
/// bar; opening the app again while it runs still shows the window.
public enum LaunchReason: String, Sendable, Equatable {
    case preferences
    case quiet
    case login
    case url
    case user

    /// The parts of the launch's Apple event the reason needs.
    public struct Event: Sendable, Equatable {
        public let eventClass: AEEventClass
        public let eventID: AEEventID
        /// The enum code under `keyAEPropData`, when there is one.
        public let propData: OSType?

        public init(eventClass: AEEventClass, eventID: AEEventID, propData: OSType? = nil) {
            self.eventClass = eventClass
            self.eventID = eventID
            self.propData = propData
        }

        public init?(_ descriptor: NSAppleEventDescriptor?) {
            guard let descriptor else { return nil }
            self.init(
                eventClass: descriptor.eventClass,
                eventID: descriptor.eventID,
                propData: descriptor.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            )
        }

        /// Content-free, for the launch log line: "aevt/oapp prdt=lgit".
        public var logDescription: String {
            let marker = propData.map { " prdt=\(Self.fourCC($0))" } ?? ""
            return "\(Self.fourCC(eventClass))/\(Self.fourCC(eventID))\(marker)"
        }

        static func fourCC(_ code: UInt32) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
            guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(code) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// 'GURL', the class and id of a "get URL" event.
    static let getURL: UInt32 = 0x4755_524C

    /// Whether this launch opens the window. Only the person's own launch
    /// does: a login, a quiet relaunch, a link and a Preferences request
    /// keep Hippocampus in the menu bar (spec-shell S7).
    public var opensWindow: Bool { self == .user }

    /// The table in spec-shell S7, in order: a Preferences request, a quiet
    /// launch, a login, a link, and otherwise the person.
    public static func decide(
        preferencesRequested: Bool,
        quietEnvironment: Bool,
        quietOnceAt: Date?,
        now: Date,
        event: Event?
    ) -> LaunchReason {
        if preferencesRequested { return .preferences }
        if quietEnvironment || QuietLaunchNote.honours(quietOnceAt, now: now) { return .quiet }
        if let event, event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEOpenApplication),
           event.propData == OSType(keyAELaunchedAsLogInItem) {
            return .login
        }
        if let event, event.eventClass == getURL, event.eventID == getURL { return .url }
        return .user
    }

    /// Read the reason now. Call it first thing in
    /// `applicationDidFinishLaunching`, while the launch's Apple event is
    /// still the current one. It takes the one-time quiet note.
    @MainActor
    public static func read(
        preferencesRequested: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        currentEvent: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> (reason: LaunchReason, event: Event?) {
        let event = Event(currentEvent)
        let reason = decide(
            preferencesRequested: preferencesRequested,
            quietEnvironment: environment[QuietLaunchNote.environmentKey] == "1",
            quietOnceAt: QuietLaunchNote.take(from: defaults),
            now: now,
            event: event
        )
        return (reason, event)
    }
}

/// A one-time request that the next launch stay in the menu bar, left just
/// before an update relaunches the app. It is a time, honoured for two
/// minutes, so a relaunch that never happened does not make the person's
/// next launch quiet (critique-shell-engineering 13).
public enum QuietLaunchNote {
    public static let key = "ai.hippocampus.launch.quietOnce"
    /// The restart command and scripts ask for a quiet launch with this.
    public static let environmentKey = "HIPPOCAMPUS_QUIET_LAUNCH"
    public static let honouredFor: TimeInterval = 120

    public static func record(_ date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    /// The note's time, removing the note.
    public static func take(from defaults: UserDefaults = .standard) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let seconds = defaults.double(forKey: key)
        defaults.removeObject(forKey: key)
        return Date(timeIntervalSince1970: seconds)
    }

    static func honours(_ note: Date?, now: Date) -> Bool {
        guard let note else { return false }
        let age = now.timeIntervalSince(note)
        return age >= 0 && age <= honouredFor
    }
}
