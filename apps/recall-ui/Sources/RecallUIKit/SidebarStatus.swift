import Foundation

/// The line at the foot of the window's sidebar: whether Hippocampus is
/// remembering, read from the status it saves (RULINGS W10).
public struct SidebarStatus: Equatable, Sendable {
    public let text: String
    /// The hi mark keeps its blue dot only while this is true.
    public let remembering: Bool

    /// "Remembering" while the saved status is fresh and nothing blocks it; a
    /// skipped window still counts, because the rest of the screen is read
    /// (RULINGS B1). "Not remembering" when the status is old or names a
    /// block. "Not remembering right now." when there is no status at all.
    public init(receipt: CaptureHealthReceipt?, now: Date = Date()) {
        guard let receipt else {
            text = UserFacingCopy.footerNoStatus
            remembering = false
            return
        }
        if receipt.isStale(now: now) || receipt.blockedReason != nil {
            text = UserFacingCopy.footerNotRemembering
            remembering = false
        } else {
            text = UserFacingCopy.footerRemembering
            remembering = true
        }
    }
}

/// Whether Hippocampus is remembering, as the whole window shows it: the
/// hi mark's dot, the footer, the status menu and the banner (SPEC 2.6). With
/// the private pipe it is the menu bar's own words (`WindowChannelStatus`);
/// a window opened by hand reads the saved status for "Remembering" or "Not
/// remembering", and has no controls.
public struct WindowStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case remembering
        case starting
        case nothingSaved
        case skipping
        case paused
        case off
        case needsPermission
        case notSaving
        case couldNotStop
        case couldNotTurnOn
        case notSetUp
        case forgetting
        /// The window applies a forget a crash left behind.
        case finishingForget
        /// No app to ask: the window was opened by hand and Hippocampus
        /// isn't running.
        case notRunning
        /// Opened by hand while Hippocampus runs: only the saved status.
        case byHand(remembering: Bool)
    }

    /// The footer's dot: blue, a hollow grey ring, or red (SPEC 2.6.3).
    public enum Dot: Equatable, Sendable {
        case on, off, problem
    }

    public enum Permission: String, Equatable, Sendable {
        case screenRecording, accessibility

        public var name: String {
            switch self {
            case .screenRecording: NavigationCopy.screenRecording
            case .accessibility: NavigationCopy.accessibility
            }
        }
    }

    /// The one control the status offers now.
    public enum Action: Equatable, Sendable {
        case pause
        case resume
        case resumeNow
        case turnOn
        case turnOff
        case openSystemSettings(Permission)
        case tryAgain
        case quit
        case finishSetup
        case openHippocampus

        public var title: String {
            switch self {
            case .pause: NavigationCopy.pause
            case .resume: NavigationCopy.resume
            case .resumeNow: NavigationCopy.resumeNow
            case .turnOn: NavigationCopy.turnOn
            case .turnOff: NavigationCopy.turnOff
            case .openSystemSettings: NavigationCopy.openSystemSettings
            case .tryAgain: NavigationCopy.tryAgain
            case .quit: NavigationCopy.quitHippocampus
            case .finishSetup: NavigationCopy.finishSetup
            case .openHippocampus: NavigationCopy.openHippocampus
            }
        }
    }

    /// One line under the field whenever remembering isn't on.
    public struct Banner: Equatable, Sendable {
        public let text: String
        public let action: Action
        /// The red dot for a failure; otherwise the pause symbol.
        public let isProblem: Bool
    }

    public var kind: Kind
    /// The footer's word and the menu's first line.
    public var title: String
    /// The menu's second line.
    public var detail: String?
    public var action: Action?
    public var pausedSince: Date?
    public var pausedUntil: Date?
    public var lowPower: Bool

    public init(kind: Kind, title: String, detail: String? = nil, action: Action? = nil,
                pausedSince: Date? = nil, pausedUntil: Date? = nil, lowPower: Bool = false) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.action = action
        self.pausedSince = pausedSince
        self.pausedUntil = pausedUntil
        self.lowPower = lowPower
    }

    /// What the app pushed over the pipe: its words, its one button.
    public init(_ status: WindowChannelStatus) {
        let permission = status.permission.flatMap(Permission.init(rawValue:)) ?? .screenRecording
        let kind: Kind = switch status.state {
        case .remembering: .remembering
        case .starting: .starting
        case .nothingSaved: .nothingSaved
        case .skipping: .skipping
        case .paused: .paused
        case .off: .off
        case .needsPermission: .needsPermission
        case .notSaving: .notSaving
        case .couldNotStop: .couldNotStop
        case .couldNotTurnOn: .couldNotTurnOn
        case .notSetUp: .notSetUp
        case .forgetting: .forgetting
        }
        let action: Action? = switch status.action {
        case "pause": .pause
        case "resume": status.pausedUntil == nil ? .resume : .resumeNow
        case "turnOn": .turnOn
        case "turnOff": .turnOff
        case "openSystemSettings": .openSystemSettings(permission)
        case "tryAgain": .tryAgain
        case "quit": .quit
        case "finishSetup": .finishSetup
        default: nil
        }
        self.init(kind: kind, title: status.title, detail: status.detail, action: action,
                  pausedSince: status.pausedSince, pausedUntil: status.pausedUntil, lowPower: status.lowPower)
        if kind == .needsPermission { self.permission = permission }
    }

    /// A window opened by hand (its parent is launchd): the saved status's
    /// "Remembering" or "Not remembering", and only Open Hippocampus; or,
    /// with no app running, that it isn't running.
    public init(byHand receipt: CaptureHealthReceipt?, appRunning: Bool, now: Date = Date()) {
        guard appRunning else {
            self.init(kind: .notRunning, title: NavigationCopy.notRemembering, action: .openHippocampus)
            return
        }
        let footer = SidebarStatus(receipt: receipt, now: now)
        self.init(kind: .byHand(remembering: footer.remembering),
                  title: footer.remembering ? NavigationCopy.remembering : NavigationCopy.notRemembering,
                  action: .openHippocampus)
    }

    /// The permission that is off, for Needs permission.
    public var permission: Permission?

    /// Whether the window can change remembering: only through the pipe.
    public var hasControls: Bool {
        switch kind {
        case .byHand, .notRunning: false
        default: true
        }
    }

    /// The hi mark keeps its blue dot only while remembering (a skipped
    /// window still counts, RULINGS B1).
    public var remembering: Bool { dot == .on }

    public var dot: Dot {
        switch kind {
        case .remembering, .starting, .nothingSaved, .skipping: .on
        case .byHand(let remembering): remembering ? .on : .off
        case .paused, .off, .notSetUp, .forgetting, .finishingForget, .notRunning: .off
        case .needsPermission, .notSaving, .couldNotStop, .couldNotTurnOn: .problem
        }
    }

    /// The banner under the field, or nil while remembering (SPEC 2.6.3).
    public func banner(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> Banner? {
        switch kind {
        case .paused:
            if let until = pausedUntil {
                let when = Self.clock(until, now: now, calendar: calendar, locale: locale)
                return Banner(text: NavigationCopy.bannerPausedUntil(when), action: .resumeNow, isProblem: false)
            }
            guard let since = pausedSince else {
                return Banner(text: NavigationCopy.bannerPausedNoTime, action: .resume, isProblem: false)
            }
            let when = Self.clock(since, now: now, calendar: calendar, locale: locale)
            return Banner(text: NavigationCopy.bannerPaused(since: when), action: .resume, isProblem: false)
        case .off:
            return Banner(text: NavigationCopy.bannerOff, action: .turnOn, isProblem: false)
        case .needsPermission:
            let permission = self.permission ?? .screenRecording
            return Banner(text: NavigationCopy.bannerPermission(permission.name),
                          action: .openSystemSettings(permission), isProblem: true)
        case .notSaving:
            return Banner(text: NavigationCopy.bannerNotSaving, action: .tryAgain, isProblem: true)
        case .couldNotStop:
            return Banner(text: NavigationCopy.bannerCouldNotStop, action: .quit, isProblem: true)
        case .couldNotTurnOn:
            return Banner(text: NavigationCopy.bannerCouldNotTurnOn, action: .tryAgain, isProblem: true)
        case .notSetUp:
            return Banner(text: NavigationCopy.bannerNotSetUp, action: .finishSetup, isProblem: false)
        case .notRunning:
            return Banner(text: NavigationCopy.bannerNotRunning, action: .openHippocampus, isProblem: false)
        case .remembering, .starting, .nothingSaved, .skipping, .forgetting, .finishingForget, .byHand:
            return nil
        }
    }

    /// A time on the Mac's clock: "3:40 PM" today, "tomorrow at 6:00 AM",
    /// otherwise "Oct 14 at 9:00 AM".
    static func clock(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(clock)"
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)) at \(clock)"
    }

    /// While the window applies a forget it had to finish, or holds
    /// remembering for one, the footer says so (SPEC 3.11).
    public func forgetting(_ phase: ForgetPhase?) -> WindowStatus {
        guard let phase else { return self }
        var status = self
        switch phase {
        case .forgetting:
            status.kind = .forgetting
            status.title = NavigationCopy.forgetting
        case .finishing:
            status.kind = .finishingForget
            status.title = NavigationCopy.finishingForget
        }
        status.detail = nil
        status.action = nil
        return status
    }

    /// Nothing known yet: the window has just opened.
    public static let unknown = WindowStatus(kind: .starting, title: "Starting\u{2026}")
}

/// A forget under way, for the footer (SPEC 3.11).
public enum ForgetPhase: Equatable, Sendable {
    /// "Forgetting…": the hold is on and the moments are being deleted.
    case forgetting
    /// "Finishing a forget…": the window applies one a crash left.
    case finishing
}

/// The status menu, from the hi mark and from the footer (SPEC 2.6.2): the
/// status lines, the first action, Forget, Privacy and Preferences. A window
/// opened by hand has no controls: the status lines and Open Hippocampus.
public enum WindowStatusMenu {
    public enum Item: Equatable, Sendable {
        /// The first line, with the dot.
        case title(String, WindowStatus.Dot)
        /// A line under it: "Last saved 12s ago", the Low Power line.
        case line(String)
        case separator
        /// Pause ▸ For 1 Hour, Until Tomorrow, Until I Resume.
        case pause
        case action(WindowStatus.Action)
        case forget(ForgetRecentChoice)
        case privacy
        case preferences
    }

    public static func items(_ status: WindowStatus) -> [Item] {
        var items: [Item] = [.title(status.title, status.dot)]
        if let detail = status.detail, !detail.isEmpty { items.append(.line(detail)) }
        if status.lowPower { items.append(.line(NavigationCopy.lowPower)) }
        guard status.hasControls else {
            return items + [.separator, .action(.openHippocampus)]
        }
        items.append(.separator)
        if let action = status.action {
            items.append(action == .pause ? .pause : .action(action))
            items.append(.separator)
        }
        items += [.forget(.tenMinutes), .forget(.hour), .forget(.today), .separator, .privacy, .preferences]
        return items
    }

    /// The menu item's words for a forget.
    public static func title(_ choice: ForgetRecentChoice) -> String {
        switch choice {
        case .tenMinutes: NavigationCopy.forgetLastTenMinutes
        case .hour: NavigationCopy.forgetLastHour
        case .today: NavigationCopy.forgetToday
        }
    }

    /// Pause's three choices, and when each ends: nil until the person
    /// resumes. Until Tomorrow ends at 6:00 AM the next day (SPEC 2.6.2).
    public enum PauseChoice: CaseIterable, Sendable {
        case hour, tomorrow, untilResume

        public var title: String {
            switch self {
            case .hour: NavigationCopy.pauseForAnHour
            case .tomorrow: NavigationCopy.pauseUntilTomorrow
            case .untilResume: NavigationCopy.pauseUntilResume
            }
        }

        public func until(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .hour:
                return now.addingTimeInterval(60 * 60)
            case .tomorrow:
                let start = calendar.startOfDay(for: now)
                guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return calendar.date(bySettingHour: 6, minute: 0, second: 0, of: next)
            case .untilResume:
                return nil
            }
        }
    }
}
