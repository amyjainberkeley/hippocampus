// SPDX-License-Identifier: TBD-private
//
// FourScreenFlowViewModel — the four-screen setup: Welcome, Permissions,
// Promise, Try it. It replaces `OnboardingFlowViewModel` when the four
// screens ship; until then no view shows it.
//
// What it holds:
// - Consent has one writer, `startRemembering(keyReady:openAtLogin:)`.
//   Nothing else moves a first run past Promise.
// - The resume clamp, at start and on every move: Try it needs consent,
//   otherwise Promise; Promise needs both permissions, otherwise Permissions.
// - Two permission rows, both visible at once. A row waits from the request
//   until the person comes back to this window; on return one refresh
//   decides. No timer moves a row.
// - Screen Recording may be confirmed by a fresh process (see
//   `ScreenRecordingProbe`). That check runs when the person comes back,
//   every 2.5 s while the Screen Recording row waits, and once more at
//   consent; never more than one at a time. A return, or consent, decides
//   only on a check that started after it: one already running may have
//   started before the person changed the setting, so it is waited out
//   and a fresh process is asked once more.
// - Stores default to memory. Setup passes the file stores; tests and
//   panels never touch the person's resume or consent files by accident.

import Foundation

/// What a permission row shows.
public enum PermissionRowState: Equatable, Sendable {
    /// Not asked yet: "Allow".
    case idle
    /// Asked, and the person has not come back to this window yet.
    case waiting
    /// Came back and it is still off, or it was off before this run.
    case needsHelp
    /// On.
    case granted
}

/// Why Start Remembering did not record consent.
public enum ConsentFailure: Equatable, Sendable {
    /// The consent file could not be written (a full disk, say).
    case notSaved
}

@MainActor
public final class FourScreenFlowViewModel: ObservableObject {
    @Published public private(set) var screen: OnboardingScreen
    @Published public private(set) var consentFailure: ConsentFailure?
    /// When this run recorded consent, in microseconds since 1970: Try it
    /// shows what was read after it.
    @Published public private(set) var consentGivenAtUs: UInt64?
    /// Bumped by every refresh, so views that read the permissions redraw.
    @Published public private(set) var permissionRefreshCount = 0
    @Published public private(set) var fullDiskAccessStatus: FullDiskAccessStatus = .notRequested
    @Published private var rows: [PermissionSurface: RowRecord] = [:]

    /// Consent existed when setup opened. Promise then only advances.
    public let isReview: Bool
    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission
    /// Kept for the panels; the four screens never ask for it.
    public let automationPermission: any TCCPermission

    /// The two rows, in the order they are shown.
    public static let rowSurfaces: [PermissionSurface] = [.screenRecording, .accessibility]
    /// Spacing of fresh-process Screen Recording checks while its row waits.
    public static let outOfProcessCheckInterval: TimeInterval = 2.5
    /// "Ask Again" is offered after this many returns that found the row off.
    public static let failedReturnsBeforeAskAgain = 2

    private let stateStore: any OnboardingStateStore
    private let consentStore: any OnboardingConsentStore
    private let fdaPermission: (any FullDiskAccessPermission)?
    private let now: () -> Date
    private var lastOutOfProcessCheck: Date?
    /// The fresh-process Screen Recording check that is running, if any.
    private var freshCheck: Task<Void, Never>?

    private struct RowRecord: Equatable {
        var waiting = false
        var asked = false
        var failedReturns = 0
    }

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        automation: (any TCCPermission)? = nil,
        fullDiskAccess: (any FullDiskAccessPermission)? = nil,
        stateStore: any OnboardingStateStore = InMemoryOnboardingStateStore(),
        consentStore: any OnboardingConsentStore = InMemoryOnboardingConsentStore(),
        now: @escaping () -> Date = Date.init,
        initialScreen: OnboardingScreen? = nil
    ) {
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
        self.automationPermission = automation
            ?? StubTCCPermission(kind: .automation, status: .notRequested)
        self.fdaPermission = fullDiskAccess
        self.stateStore = stateStore
        self.consentStore = consentStore
        self.now = now
        self.isReview = consentStore.isGiven
        // An explicit launch screen wins over the resume file.
        let requested = initialScreen ?? stateStore.loadScreen() ?? .welcome
        self.screen = Self.clamp(
            requested,
            consentGiven: consentStore.isGiven,
            bothGranted: screenRecording.status == .granted && accessibility.status == .granted
        )
    }

    // MARK: - Moving between screens

    public var bothGranted: Bool {
        screenRecordingPermission.status == .granted && accessibilityPermission.status == .granted
    }

    public var canAdvance: Bool {
        switch screen {
        case .welcome: true
        case .permissions: bothGranted
        // On a first run only Start Remembering leaves Promise.
        case .promise: isReview
        case .tryIt: false
        }
    }

    public var canGoBack: Bool {
        screen == .permissions || screen == .promise
    }

    public func advance() {
        guard canAdvance, let next = OnboardingScreen(rawValue: screen.rawValue + 1) else { return }
        move(to: next)
    }

    public func back() {
        guard canGoBack, let previous = OnboardingScreen(rawValue: screen.rawValue - 1) else { return }
        move(to: previous)
    }

    /// Jump to a screen, clamped like a resume.
    public func goTo(_ target: OnboardingScreen) {
        move(to: target)
    }

    /// Called when setup is done, so a later run starts fresh.
    public func clearResumeState() {
        stateStore.clear()
    }

    /// Try it needs consent, otherwise Promise. Promise needs both
    /// permissions, otherwise Permissions.
    static func clamp(
        _ target: OnboardingScreen,
        consentGiven: Bool,
        bothGranted: Bool
    ) -> OnboardingScreen {
        var screen = target
        if screen == .tryIt, !consentGiven { screen = .promise }
        if screen == .promise, !bothGranted { screen = .permissions }
        return screen
    }

    private func move(to target: OnboardingScreen) {
        screen = Self.clamp(target, consentGiven: consentStore.isGiven, bothGranted: bothGranted)
        stateStore.save(screen)
    }

    // MARK: - Consent

    /// The only code that writes consent. It checks the permissions once
    /// more (asking a fresh process about Screen Recording if this one
    /// still says no), then requires Promise, both permissions and the
    /// encryption key. On success it records the time and opens Try it.
    @discardableResult
    public func startRemembering(keyReady: Bool, openAtLogin: Bool) async -> Bool {
        await refreshDeciding(askFreshProcess: true)
        guard screen == .promise, bothGranted, keyReady else { return false }
        do {
            try consentStore.give(openAtLogin: openAtLogin)
        } catch {
            consentFailure = .notSaved
            return false
        }
        consentFailure = nil
        consentGivenAtUs = Self.microseconds(now())
        move(to: .tryIt)
        return true
    }

    public func dismissConsentFailure() {
        consentFailure = nil
    }

    static func microseconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1_000_000))
    }

    // MARK: - Permission rows

    public func rowState(_ surface: PermissionSurface) -> PermissionRowState {
        guard let permission = permission(for: surface) else { return .idle }
        if permission.status == .granted { return .granted }
        let row = rows[surface] ?? RowRecord()
        if row.waiting { return .waiting }
        if row.asked || permission.status == .denied { return .needsHelp }
        return .idle
    }

    /// A row's "Allow" is off while it is on, and while the other row waits
    /// for System Settings.
    public func canRequest(_ surface: PermissionSurface) -> Bool {
        guard permission(for: surface) != nil, rowState(surface) != .granted else { return false }
        return !Self.rowSurfaces.contains { $0 != surface && rowState($0) == .waiting }
    }

    /// True once the person has come back twice and found the row still off.
    public func offersAskAgain(_ surface: PermissionSurface) -> Bool {
        rowState(surface) == .needsHelp
            && (rows[surface]?.failedReturns ?? 0) >= Self.failedReturnsBeforeAskAgain
    }

    /// "Allow": today's request for the permission. The row waits until the
    /// person comes back.
    public func requestPermission(_ surface: PermissionSurface) {
        guard canRequest(surface), let permission = permission(for: surface) else { return }
        markWaiting(surface)
        permission.requestOrOpenSettings()
        refreshPermissions()
    }

    /// "Open System Settings" on a row that needs help.
    public func openSettings(_ surface: PermissionSurface) {
        guard let permission = permission(for: surface), rowState(surface) != .granted else { return }
        markWaiting(surface)
        permission.openPrivacySettings()
    }

    /// "Ask Again": reset and ask macOS again, then wait for the person.
    public func askAgain(_ surface: PermissionSurface) async {
        // A fresh-process check still running started before the reset;
        // let it answer first, so its answer cannot land after the reset.
        while let running = freshCheck {
            await running.value
        }
        guard let permission = permission(for: surface), rowState(surface) != .granted else { return }
        markWaiting(surface)
        await permission.askAgain()
    }

    /// The window became active again. One refresh first, then each row
    /// that was waiting decides: on, or needs help.
    public func userReturned() async {
        let returning = Self.rowSurfaces.filter { rows[$0]?.waiting == true }
        await refreshDeciding(askFreshProcess: screenRecordingPermission.status != .granted)
        for surface in returning {
            var row = rows[surface] ?? RowRecord()
            row.waiting = false
            if permission(for: surface)?.status != .granted {
                row.failedReturns += 1
            }
            rows[surface] = row
        }
    }

    /// The quick check. It can turn a row on, never off.
    public func refreshPermissions() {
        _ = screenRecordingPermission.checkCurrent()
        _ = accessibilityPermission.checkCurrent()
        permissionRefreshCount += 1
    }

    /// The poll, about once a second while Permissions shows. It may turn a
    /// row off; a fresh process is asked about Screen Recording only while
    /// that row waits, at most every 2.5 s.
    public func refreshPermissionsAsync() async {
        await refreshPermissionsAsync(outOfProcess: outOfProcessCheckIsDue())
    }

    /// The poll's refresh. While a fresh-process check runs, the poll does
    /// not wait for it: this process answers for this tick.
    func refreshPermissionsAsync(outOfProcess: Bool) async {
        if outOfProcess, freshCheck == nil {
            await startFreshCheck().value
        } else {
            _ = await screenRecordingPermission.checkCurrentAsync(outOfProcess: false)
        }
        _ = await accessibilityPermission.checkCurrentAsync(outOfProcess: false)
        permissionRefreshCount += 1
    }

    /// A refresh that may decide a row. Its Screen Recording answer comes
    /// from a check that started after this call: a fresh-process check
    /// already running may have started before the person turned the
    /// permission on, so it is waited out, and with `askFreshProcess` a
    /// new one runs.
    private func refreshDeciding(askFreshProcess: Bool) async {
        while let running = freshCheck {
            await running.value
        }
        if askFreshProcess {
            await startFreshCheck().value
        } else {
            _ = await screenRecordingPermission.checkCurrentAsync(outOfProcess: false)
        }
        _ = await accessibilityPermission.checkCurrentAsync(outOfProcess: false)
        permissionRefreshCount += 1
    }

    /// Start a fresh-process check of Screen Recording and keep it, so a
    /// return can wait for it. Only call when none is running.
    private func startFreshCheck() -> Task<Void, Never> {
        lastOutOfProcessCheck = now()
        let check = Task { [weak self] in
            guard let self else { return }
            _ = await self.screenRecordingPermission.checkCurrentAsync(outOfProcess: true)
            self.freshCheck = nil
        }
        freshCheck = check
        return check
    }

    private func outOfProcessCheckIsDue() -> Bool {
        guard rowState(.screenRecording) == .waiting else { return false }
        guard let last = lastOutOfProcessCheck else { return true }
        return now().timeIntervalSince(last) >= Self.outOfProcessCheckInterval
    }

    private func markWaiting(_ surface: PermissionSurface) {
        var row = rows[surface] ?? RowRecord()
        row.waiting = true
        row.asked = true
        rows[surface] = row
    }

    private func permission(for surface: PermissionSurface) -> (any TCCPermission)? {
        switch surface {
        case .screenRecording: screenRecordingPermission
        case .accessibility: accessibilityPermission
        case .automation, .fullDiskAccess: nil
        }
    }

    // MARK: - For the panels

    public func refreshFullDiskAccessStatus() async {
        guard let fda = fdaPermission else { return }
        let status = await fda.status()
        if status != fullDiskAccessStatus {
            fullDiskAccessStatus = status
        }
    }

    @discardableResult
    public func probeAutomation() -> TCCStatus {
        automationPermission.checkCurrent()
    }
}
