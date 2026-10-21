import RecallUIKit
import SwiftUI

/// What the person chose for the sidebar: Working On items they hid, and
/// names that look personal they showed anyway (SPEC 2.11, 3.2). The
/// window's settings keep both as keyed ids; the shell hands them to
/// Working On's places here, with the actions that change them: `hide`
/// hides (and takes back a show), `show` takes back a hide and shows a
/// personal name. Without the shell's, nothing is hidden or shown and the
/// actions do nothing.
struct WorkItemHides {
    var ids: Set<String> = []
    /// Names that look personal the person chose Show in Sidebar for.
    var shown: Set<String> = []
    var hide: @MainActor (String) -> Void = { _ in }
    var show: @MainActor (String) -> Void = { _ in }

    /// Whether Show All and the item's page keep it out of the sidebar.
    func keepsOut(_ item: WorkItem) -> Bool {
        item.isKeptOut(hidden: ids, shown: shown)
    }
}

/// What Resume uses: the plan, the Mac, the browsers' tabs and what is
/// never offered. The app's are the agent and the system; the synthetic
/// preview and renders put fixtures here, so nothing opens and nothing is
/// asked of macOS.
struct ResumeServices {
    var planner: any ResumePlanning
    var workspace: any ResumeWorkspace
    var tabs: any OpenTabsReading
    var rules: @MainActor () -> ResumeRules
    var asked: (any KeyValueStore)?

    /// The app's: the bundled agent and macOS.
    @MainActor static let system = ResumeServices(
        planner: AgentWorkReader.shared,
        workspace: SystemResumeWorkspace(),
        tabs: AppleScriptOpenTabs.shared,
        rules: { ResumeRules.system() },
        asked: UserDefaultsKeyValueStore()
    )

    /// Nothing at all: no plan, nothing installed, no tabs.
    static let none = ResumeServices(
        planner: NoResumePlans(), workspace: FixtureResumeWorkspace(installed: []), tabs: NoOpenTabs(),
        rules: { .none }, asked: nil
    )
}

/// A Mac with the given apps installed, where opening succeeds and does
/// nothing: previews and renders.
struct FixtureResumeWorkspace: ResumeWorkspace {
    var installed: Set<String>

    func appURL(bundleId: String) -> URL? {
        installed.contains(bundleId) ? URL(fileURLWithPath: "/Applications/\(bundleId).app") : nil
    }

    func exists(path: String) -> Bool { true }
    func open(_ urls: [URL], withApp app: URL) async -> Bool { true }
    func openApp(at app: URL) async -> Bool { true }
    func folderURL(path: String) -> URL { URL(fileURLWithPath: "/tmp/\(path)", isDirectory: true) }
}

/// The person's calendar for formatting: the environment's, in its time
/// zone and locale, so renders and the app say the same times.
extension EnvironmentValues {
    var workDisplayCalendar: Calendar {
        var calendar = self.calendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }
}

/// No browser can say its tabs.
struct NoOpenTabs: OpenTabsReading {
    func openTabs(browser: String, mayAsk: Bool) async -> OpenTabsAnswer { .unknown }
}

/// Forgetting what a lens lists: a page's moments on every day, a search
/// and its results page (SPEC 3.11). The shell's forget flow (its
/// confirmation, the hold and the Undo note) does it; without one, the
/// lenses offer no Forget.
struct LensForget {
    /// What is forgotten: a web page's moments on every day, or a search
    /// and its results page. The confirmation words differ (SPEC 3.11).
    enum Kind: Sendable {
        case page
        case search
    }

    var forget: (@MainActor (_ moments: [UInt64], _ title: String, _ kind: Kind) -> Void)?
}

private struct LensForgetKey: EnvironmentKey {
    static let defaultValue = LensForget()
}

private struct WorkItemHidesKey: EnvironmentKey {
    static let defaultValue = WorkItemHides()
}

private struct WorkMomentsKey: EnvironmentKey {
    static let defaultValue: WorkMomentCache? = nil
}

private struct ClaudeCodeStartsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RetentionDaysKey: EnvironmentKey {
    static let defaultValue = 90
}

private struct ResumeServicesKey: EnvironmentKey {
    static let defaultValue: ResumeServices? = nil
}

private struct CalendarReaderKey: EnvironmentKey {
    static let defaultValue: (any CalendarReader)? = nil
}

private struct WorkNowKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Date = { Date() }
}

extension EnvironmentValues {
    /// The shell's forget flow, for Forget This Page… and Forget This
    /// Search….
    var lensForget: LensForget {
        get { self[LensForgetKey.self] }
        set { self[LensForgetKey.self] = newValue }
    }

    /// The person's sidebar hides (the shell sets them).
    var workItemHides: WorkItemHides {
        get { self[WorkItemHidesKey.self] }
        set { self[WorkItemHidesKey.self] = newValue }
    }

    /// Moments read for Working On's pictures; the window's own when unset.
    var workMoments: WorkMomentCache? {
        get { self[WorkMomentsKey.self] }
        set { self[WorkMomentsKey.self] = newValue }
    }

    /// Claude Code is connected and starts each session with recent work:
    /// a code project's page says so (SPEC 3.2). AI Tools' read sets it.
    var claudeCodeStartsSessions: Bool {
        get { self[ClaudeCodeStartsKey.self] }
        set { self[ClaudeCodeStartsKey.self] = newValue }
    }

    /// How many days moments are kept, for the line at a list's end.
    var retentionDays: Int {
        get { self[RetentionDaysKey.self] }
        set { self[RetentionDaysKey.self] = newValue }
    }

    /// Resume's plan, Mac, tabs and rules; the app's (`.system`) when unset.
    var resumeServices: ResumeServices? {
        get { self[ResumeServicesKey.self] }
        set { self[ResumeServicesKey.self] = newValue }
    }

    /// The person's calendar, when they turned it on (SPEC-DELTA 5).
    var workCalendarReader: (any CalendarReader)? {
        get { self[CalendarReaderKey.self] }
        set { self[CalendarReaderKey.self] = newValue }
    }

    /// The window's clock, for "today at 2:20 PM".
    var workNow: @Sendable () -> Date {
        get { self[WorkNowKey.self] }
        set { self[WorkNowKey.self] = newValue }
    }
}
