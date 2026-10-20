// SPDX-License-Identifier: Apache-2.0
//
// StatusMenuModel.swift — every word of the menu-bar menu, as data, so tests
// pin them (spec-shell S2, RULINGS S3 and S5). The status row it builds is
// the one Ask's footer and Preferences show too, so the three never disagree
// (product critique 11).

import Foundation

/// What the status row is built from.
public struct StatusFacts: Equatable, Sendable {
    public var status: MenuBarStatus
    public var setup: AskPanelStatus.Setup
    /// The receipt's last saved moment, for "Last saved {time} ago".
    public var lastSavedAt: Date?
    /// When the person paused, for "Since {time}."
    public var pausedSince: Date?
    /// When the person pressed Stop Sharing, for "You stopped it at {time}."
    public var stoppedSharingAt: Date?
    /// Turn On is under way: nothing is on yet, so there is nothing to pause,
    /// but it can be turned off.
    public var turningOn: Bool
    /// A stop is under way: Off shows once it is done, and nothing is
    /// offered until then.
    public var stopping: Bool

    public init(
        status: MenuBarStatus,
        setup: AskPanelStatus.Setup = .complete,
        lastSavedAt: Date? = nil,
        pausedSince: Date? = nil,
        stoppedSharingAt: Date? = nil,
        turningOn: Bool = false,
        stopping: Bool = false
    ) {
        self.status = status
        self.setup = setup
        self.lastSavedAt = lastSavedAt
        self.pausedSince = pausedSince
        self.stoppedSharingAt = stoppedSharingAt
        self.turningOn = turningOn
        self.stopping = stopping
    }
}

/// One row about remembering: the menu's first three lines, Ask's footer and
/// the top of Preferences, Remembering.
public struct StatusRow: Equatable, Sendable {
    /// Line 1: "Remembering", "Paused", "Off", …
    public let title: String
    /// Line 2, when there is something to add.
    public let detail: String?
    /// Line 3: the one button.
    public let action: CaptureStatusAction?

    public init(title: String, detail: String?, action: CaptureStatusAction?) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    public init(_ facts: StatusFacts, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        guard facts.setup == .complete else {
            // Start Remembering in onboarding is the only consent, so before
            // setup nothing here turns remembering on (product critique 4).
            // While onboarding is on screen there is nothing to press.
            self.init(title: "Not set up yet", detail: nil,
                      action: facts.setup == .notFinished ? .finishSetup : nil)
            return
        }
        let status = facts.status
        let words = StatusWords(now: now, calendar: calendar)
        let detail: String?
        switch status {
        case .recording, .unchanged: detail = facts.lastSavedAt.map(words.lastSaved)
        case .paused: detail = facts.pausedSince.map(words.pausedSince)
        case .idle: detail = facts.stoppedSharingAt.map(words.stoppedSharing)
        default: detail = status.detailText
        }
        // A turn-on under way lands, or says why not, by itself; until then
        // nothing is on to pause, and Turn Off drops it, as the newer word.
        // A stop under way offers nothing: Pause would record a pause the
        // person did not mean, and Off shows once the stop is done.
        let action: CaptureStatusAction?
        if facts.turningOn, status.action == .pause {
            action = .turnOff
        } else if facts.stopping, status.action == .pause {
            action = nil
        } else {
            action = status.action
        }
        self.init(title: status.displayText, detail: detail, action: action)
    }
}

/// Times in the person's locale (RULINGS V): a clock time on the same day, a
/// date on another; ages in the system's abbreviated style.
struct StatusWords {
    let now: Date
    let calendar: Calendar

    func lastSaved(_ saved: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 1
        // A save a moment ago, or a clock a little ahead, still reads as one.
        let age = max(1, now.timeIntervalSince(saved).rounded(.down))
        return "Last saved \(formatter.string(from: age) ?? "") ago"
    }

    func pausedSince(_ date: Date) -> String {
        "Since \(sameDay(date) ? time(date) : day(date))."
    }

    func stoppedSharing(_ date: Date) -> String {
        sameDay(date) ? "You stopped it at \(time(date))." : "You stopped it on \(day(date))."
    }

    private func sameDay(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }

    private func time(_ date: Date) -> String { format(date, template: "jmm") }

    private func day(_ date: Date) -> String { format(date, template: "MMMd") }

    private func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// The menu-bar menu: a short native menu whose job is trust (spec-shell S2).
public enum StatusMenuModel {
    /// A key equivalent: the key and its modifiers.
    public struct KeyEquivalent: Equatable, Sendable {
        public let key: String
        public let command: Bool
        public let shift: Bool
        public let control: Bool

        public init(key: String, command: Bool = false, shift: Bool = false, control: Bool = false) {
            self.key = key
            self.command = command
            self.shift = shift
            self.control = control
        }
    }

    public struct Item: Equatable, Sendable {
        public enum Role: Equatable, Sendable {
            /// Line 1, as text.
            case status
            /// Line 2, as text.
            case detail
            /// Line 3.
            case action(CaptureStatusAction)
            case separator
            case ask
            case openWindow
            case aiTools
            case preferences
            case quit
            /// An item from elsewhere in the app, such as Demo Memory's
            /// (`DemoMemory.menuItems`), by an id its owner carries out.
            case extra(String)
        }

        public let role: Role
        public let title: String
        public let isEnabled: Bool
        /// The chosen key that opens Ask, drawn as a badge.
        public let badge: String?
        public let key: KeyEquivalent?

        public init(
            role: Role, title: String, isEnabled: Bool = true,
            badge: String? = nil, key: KeyEquivalent? = nil
        ) {
            self.role = role
            self.title = title
            self.isEnabled = isEnabled
            self.badge = badge
            self.key = key
        }

        public static let separator = Item(role: .separator, title: "")
    }

    /// Top to bottom. `askLabel` is what opens Ask right now
    /// (`AskShortcut.label`): ⌃⇧Space is a real key equivalent, a chosen key
    /// is a badge (spec-shell S3). `extraItems`, from elsewhere in the app
    /// (Demo Memory's while Option is held, SPEC-DELTA 6), are a group of
    /// their own above Quit; with none, the menu is exactly as before.
    public static func items(
        row: StatusRow, setupComplete: Bool, askLabel: String?, aiToolsConnected: Bool,
        extraItems: [Item] = []
    ) -> [Item] {
        var items = [Item(role: .status, title: row.title, isEnabled: false)]
        if let detail = row.detail {
            items.append(Item(role: .detail, title: detail, isEnabled: false))
        }
        // After a failed stop the fix, Quit, sits under the reason too
        // (RULINGS S3).
        if let action = row.action {
            items.append(Item(role: .action(action), title: action.title))
        }
        items.append(.separator)
        // Before setup only the menu item is off; the key keeps working
        // (critique-shell-engineering 9).
        if askLabel == AskShortcut.fallbackLabel {
            items.append(Item(role: .ask, title: "Ask", isEnabled: setupComplete,
                              key: KeyEquivalent(key: " ", shift: true, control: true)))
        } else {
            items.append(Item(role: .ask, title: "Ask", isEnabled: setupComplete, badge: askLabel))
        }
        items.append(Item(role: .openWindow, title: "Open Hippocampus"))
        items.append(.separator)
        items.append(Item(role: .aiTools, title: aiToolsConnected ? "AI Tools…" : "Connect AI Tools…"))
        items.append(Item(role: .preferences, title: "Preferences…", key: KeyEquivalent(key: ",", command: true)))
        items.append(.separator)
        if !extraItems.isEmpty {
            items.append(contentsOf: extraItems)
            items.append(.separator)
        }
        items.append(Item(role: .quit, title: "Quit Hippocampus", key: KeyEquivalent(key: "q", command: true)))
        return items
    }

    /// The status item's accessibility label and tooltip (RULINGS B2).
    public static func accessibilityLabel(_ row: StatusRow) -> String {
        "Hippocampus, \(row.title)"
    }
}
