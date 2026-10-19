// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppKit
import os

public struct ProcessSupervisorLaunchPlan: Sendable, Equatable {
    public let helperExecutableURL: URL
    public let helperArguments: [String]
    public let helperEnvironment: [String: String]
    public let agentExecutableURL: URL
    public let agentArguments: [String]
    public let agentEnvironment: [String: String]

    static func sanitizedEnvironment(
        baseEnvironment: [String: String],
        dbPath: URL,
        keyReference: KeychainKeyReference,
        developmentKeyMode: DevelopmentFileKeyMode? = nil
    ) -> [String: String] {
        var environment = ChildProcessEnvironment.scrubbingReusableKeys(from: baseEnvironment)
        environment["MCI_DB_PATH"] = dbPath.path
        if let developmentKeyMode {
            environment["MCI_DEVELOPMENT_FILE_KEY"] = "1"
            environment["MCI_DB_KEY_FILE"] = developmentKeyMode.keyURL.path
            return environment
        }
        environment["MCI_DB_KEYCHAIN_SERVICE"] = keyReference.service
        environment["MCI_DB_KEYCHAIN_ACCOUNT"] = keyReference.account
        environment["MCI_DB_KEYCHAIN_STORAGE_MODEL"] = KeychainKeyStore.storageModel
        return environment
    }

    package static func onboardingEnvironment(
        baseEnvironment: [String: String],
        dbPath: URL,
        keyReference: KeychainKeyReference,
        developmentKeyMode: DevelopmentFileKeyMode? = nil,
        initialStep: String?,
        remembering: SetupRemembering? = nil
    ) -> [String: String] {
        var environment = sanitizedEnvironment(
            baseEnvironment: baseEnvironment,
            dbPath: dbPath,
            keyReference: keyReference,
            developmentKeyMode: developmentKeyMode
        )
        if let initialStep, !initialStep.isEmpty {
            environment["MCI_ONBOARDING_STEP"] = initialStep
        } else {
            environment.removeValue(forKey: "MCI_ONBOARDING_STEP")
        }
        environment[SetupRemembering.environmentKey] = remembering?.rawValue
        return environment
    }

    package static func recallEnvironment(
        baseEnvironment: [String: String],
        dbPath: URL,
        keyReference: KeychainKeyReference,
        developmentKeyMode: DevelopmentFileKeyMode? = nil,
        initialTab: String?,
        focusEventId: UInt64?,
        openPopup: Bool,
        agentURL: URL?
    ) -> [String: String] {
        var environment = sanitizedEnvironment(
            baseEnvironment: baseEnvironment,
            dbPath: dbPath,
            keyReference: keyReference,
            developmentKeyMode: developmentKeyMode
        )
        if let initialTab, !initialTab.isEmpty {
            environment["MCI_INITIAL_TAB"] = initialTab
        }
        if let focusEventId, focusEventId > 0 {
            environment["MCI_INITIAL_FOCUS_EVENT_ID"] = String(focusEventId)
        }
        if openPopup {
            environment["MCI_OPEN_GLOBAL_POPUP"] = "1"
        }
        if developmentKeyMode != nil, let agentURL {
            environment["MCI_AGENT_PATH"] = agentURL.path
        }
        return environment
    }

    package static func make(
        helperURL: URL,
        agentURL: URL,
        dbPath: URL,
        keyReference: KeychainKeyReference,
        developmentKeyMode: DevelopmentFileKeyMode? = nil,
        knownSafeAppsURL: URL?,
        captureEnabled: Bool,
        crashReportOptedIn: Bool,
        generation: SupervisorProcessGeneration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProcessSupervisorLaunchPlan {
        precondition(generation.captureEnabled == captureEnabled)
        var helperArguments = [
            "--parent-lease-stdin",
            "--output", "/dev/stdout",
            "--readiness-file", generation.readinessURL.path,
            "--generation", generation.id,
        ]
        if captureEnabled { helperArguments.insert("--capture", at: 0) }
        if let knownSafeAppsURL {
            helperArguments += ["--allowlist-path", knownSafeAppsURL.path]
        }

        let childEnvironment = sanitizedEnvironment(
            baseEnvironment: baseEnvironment,
            dbPath: dbPath,
            keyReference: keyReference,
            developmentKeyMode: developmentKeyMode
        )
        var agentEnvironment = childEnvironment
        agentEnvironment["MCI_CAPTURE_ENABLED"] = captureEnabled ? "1" : "0"
        // Screen capture and sharing existing memory do not grant permission
        // to import every local AI transcript. Keep the desktop off until it
        // has a dedicated importer consent and revocation surface.
        agentEnvironment["MCI_TRANSCRIPT_REFRESH_ENABLED"] = "0"
        // Pre-opt-in daemons only understand the legacy kill switch.
        agentEnvironment["MCI_TRANSCRIPT_REFRESH_DISABLED"] = "1"
        if crashReportOptedIn {
            agentEnvironment["MCI_CRASH_REPORT_OPTED_IN"] = "1"
        } else {
            agentEnvironment.removeValue(forKey: "MCI_CRASH_REPORT_OPTED_IN")
        }

        return ProcessSupervisorLaunchPlan(
            helperExecutableURL: helperURL,
            helperArguments: helperArguments,
            helperEnvironment: childEnvironment,
            agentExecutableURL: agentURL,
            agentArguments: ["--drain-stdin", "--strict", "--db-path", dbPath.path],
            agentEnvironment: agentEnvironment
        )
    }
}

/// Whether remembering is on, paused or off, as setup is told when the app
/// opens it (`MCI_ONBOARDING_REMEMBERING`, OnboardingKit's
/// `RememberingState`). Setup shown again reads it on Try it: off or paused
/// says so and how to turn it on, instead of reading nothing and stalling. A
/// first run ignores it, since consent in that run turns remembering on.
public enum SetupRemembering: String, CaseIterable, Sendable {
    case on
    case paused
    case off

    public static let environmentKey = "MCI_ONBOARDING_REMEMBERING"
}

/// Requests the app writes on the capture helper's lease, its standard
/// input, one byte each. Only this app holds the write end.
enum HelperLeaseCommand {
    /// One fresh read of the window in front (Ask opened). Equal to the
    /// helper's `FreshReadRequest.byte`.
    static let freshRead: UInt8 = 0x72

    /// Writes `byte` without blocking the caller and without SIGPIPE. False
    /// when the helper is gone or has stopped reading.
    static func send(_ byte: UInt8, to handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        if flags & O_NONBLOCK == 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 { return false }
        var value = byte
        return Darwin.write(descriptor, &value, 1) == 1
    }
}

/// How the app talks to a window process that runs (`openRecallUI`).
@MainActor
package protocol RecallWindowCommanding: AnyObject {
    /// Sends `command` to the window process `processID` and returns whether
    /// it answered, within `timeout`, that it shows its window.
    func command(_ command: [String: Any], processID: pid_t, timeout: Duration) async -> Bool
}

/// The app's channel to its window: distributed notifications, sent and
/// answered at once, so a window in the background hears the command before
/// anything brings it forward (RecallUIKit's `RecallLaunchRequest` has the
/// same names). Tests make up their own names.
@MainActor
package final class DistributedRecallWindowChannel: RecallWindowCommanding {
    package static let requestIDKey = "request_id"
    package let commandName: Notification.Name
    package let acknowledgementName: Notification.Name

    package init(
        commandName: Notification.Name = Notification.Name("ai.hippocampus.recall.command.v1"),
        acknowledgementName: Notification.Name = Notification.Name("ai.hippocampus.recall.command.shown.v1")
    ) {
        self.commandName = commandName
        self.acknowledgementName = acknowledgementName
    }

    package func command(_ command: [String: Any], processID: pid_t, timeout: Duration) async -> Bool {
        let id = UUID().uuidString
        var userInfo = command
        userInfo[Self.requestIDKey] = id
        let answered = OSAllocatedUnfairLock(initialState: false)
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: acknowledgementName, object: String(processID), queue: .main) { note in
            guard note.userInfo?[Self.requestIDKey] as? String == id else { return }
            answered.withLock { $0 = true }
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(commandName, object: nil, userInfo: userInfo, deliverImmediately: true)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !answered.withLock({ $0 }) {
            await FoundationSupervisorTopology.pause(for: .milliseconds(10))
        }
        return answered.withLock { $0 }
    }
}

/// Sends nothing and never answers: the default outside the app, so no test
/// ever messages a real window.
@MainActor
package final class SilentRecallWindowChannel: RecallWindowCommanding {
    package init() {}
    package func command(_ command: [String: Any], processID: pid_t, timeout: Duration) async -> Bool { false }
}

@MainActor
public final class ProcessSupervisor: ObservableObject, Sendable {
    @Published public private(set) var state: SupervisorState = .idle {
        didSet { stateChanged() }
    }
    @Published public private(set) var health: HealthSnapshot?
    @Published public private(set) var captureReceipt: CaptureStatusReceipt?
    public private(set) var captureStartedAt: Date?
    /// It may still be reading the screen though a stop was asked for: the
    /// status says "Couldn’t stop" (product critique 3, RULINGS S10).
    public var stopFailed: Bool { stopRequestFailed || captureHelperSurvivedStop }
    /// The person asked it to stop, pause, turn off or quit, and that failed:
    /// the helper, consent or the saved setting. Cleared by the next
    /// committed transition.
    @Published private var stopRequestFailed = false
    /// A stop threw while a capture helper may have been held, by any change:
    /// a start's cleanup, a restart, Try Again, a turn-on's rollback. Cleared
    /// once a later stop returns (RULINGS B1).
    @Published private var captureHelperSurvivedStop = false
    /// When the person pressed macOS's Stop Sharing; nil once remembering is
    /// turned back on. Kept across launches (spec-shell S5).
    @Published public private(set) var stoppedSharingAt: Date?
    /// Why the last Turn On did not take, while remembering stays off, so the
    /// status says so instead of a silent "Off". Cleared by the next Turn On,
    /// a turn-off or Quit.
    @Published public private(set) var turnOnFailure: TurnOnFailure?
    /// Turn On was pressed and has not landed; it may be waiting out a change
    /// under way, since a press is never dropped.
    @Published private var pendingTurnOn: UUID?
    /// The turn-on under way, from taking the transition gate to its commit
    /// or failure.
    @Published private var enablingAttempt: UUID?
    private var turnOnAttempts = 0
    /// The person chose Open System Settings… for the permission the status
    /// names, so the next look tries again, once.
    private var permissionFixChosen = false
    /// Pause presses, so a turn-on a pause stopped is not called a failure.
    private var pauseRequests = 0
    private var pauseRequestsAtAttempt = 0

    /// A turn-on is under way: pressed or switching on, and not landed yet.
    public var turningOn: Bool { pendingTurnOn != nil || enablingAttempt != nil }
    /// A stop is under way that may still leave the screen read until it is
    /// done: a turn-off (the setting is already off), or Quit while a capture
    /// helper may be held, as when it overtakes a turn-on. Off shows once the
    /// stop is done, never before (RULINGS B1 and S7).
    var stoppingCapture: Bool {
        if captureStopTask != nil { return true }
        let quitting = (shutdownTask != nil || shutdownRequested) && state != .stopped
        return quitting && mayHoldCaptureHelper
    }
    /// Called when the window was asked for and a failed start ended the
    /// request: the app shows Preferences, where the reason and the fix are
    /// (spec-shell S5, D9).
    public var onPresentationBlocked: (@MainActor () -> Void)?
    /// Called when remembering starts with every permission it needs: a
    /// turn-on or a restart committed and its helper found none off. A fresh
    /// helper never reports a permission restored, so the app withdraws a
    /// permission notification that would otherwise stay up.
    public var onRememberingStarted: (@MainActor () -> Void)?

    public var menuBarStatus: MenuBarStatus {
        MenuBarStatus.derive(
            from: shownState, captureEnabled: captureEnabled,
            tccRevokedSurface: tccRevokedSurface, receipt: captureReceipt,
            helperHealth: health, captureStartedAt: captureStartedAt,
            stopFailed: stopFailed, stopping: stoppingCapture,
            turningOn: turningOn, turnOnFailure: turnOnFailure,
            skipSeenSince: skipWatch.since, now: clock()
        )
    }

    /// The state the status is read from. Before the launch's first start,
    /// while its orphan sweep runs (up to about 15 s, waiting out a writer a
    /// crash left) or that start is about to begin, nothing has started but
    /// one is coming: Starting…, or Paused for a kept pause, never Off.
    private var shownState: SupervisorState {
        guard state == .idle, launchSweepRunning || startRunning else { return state }
        return requestedPauseState ? .paused : .starting
    }

    /// When the person paused; nil when not paused. Kept across launches.
    public var pausedSince: Date? { pauses.pausedSince }
    @Published public private(set) var captureEnabled: Bool
    /// A permission macOS has off for Hippocampus, as a capture helper
    /// reported it: in its readiness receipt as it started, or on stderr
    /// while it ran. Remembering never runs with one off. A start that meets
    /// it ends, and a run that meets it ends, so "Needs permission" and
    /// "Hippocampus stopped remembering" are true: the helper alone pauses
    /// itself, while the agent would still take pages from the browser
    /// extensions and Safari's consent would stay on. Remembering stays on
    /// in the setting, so the next look (the menu opening, the app becoming
    /// active) starts a fresh helper, the only reliable judge
    /// (`retryIfPermissionMayBeBack`).
    @Published public internal(set) var tccRevokedSurface: TCCRevokedReason? {
        didSet {
            guard tccRevokedSurface != nil else { return }
            // A start under way ends here at once, cancelled mid-wait. What
            // it launched is still stopped all the way: every stop runs in a
            // task of its own (`stopTopology`).
            cancelPendingRetry()
            if state == .starting {
                transitionGate.reset()
                stopAncillaryServices()
                state = .crashed(reason: Self.permissionStopReason)
            } else if state == .running, captureEnabled {
                endRunForPermission()
            }
            if captureEnabled { watchPermission() }
        }
    }

    static let permissionStopReason = "Capture permission was revoked."

    private let locator: BinaryLocator
    private let keyStore: KeyStore
    private let developmentKeyMode: DevelopmentFileKeyMode?
    private let runtimeConfig: any RuntimeConfiguring
    private let topology: any SupervisorTopologyControlling
    private let keyCustodyPreparer: any KeyCustodyPreparing
    private let captureConsentAuthority: any CaptureConsentControlling
    private let readinessTimeout: TimeInterval
    private let recoveryNow: @MainActor @Sendable () -> ContinuousClock.Instant
    private let retrySleep: @MainActor @Sendable (TimeInterval) async throws -> Void
    private let captureStatusReader: @MainActor @Sendable () -> (HealthSnapshot?, CaptureStatusReceipt?)
    private let captureStopNote: any CaptureStopNoting
    private let pauses: UserPauseController
    private let orphanSweeper: (any CaptureOrphanSweeping)?
    private let clock: @MainActor @Sendable () -> Date
    /// Whether macOS has a permission on for Hippocampus as this process can
    /// tell, nil when it cannot (`permissionVisibleHere`).
    private let permissionProbe: @MainActor @Sendable (TCCRevokedReason) -> Bool?
    private let permissionPollSleep: @MainActor @Sendable () async throws -> Void
    private var permissionWatch: Task<Void, Never>?
    private var skipWatch = SkipWatch()
    private let logger = Logger(subsystem: "ai.hippocampus", category: "supervisor")
    private var retryTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var safariInboxReader: SafariInboxReader?
    private var currentKeyReference: KeychainKeyReference = .defaultDatabaseKey
    private var retryCount = 0
    private var readyRun: (generationID: String, since: ContinuousClock.Instant)?
    private var transitionGate = SupervisorTransitionGate()
    private var pendingRetryGenerationID: String?
    private var currentGenerationID: String?
    // Invalidated async work must unwind before another topology can start.
    private var inFlightTransitions: Set<UUID> = []
    /// A capture helper was launched since the last stop that returned, so
    /// what the topology holds may be reading the screen.
    private var mayHoldCaptureHelper = false
    /// The launch's orphan sweep is still ending what an earlier run left.
    @Published private var launchSweepRunning = false
    /// A start `start()` asked for is under way, from the ask until it ends.
    @Published private var startRunning = false
    /// The memory's key, checked for a window asked for while the launch's
    /// orphan sweep runs, when no start can.
    private var windowKeyCheck: Task<Void, Never>?
    private var captureStopLatched = false
    private var captureStopTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Error>?
    private var shutdownRequested = false
    private var requestedPauseState = false
    private var pauseTask: Task<Void, Never>?
    /// The Recall executable is a single commanded child. Keeping the process
    /// handle prevents every menu action or hotkey press from launching a
    /// competing window and duplicate database reader.
    private var recallProcess: Process?
    private let recallWindowChannel: any RecallWindowCommanding
    /// Window requests, carried out one at a time in the order they came.
    private var windowRequests: [WindowRequest] = []
    private var windowRequestTask: Task<Void, Never>?
    /// Quit has closed the windows: nothing opens after.
    private var windowsRetired = false
    private var recallPresentationGate = RecallPresentationGate()
    /// This launch has read and checked the memory's key, so the window can
    /// read it too, with no second Keychain request racing the first.
    private var memoryKeyChecked = false
    /// Whether the memory's database is on disk: the agent makes it on its
    /// first run, after setup.
    private let memoryOnDisk: @MainActor @Sendable () -> Bool
    /// Every onboarding this app started that is still running: Ask tells
    /// them when it opens, and Quit stops them (spec-shell S6.3).
    private var onboardingProcesses: [Process] = []

    private static let maxRetries = 10
    private static let maxBackoff: TimeInterval = 60
    private static let stableRunDuration: Duration = .seconds(5 * 60)

    /// The app passes the stores that keep Stop Sharing and Pause across
    /// launches; the defaults keep nothing, so tests never touch a real
    /// defaults domain.
    public convenience init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring = RuntimeConfig(),
        captureStopNote: any CaptureStopNoting = NoCaptureStopNote(),
        pauses: UserPauseController = UserPauseController(),
        orphanSweeper: (any CaptureOrphanSweeping)? = nil
    ) {
        let developmentKeyMode = DevelopmentFileKeyMode.active()
        self.init(
            locator: locator,
            keyStore: developmentKeyMode.map { FileKeyStore(path: $0.keyURL) } ?? keyStore,
            runtimeConfig: runtimeConfig,
            topology: FoundationSupervisorTopology(),
            keyCustodyPreparer: AgentKeyCustodyPreparer(),
            captureConsentAuthority: CaptureConsentAuthority(),
            readinessTimeout: 10,
            developmentKeyMode: developmentKeyMode,
            captureStopNote: captureStopNote,
            pauses: pauses,
            orphanSweeper: orphanSweeper,
            memoryOnDisk: { FileManager.default.fileExists(atPath: ProcessSupervisor.databaseURL.path) },
            permissionProbe: ProcessSupervisor.permissionVisibleHere,
            recallWindowChannel: DistributedRecallWindowChannel()
        )
    }

    /// Accessibility is answered live for this process, which macOS treats as
    /// the helper's too (the helper is its child). Screen Recording is not: a
    /// process's own answer can stay "no" after the person allows it.
    public static func permissionVisibleHere(_ permission: TCCRevokedReason) -> Bool? {
        switch permission {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording, .fullDiskAccess, .automation: return nil
        }
    }

    /// `memoryOnDisk` says whether the memory's database exists. Tests that
    /// leave it out get "not yet", the first run before the agent makes it.
    package init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring,
        topology: any SupervisorTopologyControlling,
        keyCustodyPreparer: any KeyCustodyPreparing,
        captureConsentAuthority: any CaptureConsentControlling = NoopCaptureConsentAuthority(),
        readinessTimeout: TimeInterval,
        developmentKeyMode: DevelopmentFileKeyMode? = nil,
        recoveryNow: @escaping @MainActor @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        retrySleep: @escaping @MainActor @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        captureStatusReader: @escaping @MainActor @Sendable () -> (HealthSnapshot?, CaptureStatusReceipt?) = {
            (HealthSnapshot.readFromLog(), CaptureStatusReceipt.read())
        },
        captureStopNote: any CaptureStopNoting = NoCaptureStopNote(),
        pauses: UserPauseController = UserPauseController(),
        orphanSweeper: (any CaptureOrphanSweeping)? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = { Date() },
        memoryOnDisk: @escaping @MainActor @Sendable () -> Bool = { false },
        permissionProbe: @escaping @MainActor @Sendable (TCCRevokedReason) -> Bool? = { _ in nil },
        permissionPollSleep: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(2))
        },
        recallWindowChannel: any RecallWindowCommanding = SilentRecallWindowChannel()
    ) {
        self.locator = locator
        self.keyStore = developmentKeyMode.map { FileKeyStore(path: $0.keyURL) } ?? keyStore
        self.developmentKeyMode = developmentKeyMode
        self.runtimeConfig = runtimeConfig
        self.topology = topology
        self.keyCustodyPreparer = keyCustodyPreparer
        self.captureConsentAuthority = captureConsentAuthority
        self.readinessTimeout = readinessTimeout
        self.recoveryNow = recoveryNow
        self.retrySleep = retrySleep
        self.captureStatusReader = captureStatusReader
        self.captureStopNote = captureStopNote
        self.pauses = pauses
        self.orphanSweeper = orphanSweeper
        self.clock = clock
        self.memoryOnDisk = memoryOnDisk
        self.permissionProbe = permissionProbe
        self.permissionPollSleep = permissionPollSleep
        self.recallWindowChannel = recallWindowChannel
        self.captureEnabled = runtimeConfig.captureEnabled
        // A pause outlives a relaunch: start goes straight to Paused.
        self.requestedPauseState = pauses.isPaused
        self.stoppedSharingAt = captureStopNote.stoppedSharingAt
        stayOffAfterStopSharing()
    }

    /// After Stop Sharing the next launch stays off, even if saving "off" to
    /// runtime.toml failed then (spec-shell S5.3, D8): try again, and if the
    /// setting still says on, latch off for this session. A note older than
    /// runtime.toml's last change means remembering was turned on elsewhere
    /// since, so it no longer applies (critique-shell-engineering 13).
    private func stayOffAfterStopSharing() {
        guard let stopped = stoppedSharingAt, runtimeConfig.captureEnabled else { return }
        if let modified = runtimeConfig.modifiedAt, modified > stopped {
            captureStopNote.clear()
            stoppedSharingAt = nil
            return
        }
        try? runtimeConfig.setCaptureEnabled(false)
        captureEnabled = false
        guard runtimeConfig.captureEnabled else { return }
        captureStopLatched = true
        state = .stopped
        logger.error("supervisor: the person stopped sharing and capture is still on in runtime.toml; staying off")
    }

    /// Every committed move into running, paused or stopped ends a failed
    /// stop request and shows a window that was asked for
    /// (critique-shell-engineering 5). A capture helper that survived a stop
    /// is not ended by a commit, only by a stop that returns. A failed start
    /// shows the window too when there is memory to read, and otherwise ends
    /// the request.
    private func stateChanged() {
        switch state {
        case .running, .paused, .stopped:
            stopRequestFailed = false
            guard !shutdownRequested else { return }
            // Nothing of ours reads the screen now: end what an earlier run
            // left behind (spec-shell S6.4). Quit runs its own sweep.
            if state != .running {
                let moment: CaptureOrphanSweep.Moment = state == .paused ? .paused : .stopped
                Task { [weak self] in await self?.sweepOrphans(moment) }
            }
            if recallPresentationGate.consumeIfReady(state: state, memoryReady: memoryReady) {
                openRecallUI(initialTab: Self.windowTab)
            }
        case .crashed:
            if !shutdownRequested, recallPresentationGate.consumeIfReady(state: state, memoryReady: memoryReady) {
                openRecallUI(initialTab: Self.windowTab)
            } else if recallPresentationGate.consumeIfBlocked(state: state, memoryReady: memoryReady) {
                onPresentationBlocked?()
            }
        case .idle, .starting:
            break
        }
    }

    /// The window can read memory now: its database is on disk and this
    /// launch has checked its key.
    var memoryReady: Bool { memoryKeyChecked && memoryOnDisk() }

    /// A window asked for while the key was being checked opens as soon as
    /// it is, before the helper is ready.
    private func showWindowIfMemoryReady() {
        guard !shutdownRequested, shutdownTask == nil else { return }
        if recallPresentationGate.consumeIfReady(state: state, memoryReady: memoryReady) {
            openRecallUI(initialTab: Self.windowTab)
        }
    }

    /// The helper and agent running now.
    public var captureProcessIDs: Set<pid_t> { topology.childProcessIDs }

    /// End capture processes no live Hippocampus owns: at launch before
    /// `start()`, after Pause and Stop Sharing, and at Quit (spec-shell
    /// S6.4). It runs off the main thread. Quit's ends every match; the
    /// others leave this supervisor's live children, and what they started,
    /// alone. Nil outside a `.app` bundle.
    ///
    /// The launch's sweep can wait out an orphaned writer for up to 15 s.
    /// Until it returns nothing starts capture: a reopen's start is the
    /// launch's own, which follows the sweep, and a Turn On waits for it, so
    /// no new helper starts beside what the sweep is ending.
    @discardableResult
    public func sweepOrphans(_ moment: CaptureOrphanSweep.Moment) async -> CaptureOrphanSweep.Outcome? {
        guard let orphanSweeper else { return nil }
        let children: @Sendable () async -> Set<pid_t> = { [weak self] in
            await self?.captureProcessIDs ?? []
        }
        if moment == .launch {
            launchSweepRunning = true
            checkKeyForWindowDuringSweep()
        }
        defer { if moment == .launch { launchSweepRunning = false } }
        return await orphanSweeper.run(moment, liveChildren: moment == .quit ? nil : children)
    }

    /// A window asked for while the launch's orphan sweep runs waited for
    /// the sweep and the start after it, up to about 15 s. Opening the window
    /// starts no capture, so the memory's key is checked alongside the sweep
    /// for it, and the window opens as soon as that is done. A start waits
    /// for this check, so the two never ask the Keychain at once.
    private func checkKeyForWindowDuringSweep() {
        guard launchSweepRunning, !memoryKeyChecked, windowKeyCheck == nil, recallPresentationGate.isPending,
              !shutdownRequested, let agentURL = locator.agentPath() else { return }
        let reference = keyReference
        windowKeyCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.windowKeyCheck = nil }
            do {
                try await self.prepareKey(agentURL: agentURL, reference: reference)
                _ = try await KeyStoreAccess.readValidatedKey(from: self.keyStore)
                self.currentKeyReference = reference
                self.memoryKeyChecked = true
                self.showWindowIfMemoryReady()
            } catch {
                self.logger.error("supervisor: checking the memory's key for the window failed: \(error.localizedDescription)")
            }
        }
    }

    /// The Keychain item, or the development file, that holds the memory's key.
    private var keyReference: KeychainKeyReference {
        (keyStore as? FileKeyStore)?.keychainReference
            ?? (keyStore as? KeychainKeyStore)?.reference
            ?? .defaultDatabaseKey
    }

    /// Makes sure the memory's key exists where the agent reads it.
    private func prepareKey(agentURL: URL, reference: KeychainKeyReference) async throws {
        if let developmentKeyMode {
            try FileKeyStore(path: developmentKeyMode.keyURL).ensureDevelopmentKey()
        } else {
            try await keyCustodyPreparer.prepare(agentURL: agentURL, databaseURL: dbPath, keyReference: reference)
        }
    }

    /// Start remembering as the setting says. Never while a stop failed: what
    /// would not stop may still be reading, and a start, or the Paused a kept
    /// pause starts in, would hide it. "Couldn’t stop" stands until a stop
    /// returns, and its button, Quit, is the sure way (RULINGS B1, S10).
    public func start() {
        guard !captureStopLatched, captureStopTask == nil, !stopFailed, !launchSweepRunning,
              !shutdownRequested, shutdownTask == nil, !state.isActive, state != .starting else {
            return
        }
        // One start at a time: opening the app twice, or opening it and
        // pressing Turn On, asks again while the first start is still under
        // way, before it has begun or while it stops what an ended run left.
        // Cancelling it made it fail with CancellationError: a crash that on
        // a first run ended the window request and showed Preferences
        // instead, and otherwise left "Not saving" with nothing running.
        // Another change under way (Try Again's restart, a retry, a pause)
        // is never cancelled for a start either; only a retry still waiting
        // out its backoff is replaced.
        guard !startRunning, inFlightTransitions.isEmpty, pauseTask == nil else { return }
        cancelPendingRetry()
        startRunning = true
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startRunning = false }
            do {
                try await self.startAndWaitForReadiness()
            } catch {
                self.logger.error("supervisor: verified start failed: \(error.localizedDescription)")
            }
        }
    }

    package func startAndWaitForReadiness() async throws {
        guard !captureStopLatched, captureStopTask == nil, !stopFailed,
              !shutdownRequested, shutdownTask == nil else {
            throw SupervisorError.transitionInProgress
        }
        if requestedPauseState {
            try await enterKeptPause()
            return
        }
        guard let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
        retryCount = 0
        do {
            try captureConsentAuthority.disable()
            // A run that ended can leave an exited helper or agent held,
            // and the launch refuses until it is stopped.
            if topology.holdsProcesses {
                try await stopTopology(timeout: 2)
                try ensureTransitionIsActive(transitionID)
            }
            let generationID = try await startTopology(
                captureEnabled: runtimeConfig.captureEnabled,
                transitionID: transitionID
            )
            try ensureTransitionIsActive(transitionID)
            try prepareCaptureBoundary(
                captureEnabled: runtimeConfig.captureEnabled,
                generationID: generationID
            )
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
            activateTopology(captureEnabled: runtimeConfig.captureEnabled, generationID: generationID)
        } catch {
            stopAncillaryServices()
            if topology.holdsProcesses && !captureStopLatched {
                try? await stopTopology(timeout: 2)
            }
            if transitionGate.ownsTransition(transitionID) {
                transitionGate.fail(transitionID: transitionID)
                state = .crashed(reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// A pause kept from before goes straight to Paused, which owns no
    /// processes. Whatever an ended run left is stopped first, and Paused
    /// shows only once that stop has returned: until then it may still be
    /// reading, and Paused would say it is not (RULINGS B1).
    private func enterKeptPause() async throws {
        try captureConsentAuthority.disable()
        if topology.holdsProcesses {
            guard let transitionID = beginOwnedTransition() else {
                throw SupervisorError.transitionInProgress
            }
            defer { inFlightTransitions.remove(transitionID) }
            do {
                try await stopTopology(timeout: 2)
                try ensureTransitionIsActive(transitionID)
                guard transitionGate.commitStopped(transitionID: transitionID) else {
                    throw SupervisorError.transitionInProgress
                }
            } catch {
                if transitionGate.ownsTransition(transitionID) {
                    transitionGate.fail(transitionID: transitionID)
                    state = .crashed(reason: error.localizedDescription)
                }
                throw error
            }
        }
        stopAncillaryServices()
        state = .paused
    }

    public func stop() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.shutdownAndWait()
            } catch {
                self.logger.error("supervisor: verified stop failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop helper and agent completely before publishing `.stopped`.
    /// Concurrent callers await the same shutdown operation.
    public func shutdownAndWait(timeout: TimeInterval = 2) async throws {
        supersedeTurnOn()
        // The quit intent comes first, also when this joins a stop already
        // under way: a restart that stayed open may have left its stop
        // running with starts allowed again (`allowStartsAfterFailedRestart`).
        shutdownRequested = true
        if let shutdownTask {
            try await shutdownTask.value
            return
        }

        cancelPendingRetry()
        transitionGate.reset()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.revokeConsentAndStopTopology(timeout: timeout)
                self.state = .stopped
            } catch {
                self.stopRequestFailed = true
                self.state = .crashed(reason: error.localizedDescription)
                throw error
            }
        }
        shutdownTask = task
        // Quit intent survives a failed teardown. Only a new application
        // instance may start again; a wake event is not an explicit restart.
        defer { shutdownTask = nil }
        do {
            try await task.value
        } catch {
            throw error
        }
    }

    /// A restart that failed leaves Hippocampus open: its stop failed, could
    /// not be verified in time, or its relaunch could not be scheduled. The
    /// quit intent that keeps anything from starting again would leave Turn
    /// On, Try Again and opening the app doing nothing, silently, until Quit,
    /// so it ends here, whatever the stop did:
    ///
    /// - A stop that landed: Off, and Turn On works.
    /// - A stop still under way past the coordinator's bound: nothing starts
    ///   until it lands (every start waits for `shutdownTask`); then it is
    ///   Off, and Turn On works.
    /// - A stop that failed: "Couldn’t stop" stands, and still no start runs
    ///   over it (`stopFailed`), but opening the app shows the window, as
    ///   after any other stop that failed.
    ///
    /// Restart or Quit again sets the intent again (`shutdownAndWait`).
    public func allowStartsAfterFailedRestart() {
        shutdownRequested = false
    }

    /// Quit could not verify a clean stop in time. The app is exiting and its
    /// children follow the parent lease, so make certain nothing relaunches,
    /// revoke capture consent, try one more bounded stop, and publish
    /// `.stopped`. Only `ApplicationTerminationCoordinator` calls this, and
    /// only for a quit; a restart still requires the verified stop.
    public func forceStopForQuit(timeout: TimeInterval) async {
        supersedeTurnOn()
        shutdownRequested = true
        cancelPendingRetry()
        transitionGate.reset()
        do {
            try captureConsentAuthority.disable()
        } catch {
            logger.error("supervisor: capture consent revocation failed on forced quit: \(error.localizedDescription)")
        }
        stopAncillaryServices(revokeCaptureConsent: false)
        let topology = topology
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            func finish() {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            Task { @MainActor in
                try? await topology.stop(timeout: timeout)
                finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout * 2 + 1))
                finish()
            }
        }
        state = .stopped
    }

    /// Pause or resume. The pause and its time are kept, so it outlives a
    /// relaunch (spec-shell S5).
    public func setPaused(_ paused: Bool) {
        if paused {
            // The newer word: a press still waiting is dropped. A turn-on
            // already starting lands unless the pause stops it, and one the
            // pause stopped says nothing about failing.
            pendingTurnOn = nil
            pauseRequests += 1
        }
        pauses.setPaused(paused)
        requestedPauseState = paused
        guard !shutdownRequested, shutdownTask == nil else { return }
        guard state == .starting || state == .running || state == .paused || pauseTask != nil else {
            return
        }
        guard pauseTask == nil else { return }
        pauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pauseTask = nil }
            while !Task.isCancelled {
                let requested = self.requestedPauseState
                let alreadyApplied = requested
                    ? self.state == .paused
                    : self.state == .running
                if alreadyApplied { return }
                do {
                    try await self.setPausedAndWait(requested)
                } catch {
                    self.logger.error("supervisor: verified pause transition failed: \(error.localizedDescription)")
                    // A newer word came while this one ran (Pause pressed
                    // while a resume started): it is carried out, not
                    // dropped with the failure.
                    guard requested != self.requestedPauseState else { return }
                    continue
                }
                if requested == self.requestedPauseState { return }
            }
        }
    }

    /// A user pause owns no child processes. Stopping the full topology keeps
    /// the helper's parent-lifetime lease responsive and makes owner death
    /// fail closed; resume starts and verifies a fresh generation.
    package func setPausedAndWait(_ paused: Bool) async throws {
        guard !captureStopLatched, captureStopTask == nil,
              !shutdownRequested, shutdownTask == nil else {
            throw SupervisorError.transitionInProgress
        }

        if paused {
            // A start that failed, as a resume can: Paused once what it
            // left is stopped, as a kept pause at launch.
            if case .crashed = state {
                cancelPendingRetry()
                try await enterKeptPause()
                return
            }
            guard state == .starting || state == .running else { return }
            cancelPendingRetry()
            if state == .starting {
                transitionGate.reset()
                do {
                    try await revokeConsentAndStopTopology(timeout: 5)
                    try Task.checkCancellation()
                    guard !shutdownRequested, shutdownTask == nil else {
                        throw SupervisorError.transitionInProgress
                    }
                    state = .paused
                } catch {
                    if !shutdownRequested {
                        stopRequestFailed = true
                        state = .crashed(reason: error.localizedDescription)
                    }
                    throw error
                }
                return
            }
            guard let transitionID = beginOwnedTransition() else {
                throw SupervisorError.transitionInProgress
            }
            defer { inFlightTransitions.remove(transitionID) }
            do {
                try await revokeConsentAndStopTopology(timeout: 5)
                try ensureTransitionIsActive(transitionID)
                guard transitionGate.commitStopped(transitionID: transitionID) else {
                    throw SupervisorError.transitionInProgress
                }
                state = .paused
            } catch {
                if transitionGate.ownsTransition(transitionID) {
                    transitionGate.fail(transitionID: transitionID)
                    stopRequestFailed = true
                    state = .crashed(reason: error.localizedDescription)
                } else {
                    await stopUncommittedTopologyIfNeeded()
                }
                throw error
            }
            return
        }

        guard state == .paused else { return }
        cancelPendingRetry()
        guard let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
        do {
            let generationID = try await startTopology(
                captureEnabled: captureEnabled,
                transitionID: transitionID
            )
            try ensureTransitionIsActive(transitionID)
            try prepareCaptureBoundary(
                captureEnabled: captureEnabled,
                generationID: generationID
            )
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
            activateTopology(captureEnabled: captureEnabled, generationID: generationID)
        } catch {
            if transitionGate.ownsTransition(transitionID) {
                transitionGate.fail(transitionID: transitionID)
                state = .crashed(reason: error.localizedDescription)
            } else {
                await stopUncommittedTopologyIfNeeded()
            }
            throw error
        }
    }

    public func applyCaptureEnabled(_ enabled: Bool) async throws {
        // Disabling must also cancel an enable whose setting is not published yet.
        if !enabled {
            try await requestCaptureStop().value
            return
        }
        guard !shutdownRequested, shutdownTask == nil else {
            throw SupervisorError.transitionInProgress
        }
        guard enabled != captureEnabled else { return }
        guard let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
        // Only once this change owns the gate: a start under way (the app's
        // own at launch, a reopen, Try Again) runs in the retry task, and
        // cancelling it before a refusal left "Not saving" with nothing
        // running. A retry waiting out its backoff is replaced by this one.
        cancelPendingRetry()
        let attempt = beginTurnOnAttempt()
        defer { endTurnOnAttempt(attempt) }
        do {
            try await turnCaptureOn(transitionID: transitionID)
        } catch {
            noteTurnOnFailure(error, attempt: attempt)
            throw error
        }
    }

    /// The verified change to on: stop what runs, start and verify the
    /// capture generation, save the setting, commit. On failure the prior
    /// topology is restarted and verified before the error is rethrown, so
    /// remembering stays off.
    private func turnCaptureOn(transitionID: UUID) async throws {
        let prior = captureEnabled

        do {
            try await revokeConsentAndStopTopology(timeout: 5)
            try ensureTransitionIsActive(transitionID)
        } catch {
            if transitionGate.ownsTransition(transitionID) {
                transitionGate.fail(transitionID: transitionID)
                state = .crashed(reason: error.localizedDescription)
            }
            throw error
        }

        do {
            // A failed capture start rolls back below, and that says how
            // the change ended. A helper that found a permission off ends
            // the start inside it: the press does not land, and remembering
            // stays off with "Needs permission".
            let generationID = try await startTopology(
                captureEnabled: true,
                transitionID: transitionID,
                publishesFailure: false
            )
            try ensureTransitionIsActive(transitionID)
            try prepareCaptureBoundary(
                captureEnabled: true,
                generationID: generationID
            )
            try runtimeConfig.setCaptureEnabled(true)
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
            captureEnabled = true
            captureStopLatched = false
            // Turned back on: the Stop Sharing note and any pause are over
            // (spec-shell S5, D10).
            stoppedSharingAt = nil
            captureStopNote.clear()
            requestedPauseState = false
            pauses.setPaused(false)
            activateTopology(captureEnabled: true, generationID: generationID)
        } catch {
            let requestedError = error
            guard transitionGate.ownsTransition(transitionID) else {
                await stopUncommittedTurnOn()
                throw requestedError
            }
            // What the failed start launched may still be reading until it
            // is stopped (RULINGS B1). A helper or agent that exited is
            // still held, and the rollback's launch refuses until it is.
            do {
                if topology.holdsProcesses {
                    try await stopTopology(timeout: 5)
                    try ensureTransitionIsActive(transitionID)
                }
                stopAncillaryServices()
                let rollbackGenerationID = try await startTopology(
                    captureEnabled: prior,
                    transitionID: transitionID
                )
                try ensureTransitionIsActive(transitionID)
                try prepareCaptureBoundary(
                    captureEnabled: prior,
                    generationID: rollbackGenerationID
                )
                guard transitionGate.commit(
                    generationID: rollbackGenerationID,
                    transitionID: transitionID
                ) else {
                    throw SupervisorError.transitionInProgress
                }
                captureEnabled = prior
                activateTopology(captureEnabled: prior, generationID: rollbackGenerationID)
            } catch {
                if transitionGate.ownsTransition(transitionID) {
                    transitionGate.fail(transitionID: transitionID)
                    captureEnabled = prior
                    // A capture helper that would not stop has already set
                    // "Couldn’t stop" (`stopTopology`); one that stopped,
                    // before an off topology that would not start, has not.
                    state = .crashed(
                        reason: "Capture change failed and prior topology could not be restored: \(error.localizedDescription)"
                    )
                } else {
                    await stopUncommittedTopologyIfNeeded()
                }
            }
            throw requestedError
        }
    }

    // MARK: - Turning on (never a silent Off)

    /// Turn On, from the menu, Ask's footer or Preferences' status row. A
    /// press during another change (a start, a stop, a pause) waits for it
    /// and is never dropped. Starting… shows until remembering is on; if it
    /// cannot turn on, the status says why while remembering stays off: a
    /// permission macOS has off, with Open System Settings…, or that it
    /// didn't start, with Try Again.
    public func turnOn() {
        guard !shutdownRequested, shutdownTask == nil else { return }
        if captureEnabled {
            // On but not running: start it. Turning on ends a pause
            // (spec-shell S5).
            setPaused(false)
            start()
            return
        }
        // A new press is a new try: Starting…, not the old reason. That
        // includes the permission the last try found off: the fresh helper
        // this press starts reports it again if it still is, and until then
        // the menu that press opened (a look after Open System Settings…)
        // shows Starting… with Turn Off, so the turn-on can be dropped.
        turnOnFailure = nil
        tccRevokedSurface = nil
        guard pendingTurnOn == nil else { return }
        let press = UUID()
        pendingTurnOn = press
        Task { @MainActor [weak self] in await self?.carryOutTurnOn(press) }
    }

    /// How long a press waits for a change under way before saying it
    /// couldn't turn on. Every start and stop is bounded well inside it.
    private static let turnOnWait: Duration = .seconds(60)

    private func carryOutTurnOn(_ press: UUID) async {
        defer { if pendingTurnOn == press { pendingTurnOn = nil } }
        let giveUpAt = recoveryNow().advanced(by: Self.turnOnWait)
        while pendingTurnOn == press, !captureEnabled, !shutdownRequested, shutdownTask == nil {
            if !changeUnderWay {
                let tried = turnOnAttempts
                do {
                    try await applyCaptureEnabled(true)
                    return
                } catch {
                    // An attempt that ran has said why it failed, or was
                    // overtaken by a turn-off, a pause or Quit.
                    if turnOnAttempts != tried { return }
                    // None ran: another change took the gate first.
                }
            }
            guard recoveryNow() < giveUpAt else {
                guard pendingTurnOn == press, !captureEnabled else { return }
                logger.error("supervisor: Turn On waited too long for another change to finish")
                turnOnFailure = .didNotStart(reason: SupervisorError.transitionInProgress.localizedDescription)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A start, a stop, a pause or a capture change holds the transition gate.
    private var changeUnderWay: Bool {
        !inFlightTransitions.isEmpty || captureStopTask != nil || pauseTask != nil || launchSweepRunning
    }

    private func beginTurnOnAttempt() -> UUID {
        let attempt = UUID()
        turnOnAttempts += 1
        pauseRequestsAtAttempt = pauseRequests
        enablingAttempt = attempt
        turnOnFailure = nil
        // This attempt is the look a chosen Open System Settings… asked for.
        permissionFixChosen = false
        // Nothing reports permissions while remembering is off, so one an
        // earlier run reported off cannot be told current. The fresh helper
        // this attempt starts reports it again if it still is, as for Try
        // Again (critique-shell-engineering 6).
        tccRevokedSurface = nil
        return attempt
    }

    private func endTurnOnAttempt(_ attempt: UUID) {
        if enablingAttempt == attempt { enablingAttempt = nil }
    }

    /// Why a turn-on did not take, kept while remembering stays off, unless
    /// a turn-off, a pause or Quit overtook it.
    private func noteTurnOnFailure(_ error: Error, attempt: UUID) {
        guard enablingAttempt == attempt, !captureEnabled, !shutdownRequested,
              pauseRequests == pauseRequestsAtAttempt else { return }
        logger.error("supervisor: turning remembering on failed: \(error.localizedDescription)")
        turnOnFailure = tccRevokedSurface.map(TurnOnFailure.permission)
            ?? .didNotStart(reason: error.localizedDescription)
    }

    /// A turn-off or Quit is the newer word, and each stops what runs: a
    /// turn-on waiting or under way ends without a reason to show, and an old
    /// reason goes.
    private func supersedeTurnOn() {
        pendingTurnOn = nil
        enablingAttempt = nil
        turnOnFailure = nil
        permissionFixChosen = false
    }

    /// Stops what a turn-on launched and could not commit, unless a turn-off,
    /// a pause or Quit under way owns the teardown. A latch left by an
    /// earlier turn-off is not one: honoring it would leave a helper waiting
    /// on a permission, to start reading on its own once it is allowed.
    private func stopUncommittedTurnOn() async {
        guard captureStopTask == nil, pauseTask == nil,
              !shutdownRequested, shutdownTask == nil else { return }
        if topology.holdsProcesses {
            // One that would not stop may still read: `stopTopology` says
            // "Couldn’t stop" (RULINGS B1).
            try? await stopTopology(timeout: 2)
        }
        stopAncillaryServices()
    }

    /// A capture run whose helper reported a permission off ends: consent and
    /// Safari's pages stop at once, the status says Needs permission, and
    /// the helper and agent stop. A change already under way (a pause, a
    /// turn-off) stops the run itself. A stop that fails is "Couldn’t stop",
    /// as any other (`stopTopology`).
    private func endRunForPermission() {
        guard let transitionID = beginOwnedTransition() else { return }
        stopAncillaryServices()
        state = .crashed(reason: Self.permissionStopReason)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightTransitions.remove(transitionID) }
            do {
                try await self.stopTopology(timeout: 2)
                self.transitionGate.commitStopped(transitionID: transitionID)
                // A pause asked for while it stopped is Paused now that
                // nothing runs.
                if self.requestedPauseState, case .crashed = self.state { self.state = .paused }
            } catch {
                self.logger.error("supervisor: stopping a run a permission ended failed: \(error.localizedDescription)")
                self.transitionGate.fail(transitionID: transitionID)
            }
        }
    }

    /// While remembering is on and stopped on a permission this process can
    /// see for itself, watch it: when it goes from off to on, look again, as
    /// the menu opening would. A helper paused on Accessibility used to
    /// resume by itself; a run ended on it now starts again the same way.
    /// Only a change counts, so a permission this process sees on while the
    /// helper said off is never tried over and over.
    private func watchPermission() {
        guard permissionWatch == nil else { return }
        permissionWatch = Task { @MainActor [weak self] in
            var sawOff = false
            while !Task.isCancelled {
                guard let self, self.captureEnabled, let permission = self.tccRevokedSurface,
                      let on = self.permissionProbe(permission) else { break }
                if !on {
                    sawOff = true
                } else if sawOff {
                    sawOff = false
                    self.retryIfPermissionMayBeBack()
                }
                do { try await self.permissionPollSleep() } catch { break }
            }
            self?.permissionWatch = nil
        }
    }

    /// `publishesFailure` false leaves the state to a caller that will roll
    /// back: a crash published now would be read as the end of the change,
    /// which ends a window asked for on a first run, and the rollback would
    /// then undo it.
    private func startTopology(
        captureEnabled requestedCapture: Bool,
        transitionID: UUID,
        publishesFailure: Bool = true
    ) async throws -> String {
        try ensureTransitionIsActive(transitionID)
        guard !requestedCapture || tccRevokedSurface == nil else {
            throw SupervisorError.transitionInProgress
        }
        state = .starting
        guard let helperURL = locator.helperPath() else {
            try failStart(SupervisorError.binaryNotFound("MCICaptureHelper"), publishing: publishesFailure)
        }
        guard let agentURL = locator.agentPath() else {
            try failStart(SupervisorError.binaryNotFound("mci-agent"), publishing: publishesFailure)
        }

        let reference = keyReference
        var launchingGenerationID: String?
        do {
            // Never two Keychain requests at once: a check for the window
            // during the launch's sweep finishes first.
            if let windowKeyCheck { await windowKeyCheck.value }
            try await prepareKey(agentURL: agentURL, reference: reference)
            try ensureTransitionIsActive(transitionID)
            _ = try await KeyStoreAccess.readValidatedKey(from: keyStore)
            try ensureTransitionIsActive(transitionID)
            currentKeyReference = reference
            memoryKeyChecked = true
            showWindowIfMemoryReady()

            let generation = try SupervisorProcessGeneration.make(
                captureEnabled: requestedCapture
            )
            launchingGenerationID = generation.id
            currentGenerationID = generation.id
            let plan = ProcessSupervisorLaunchPlan.make(
                helperURL: helperURL,
                agentURL: agentURL,
                dbPath: dbPath,
                keyReference: reference,
                developmentKeyMode: developmentKeyMode,
                knownSafeAppsURL: locator.knownSafeAppsPath(),
                captureEnabled: requestedCapture,
                crashReportOptedIn: runtimeConfig.crashReportOptedIn,
                generation: generation
            )
            captureStartedAt = clock()
            captureReceipt = nil
            health = nil
            skipWatch = SkipWatch()
            // What the topology holds from here: this launch's processes, or,
            // when the launch is refused for processes still held, those too.
            mayHoldCaptureHelper = requestedCapture || (topology.holdsProcesses && mayHoldCaptureHelper)
            try await topology.launch(
                plan: plan,
                generation: generation,
                onUnexpectedExit: { [weak self] label, status in
                    self?.handleUnexpectedExit(
                        generationID: generation.id,
                        label: label,
                        status: status
                    )
                }
            )
            try ensureTransitionIsActive(transitionID)
            try await topology.waitForReadiness(
                generation: generation,
                timeout: readinessTimeout
            )
            // The fresh capture helper found a permission off as it started.
            // It is paused on it: it may start reading by itself once that
            // is allowed, or never see the grant (Screen Recording). So this
            // start does not land, whichever change it serves: a Turn On
            // stays off, a start or a restart ends with Needs permission,
            // exactly as when the helper's stderr report beats its readiness.
            // That report is read once a second, so it used to arrive after
            // the commit most of the time.
            if requestedCapture, let permission = topology.permissionOffAtReadiness {
                tccRevokedSurface = permission
            }
            try ensureTransitionIsActive(transitionID)
            guard topology.isRunning else {
                throw SupervisorProcessRuntimeError.invalidReadiness
            }
            return generation.id
        } catch {
            if case SupervisorProcessRuntimeError.helperExited(82) = error,
               launchingGenerationID == currentGenerationID {
                // Readiness can observe the exit before its delegate callback.
                noteStoppedSharing()
                _ = try? await requestCaptureStop().value
            }
            // Whatever the failed start left is torn down, running or not:
            // a helper whose agent exited may still be reading, and an
            // exited one keeps the next launch from starting.
            if topology.holdsProcesses && !captureStopLatched {
                try? await stopTopology(timeout: 2)
            }
            if !topology.holdsProcesses { mayHoldCaptureHelper = false }
            stopAncillaryServices()
            if publishesFailure, transitionGate.ownsTransition(transitionID) {
                state = .crashed(reason: error.localizedDescription)
            }
            throw error
        }
    }

    private func ensureTransitionIsActive(_ transitionID: UUID) throws {
        try Task.checkCancellation()
        guard !shutdownRequested, transitionGate.ownsTransition(transitionID) else {
            throw SupervisorError.transitionInProgress
        }
    }

    private func beginOwnedTransition() -> UUID? {
        guard inFlightTransitions.isEmpty, captureStopTask == nil, !launchSweepRunning,
              let id = transitionGate.beginTransition() else { return nil }
        inFlightTransitions.insert(id)
        return id
    }

    /// User intent is latched before any suspension. Persistence, consent and
    /// shutdown are all attempted independently; none can roll capture back on.
    private func requestCaptureStop() -> Task<Void, Error> {
        supersedeTurnOn()
        if let captureStopTask { return captureStopTask }
        captureStopLatched = true
        captureEnabled = false
        cancelPendingRetry()
        transitionGate.reset()
        currentGenerationID = nil
        let task = Task { @MainActor in
            defer { self.captureStopTask = nil }
            var failures: [String] = []
            do { try self.runtimeConfig.setCaptureEnabled(false) }
            catch {
                failures.append("Saving capture off: \(error.localizedDescription)")
                self.keepOffAcrossLaunches()
            }
            do { try await self.revokeConsentAndStopTopology(timeout: 5) }
            catch { failures.append("Stopping capture: \(error.localizedDescription)") }
            guard failures.isEmpty else {
                let error = SupervisorError.captureStopFailed(failures.joined(separator: "; "))
                self.stopRequestFailed = true
                self.state = .crashed(reason: error.localizedDescription)
                throw error
            }
            self.state = .stopped
        }
        captureStopTask = task
        return task
    }

    private func activateTopology(captureEnabled: Bool, generationID: String) {
        // All callers have verified child readiness and committed this generation.
        readyRun = (generationID, recoveryNow())
        self.captureEnabled = captureEnabled
        state = .running
        startHealthPolling()
        if captureEnabled, topology.permissionOffAtReadiness == nil {
            onRememberingStarted?()
        }
    }

    private func prepareCaptureBoundary(
        captureEnabled: Bool,
        generationID: String
    ) throws {
        guard captureEnabled else {
            try captureConsentAuthority.disable()
            return
        }
        guard tccRevokedSurface == nil, !shutdownRequested else {
            throw SupervisorError.transitionInProgress
        }
        startSafariInboxReader(expectedGenerationID: generationID)
        do {
            try captureConsentAuthority.enable(generationID: generationID)
        } catch {
            safariInboxReader?.stop()
            safariInboxReader = nil
            throw error
        }
    }

    private func stopUncommittedTopologyIfNeeded() async {
        guard !captureStopLatched else { return }
        if topology.holdsProcesses {
            try? await stopTopology(timeout: 2)
        }
        stopAncillaryServices()
    }

    /// Every stop of the helper and the agent but Quit's last resort. A stop
    /// that returns has ended all the topology held. One that throws left a
    /// survivor, and a capture helper that survives may still be reading
    /// the screen, so that is "Couldn’t stop" whichever change asked for the
    /// stop: a start's cleanup, a restart, Try Again or a turn-on's rollback
    /// (RULINGS B1).
    ///
    /// The stop runs in a task of its own, so it always runs to its end. The
    /// change that asks for it may have been cancelled (a permission report,
    /// a pause or Quit ends a start that way), and a stop that ran in that
    /// task threw at its first wait, before it signalled anything: nothing
    /// had stopped, yet it read as a helper that would not stop.
    private func stopTopology(timeout: TimeInterval) async throws {
        let topology = topology
        let stop = Task { @MainActor in try await topology.stop(timeout: timeout) }
        do {
            try await stop.value
        } catch {
            if mayHoldCaptureHelper { captureHelperSurvivedStop = true }
            throw error
        }
        mayHoldCaptureHelper = false
        captureHelperSurvivedStop = false
    }

    /// Consent and child-process shutdown are independent safety boundaries.
    /// Always attempt both, then surface the strongest failure after ancillary
    /// readers and timers have been stopped.
    private func revokeConsentAndStopTopology(timeout: TimeInterval) async throws {
        var consentError: Error?
        var topologyError: Error?

        do {
            try captureConsentAuthority.disable()
        } catch {
            consentError = error
            logger.error("supervisor: capture consent revocation failed: \(error.localizedDescription)")
        }

        do {
            try await stopTopology(timeout: timeout)
        } catch {
            topologyError = error
        }

        stopAncillaryServices(revokeCaptureConsent: false)

        if let topologyError, let consentError {
            throw SupervisorError.captureStopFailed(
                "Consent: \(consentError.localizedDescription); shutdown: \(topologyError.localizedDescription)"
            )
        }
        if let topologyError { throw topologyError }
        if let consentError { throw consentError }
    }

    private func failStart(_ error: Error, publishing: Bool) throws -> Never {
        if publishing { state = .crashed(reason: error.localizedDescription) }
        throw error
    }

    private func handleUnexpectedExit(generationID: String, label: String, status: Int32) {
        if label == "helper", status == 82, generationID == currentGenerationID {
            noteStoppedSharing()
            let stopTask = requestCaptureStop()
            Task { @MainActor [weak self] in
                do { try await stopTask.value }
                catch { self?.logger.error("supervisor: user stop failed: \(error.localizedDescription)") }
            }
            return
        }
        guard state != .stopped,
              !captureStopLatched,
              !shutdownRequested,
              pendingRetryGenerationID == nil,
              transitionGate.acceptsUnexpectedExit(generationID: generationID)
        else { return }
        let exitedRun = readyRun
        let exitedAt = recoveryNow()
        stopAncillaryServices()
        state = .crashed(reason: "\(label) exited (\(status))")
        guard tccRevokedSurface == nil else { return }
        // Replenish only for the exiting ready generation. Backoff, startup,
        // pauses and retired-child callbacks cannot earn a fresh budget.
        if let exitedRun, exitedRun.generationID == generationID,
           exitedRun.since.duration(to: exitedAt) >= Self.stableRunDuration {
            retryCount = 0
        }
        pendingRetryGenerationID = generationID
        scheduleRetry(expectedGenerationID: generationID)
    }

    /// Workspace availability is not capture consent. Recover only a failed,
    /// previously enabled session; an explicit stop or pause always wins.
    public func recoverAfterWorkspaceWake() async {
        guard case .crashed = state,
              captureEnabled, runtimeConfig.captureEnabled,
              !captureStopLatched, captureStopTask == nil,
              !requestedPauseState, pauseTask == nil,
              !shutdownRequested, shutdownTask == nil,
              tccRevokedSurface == nil, inFlightTransitions.isEmpty
        else { return }
        cancelPendingRetry()
        retryCount = 0
        do {
            try await restartTopology()
        } catch {
            logger.error("supervisor: wake recovery failed: \(error.localizedDescription)")
            guard !Task.isCancelled, !captureStopLatched, !requestedPauseState,
                  !shutdownRequested, tccRevokedSurface == nil,
                  captureEnabled, runtimeConfig.captureEnabled,
                  case .crashed = state else { return }
            let recoveryID = UUID().uuidString
            pendingRetryGenerationID = recoveryID
            scheduleRetry(expectedGenerationID: recoveryID, requireCommittedGeneration: false)
        }
    }

    /// Try Again (spec-shell S2): restart remembering now, with a fresh
    /// retry budget. A permission reported turned off is cleared first,
    /// because after a failed start no helper is left to report it back on;
    /// a running helper reports a real one again on its first heartbeat
    /// (critique-shell-engineering 6). An explicit stop, a pause, a quit or
    /// a change under way wins.
    public func retryNow() {
        guard !captureStopLatched, captureStopTask == nil,
              !requestedPauseState, pauseTask == nil,
              !shutdownRequested, shutdownTask == nil,
              inFlightTransitions.isEmpty else { return }
        cancelPendingRetry()
        retryCount = 0
        tccRevokedSurface = nil
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.restartTopology()
            } catch {
                self.logger.error("supervisor: retry failed: \(error.localizedDescription)")
            }
        }
    }

    /// While "Needs permission" shows, look again when the person may have
    /// changed it: when the menu opens or the app becomes active (RULINGS
    /// S10). A fresh helper is the only reliable judge, since a process's own
    /// answer can stay "no" after the person allows it.
    ///
    /// - Remembering is on and stopped on the permission (it never runs with
    ///   one off): nothing is left running to notice it coming back, so every
    ///   look restarts it. Remembering was on, so no new consent is needed.
    /// - A turn-on found the permission off, so remembering stayed off: a look
    ///   is Turn On again, which is consent. It is pressed again once per Open
    ///   System Settings… the person chose for it, never by a menu opened to
    ///   quit, and the menu it opens shows it as Starting… with Turn Off, so
    ///   it can be dropped.
    public func retryIfPermissionMayBeBack() {
        guard !stopFailed else { return }
        if !captureEnabled, case .permission = turnOnFailure {
            guard permissionFixChosen else { return }
            permissionFixChosen = false
            turnOn()
            return
        }
        guard captureEnabled, tccRevokedSurface != nil, case .crashed = state else { return }
        permissionFixChosen = false
        retryNow()
    }

    /// What the helper's stderr says about permissions now, from the tail:
    /// the one off (Screen Recording first), or nil once every one it named
    /// is back. One that comes back while remembering is on and stopped on
    /// it (the helper said so just before its run ended) is a look: a fresh
    /// helper starts.
    public func helperReportedPermission(_ surface: TCCRevokedReason?) {
        let stoppedOnPermission = captureEnabled && tccRevokedSurface != nil
            && state == .crashed(reason: Self.permissionStopReason)
        tccRevokedSurface = surface
        if surface == nil, stoppedOnPermission, !stopFailed { retryNow() }
    }

    /// The person chose Open System Settings… for a permission the status
    /// says is off: the next look tries again (`retryIfPermissionMayBeBack`).
    func notePermissionFixChosen() {
        var turnOnFoundItOff = false
        if case .permission = turnOnFailure, !captureEnabled { turnOnFoundItOff = true }
        permissionFixChosen = turnOnFoundItOff || (captureEnabled && tccRevokedSurface != nil)
    }

    /// A status button whose change failed: the status row says where things
    /// stand, so only the log needs the error.
    func logStatusActionFailure(_ what: String, _ error: Error) {
        logger.error("supervisor: \(what, privacy: .public) failed: \(error.localizedDescription)")
    }

    /// Saving "off" failed, so runtime.toml still says on and the next
    /// launch would start capture. Keep the note Stop Sharing keeps: the next
    /// launch honours it and stays off, and it reads "You stopped it at …"
    /// (spec-shell S5.3, D8). Turning remembering back on clears it.
    private func keepOffAcrossLaunches() {
        guard stoppedSharingAt == nil else { return }
        let now = clock()
        stoppedSharingAt = now
        captureStopNote.record(now)
        logger.error("supervisor: saving capture off failed; kept a note so the next launch stays off")
    }

    /// Stop Sharing was pressed: remember when, here and across launches.
    private func noteStoppedSharing() {
        let now = clock()
        stoppedSharingAt = now
        captureStopNote.record(now)
        logger.info("supervisor: the person stopped sharing; capture is off")
    }

    private func scheduleRetry(expectedGenerationID: String, requireCommittedGeneration: Bool = true) {
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pendingRetryGenerationID == expectedGenerationID {
                    self.pendingRetryGenerationID = nil
                }
            }
            var needsCommittedGeneration = requireCommittedGeneration
            while self.retryCount < Self.maxRetries {
                self.retryCount += 1
                let delay = min(pow(2.0, Double(self.retryCount - 1)), Self.maxBackoff)
                do { try await self.retrySleep(delay) } catch { return }
                guard !Task.isCancelled,
                      self.pendingRetryGenerationID == expectedGenerationID,
                      !self.captureStopLatched, !self.requestedPauseState,
                      !self.shutdownRequested, self.tccRevokedSurface == nil,
                      !needsCommittedGeneration || self.transitionGate.canBeginRetry(
                        expectedGenerationID: expectedGenerationID
                      )
                else { return }
                needsCommittedGeneration = false
                do {
                    try await self.restartTopology()
                    return
                } catch {
                    self.logger.error("supervisor: retry failed: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled,
                  self.pendingRetryGenerationID == expectedGenerationID,
                  !self.captureStopLatched, !self.requestedPauseState,
                  !self.shutdownRequested, self.tccRevokedSurface == nil,
                  case .crashed(let reason) = self.state else { return }
            self.state = .crashed(reason:
                "Automatic recovery stopped after \(Self.maxRetries) restart attempts without a stable run. "
                + "Restart Hippocampus to try again. Last error: \(reason)"
            )
        }
    }

    private func restartTopology() async throws {
        guard !captureStopLatched, !requestedPauseState, !shutdownRequested,
              tccRevokedSurface == nil,
              let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
        state = .starting
        do {
            try await revokeConsentAndStopTopology(timeout: 2)
            try ensureTransitionIsActive(transitionID)
            let generationID = try await startTopology(
                captureEnabled: runtimeConfig.captureEnabled,
                transitionID: transitionID
            )
            try ensureTransitionIsActive(transitionID)
            try prepareCaptureBoundary(
                captureEnabled: runtimeConfig.captureEnabled,
                generationID: generationID
            )
            guard transitionGate.commit(generationID: generationID, transitionID: transitionID) else {
                throw SupervisorError.transitionInProgress
            }
            activateTopology(captureEnabled: runtimeConfig.captureEnabled, generationID: generationID)
        } catch {
            if transitionGate.ownsTransition(transitionID) {
                transitionGate.fail(transitionID: transitionID)
                state = .crashed(reason: error.localizedDescription)
            } else {
                await stopUncommittedTopologyIfNeeded()
            }
            throw error
        }
    }

    private func cancelPendingRetry() {
        retryTask?.cancel()
        retryTask = nil
        pendingRetryGenerationID = nil
    }

    private func startSafariInboxReader(expectedGenerationID: String) {
        let reader = SafariInboxReader(expectedGenerationID: expectedGenerationID)
        reader.start()
        safariInboxReader = reader
    }

    private func startHealthPolling() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCaptureStatus() }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshCaptureStatus()
    }

    public func refreshCaptureStatus() {
        let (health, receipt) = captureStatusReader()
        skipWatch.observe(receipt, at: clock())
        (self.health, captureReceipt) = (health, receipt)
    }

    /// Ask opened: ask the capture helper for one fresh read of the window in
    /// front, so "What's on this screen?" is answered from what is there now,
    /// not from the last read before the reader's rest. Nothing is asked
    /// while remembering is off, paused, stopping or without a permission;
    /// the helper skips the read for an excluded app, a password manager, a
    /// private window or a password field, as for any other.
    @discardableResult
    public func requestFreshRead() -> Bool {
        guard state == .running, captureEnabled, !requestedPauseState, !captureStopLatched,
              captureStopTask == nil, !shutdownRequested, shutdownTask == nil, tccRevokedSurface == nil
        else { return false }
        return topology.requestFocusedRead()
    }

    private func stopAncillaryServices(revokeCaptureConsent: Bool = true) {
        readyRun = nil
        if revokeCaptureConsent {
            do {
                try captureConsentAuthority.disable()
            } catch {
                logger.error("supervisor: capture consent revocation failed: \(error.localizedDescription)")
            }
        }
        safariInboxReader?.stop()
        safariInboxReader = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Where the window opens when the app is opened (RULINGS X9).
    static let windowTab = "overview"

    /// Show the window: at once when there is memory to read, whatever
    /// remembering is doing; otherwise once remembering is running, paused or
    /// stopped. When a start failed before there was memory to read, the app
    /// shows Preferences instead (spec-shell S5, D9).
    public func openRecallWhenReady(initialLaunch: Bool = false) {
        guard !shutdownRequested, shutdownTask == nil else { return }
        if recallPresentationGate.request(initialLaunch: initialLaunch, state: state, memoryReady: memoryReady) {
            openRecallUI(initialTab: Self.windowTab)
        } else if recallPresentationGate.consumeIfBlocked(state: state, memoryReady: memoryReady) {
            onPresentationBlocked?()
        } else {
            checkKeyForWindowDuringSweep()
        }
    }

    /// The person opened Hippocampus again while it runs: the window, in any
    /// state of remembering (Oct 18), and a start for a run that ended or
    /// never began. A stop, a pause or a quit stays as it is, and so does a
    /// stop that failed: `start()` leaves "Couldn’t stop" standing.
    public func reopenWindow() {
        openRecallWhenReady()
        if !state.isActive && state != .starting {
            start()
        }
    }

    /// Setup, for a person who opened Hippocampus before finishing it: the
    /// setup this app already opened comes forward, so a second one never
    /// starts beside it.
    @discardableResult
    public func showOnboarding() -> Bool {
        if let open = onboardingProcesses.last(where: \.isRunning) {
            NSRunningApplication(processIdentifier: open.processIdentifier)?
                .activate(options: [.activateAllWindows])
            return true
        }
        return openOnboarding()
    }

    private struct WindowRequest {
        let tab: String?
        let focusEventId: UInt64?
        let openPopup: Bool
    }

    /// How long a window that runs has to say it shows itself, and how long
    /// one that said nothing has to end before a fresh one opens.
    static let windowAnswerWait: Duration = .milliseconds(500)
    static let windowExitWait: Duration = .seconds(3)

    /// Show the window on `initialTab`. Every way of opening it comes here:
    /// opening Hippocampus, the menu's Open Hippocampus, Ask, a link.
    ///
    /// The window's process ends with its last window. A process that runs is
    /// asked first, and answers only when it shows its window (a minimized
    /// one comes back out of the Dock), so nothing opens beside it. One that
    /// does not answer is quitting (its last window just closed): the request
    /// waits for it to end and opens a fresh window, on the place asked for.
    /// It used to take any running process as one that would show the
    /// window, and nothing appeared. One that neither answers nor ends is
    /// only brought forward: a second window process would be a second
    /// reader of the memory.
    public func openRecallUI(
        initialTab: String? = nil,
        focusEventId: UInt64? = nil,
        openPopup: Bool = false
    ) {
        guard !windowsRetired else { return }
        windowRequests.append(WindowRequest(tab: initialTab, focusEventId: focusEventId, openPopup: openPopup))
        guard windowRequestTask == nil else { return }
        windowRequestTask = Task { @MainActor [weak self] in
            while let self, !self.windowRequests.isEmpty {
                let request = self.windowRequests.removeFirst()
                await self.carryOut(request)
            }
            self?.windowRequestTask = nil
        }
    }

    private func carryOut(_ request: WindowRequest) async {
        guard !windowsRetired else { return }
        if let running = recallProcess, running.isRunning {
            var command: [String: Any] = ["open_popup": request.openPopup]
            if let tab = request.tab, !tab.isEmpty { command["tab"] = tab }
            if let focusEventId = request.focusEventId, focusEventId > 0 {
                command["focus_event_id"] = NSNumber(value: focusEventId)
            }
            let shown = await recallWindowChannel.command(
                command, processID: running.processIdentifier, timeout: Self.windowAnswerWait
            )
            if !shown, await Self.waitForExit(running, within: Self.windowExitWait) {
                guard !windowsRetired else { return }
                launchRecallUI(request)
                return
            }
            if !shown {
                logger.error("supervisor: the window neither answered nor ended; bringing it forward")
            }
            NSRunningApplication(processIdentifier: running.processIdentifier)?
                .activate(options: [.activateAllWindows])
            return
        }
        launchRecallUI(request)
    }

    private static func waitForExit(_ process: Process, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while process.isRunning, ContinuousClock.now < deadline {
            await FoundationSupervisorTopology.pause(for: .milliseconds(25))
        }
        return !process.isRunning
    }

    private func launchRecallUI(_ request: WindowRequest) {
        recallProcess = nil
        guard let recallPath = locator.recallUIPath() else { return }
        let environment = ProcessSupervisorLaunchPlan.recallEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference,
            developmentKeyMode: developmentKeyMode,
            initialTab: request.tab,
            focusEventId: request.focusEventId,
            openPopup: request.openPopup,
            agentURL: locator.agentPath()
        )
        do {
            let task = try ChildProcessEnvironment.makeProcess(
                preparedEnvironment: environment
            )
            task.executableURL = recallPath
            try task.run()
            recallProcess = task
        } catch {
            logger.error("supervisor: Recall launch failed: \(error.localizedDescription)")
        }
    }

    /// How the command bar starts its memory sessions: the bundled agent in
    /// `mcp-serve` mode (`--assist` adds answers and suggestions with the
    /// on-device model), with a sanitized environment that carries only the
    /// brain path and the Keychain reference. Nil before the app is set up.
    public func memorySessionLaunch(assist: Bool) -> MemorySessionLaunch? {
        guard let agent = locator.agentPath() else { return nil }
        let environment = ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference,
            developmentKeyMode: developmentKeyMode
        )
        return MemorySessionLaunch(
            executable: agent,
            arguments: assist ? ["mcp-serve", "--assist"] : ["mcp-serve"],
            environment: environment
        )
    }

    /// Retire the commanded Recall child when the owning menu-bar process exits.
    /// Capture restarts intentionally do not call this; Recall remains useful
    /// while capture is paused or a helper generation is being replaced.
    public func closeRecallUI() {
        windowsRetired = true
        windowRequests.removeAll()
        guard let recallProcess else { return }
        if recallProcess.isRunning {
            let runningApplication = NSRunningApplication(
                processIdentifier: recallProcess.processIdentifier
            )
            if runningApplication?.terminate() != true {
                recallProcess.terminate()
            }
        }
        self.recallProcess = nil
    }

    /// What setup is told about remembering when it opens: paused for a
    /// kept pause, off when the setting is off and no turn-on is under way,
    /// otherwise on.
    var rememberingForSetup: SetupRemembering {
        if requestedPauseState || state == .paused { return .paused }
        return captureEnabled || turningOn ? .on : .off
    }

    public func openOnboarding(initialStep: String? = nil) -> Bool {
        guard let path = locator.onboardingPath() else { return false }
        let task = ChildProcessEnvironment.makeProcess(
            baseEnvironment: ProcessSupervisorLaunchPlan.onboardingEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                dbPath: dbPath,
                keyReference: currentKeyReference,
                developmentKeyMode: developmentKeyMode,
                initialStep: initialStep,
                remembering: rememberingForSetup
            )
        )
        task.executableURL = path
        do {
            try task.run()
        } catch {
            logger.error("supervisor: onboarding launch failed: \(error.localizedDescription)")
            return false
        }
        onboardingProcesses = onboardingProcesses.filter(\.isRunning) + [task]
        return true
    }

    /// Whether an onboarding this app started is still open. Ask posts
    /// `ai.hippocampus.ask.didShow` only then (RULINGS X1).
    public var onboardingIsRunning: Bool { onboardingProcesses.contains(where: \.isRunning) }

    /// Ask every onboarding this app started to quit, without waiting.
    public func closeOnboarding() {
        for process in onboardingProcesses where process.isRunning {
            Self.askToQuit(process)
        }
        onboardingProcesses = []
    }

    /// On quit: ask the window and setup to quit, wait up to `timeout`, then
    /// end whatever is left with SIGTERM and SIGKILL (spec-shell S6.3).
    public func stopWindowsForQuit(timeout: TimeInterval = 1) async {
        windowsRetired = true
        windowRequests.removeAll()
        let windows = ([recallProcess] + onboardingProcesses).compactMap { $0 }.filter(\.isRunning)
        recallProcess = nil
        onboardingProcesses = []
        guard !windows.isEmpty else { return }
        windows.forEach(Self.askToQuit)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, windows.contains(where: \.isRunning) {
            if (try? await Task.sleep(for: .milliseconds(25))) == nil { break }
        }
        let survivors = windows.filter(\.isRunning)
        guard !survivors.isEmpty else { return }
        do {
            try await SupervisorProcessShutdown.stop(processes: survivors, termTimeout: 0.5, killTimeout: 0.5)
        } catch {
            logger.error("supervisor: a window did not stop at quit: \(error.localizedDescription)")
        }
    }

    /// A window quits the way a person quits it; a process that is not a
    /// registered app gets SIGTERM instead.
    private static func askToQuit(_ process: Process) {
        if NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate() != true {
            process.terminate()
        }
    }

    public var hasOnboarding: Bool { locator.onboardingPath() != nil }
    public var agentBinaryPath: URL? { locator.agentPath() }
    public func sanitizedChildEnvironment() -> [String: String] {
        ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference,
            developmentKeyMode: developmentKeyMode
        )
    }
    public var dbPath: URL { Self.databaseURL }
    /// The memory's database.
    public static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/mci.sqlite")
    }
    public var isCrashReportOptedIn: Bool { runtimeConfig.crashReportOptedIn }
    public func setCrashReportOptedIn(_ value: Bool) {
        try? runtimeConfig.setCrashReportOptedIn(value)
    }
    public var safariInboxStats: (
        forwarded: UInt64,
        droppedConsent: UInt64,
        droppedDenylist: UInt64,
        droppedSecret: UInt64,
        failedParse: UInt64
    )? {
        guard let reader = safariInboxReader else { return nil }
        return (
            reader.forwarded,
            reader.droppedConsent,
            reader.droppedDenylist,
            reader.droppedSecret,
            reader.failedParse
        )
    }
}

#if DEBUG
extension ProcessSupervisor {
    /// The off-screen renderer only: put the published status where a real
    /// run would, so Preferences draws from the real derivation.
    package func showForPreview(
        state: SupervisorState, captureEnabled: Bool, receipt: CaptureStatusReceipt?,
        startedAt: Date?, stoppedSharingAt: Date? = nil, stopFailed: Bool = false,
        turnOnFailure: TurnOnFailure? = nil, turningOn: Bool = false
    ) {
        self.captureEnabled = captureEnabled
        self.captureStartedAt = startedAt
        self.captureReceipt = receipt
        self.stoppedSharingAt = stoppedSharingAt
        self.state = state
        self.stopRequestFailed = stopFailed
        self.turnOnFailure = turnOnFailure
        // A press as the menu leaves it: nothing carries it out here.
        self.pendingTurnOn = turningOn ? UUID() : nil
    }
}
#endif

extension ProcessSupervisor: CaptureSettingApplying {}

enum SupervisorError: LocalizedError {
    case binaryNotFound(String)
    case transitionInProgress
    case captureStopFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): "\(name) binary not found"
        case .transitionInProgress: "A supervisor reconfiguration is already in progress."
        case .captureStopFailed(let reason): "Capture is disabled for this session. \(reason)"
        }
    }
}
