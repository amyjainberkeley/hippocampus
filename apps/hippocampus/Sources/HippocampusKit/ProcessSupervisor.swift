// SPDX-License-Identifier: TBD-private
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
        initialStep: String?
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

@MainActor
public final class ProcessSupervisor: ObservableObject, Sendable {
    @Published public private(set) var state: SupervisorState = .idle
    @Published public private(set) var health: HealthSnapshot?
    @Published public private(set) var captureReceipt: CaptureStatusReceipt?
    public private(set) var captureStartedAt: Date?

    public var menuBarStatus: MenuBarStatus {
        MenuBarStatus.derive(
            from: state, captureEnabled: captureEnabled,
            tccRevokedSurface: tccRevokedSurface, receipt: captureReceipt,
            helperHealth: health, captureStartedAt: captureStartedAt
        )
    }
    @Published public private(set) var captureEnabled: Bool
    @Published public internal(set) var tccRevokedSurface: TCCRevokedReason? {
        didSet {
            guard tccRevokedSurface != nil else { return }
            cancelPendingRetry()
            if state == .starting {
                transitionGate.reset()
                stopAncillaryServices()
                state = .crashed(reason: "Capture permission was revoked.")
            }
        }
    }

    private let locator: BinaryLocator
    private let keyStore: KeyStore
    private let developmentKeyMode: DevelopmentFileKeyMode?
    private let runtimeConfig: any RuntimeConfiguring
    private let topology: any SupervisorTopologyControlling
    private let keyCustodyPreparer: any KeyCustodyPreparing
    private let captureConsentAuthority: any CaptureConsentControlling
    private let readinessTimeout: TimeInterval
    private let logger = Logger(subsystem: "ai.hippocampus", category: "supervisor")
    private var retryTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var safariInboxReader: SafariInboxReader?
    private var currentKeyReference: KeychainKeyReference = .defaultDatabaseKey
    private var retryCount = 0
    private var transitionGate = SupervisorTransitionGate()
    private var pendingRetryGenerationID: String?
    private var currentGenerationID: String?
    // Invalidated async work must unwind before another topology can start.
    private var inFlightTransitions: Set<UUID> = []
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
    private var recallPresentationGate = RecallPresentationGate()

    private static let maxRetries = 10
    private static let maxBackoff: TimeInterval = 60

    public convenience init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring = RuntimeConfig()
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
            developmentKeyMode: developmentKeyMode
        )
    }

    package init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring,
        topology: any SupervisorTopologyControlling,
        keyCustodyPreparer: any KeyCustodyPreparing,
        captureConsentAuthority: any CaptureConsentControlling = NoopCaptureConsentAuthority(),
        readinessTimeout: TimeInterval,
        developmentKeyMode: DevelopmentFileKeyMode? = nil
    ) {
        self.locator = locator
        self.keyStore = developmentKeyMode.map { FileKeyStore(path: $0.keyURL) } ?? keyStore
        self.developmentKeyMode = developmentKeyMode
        self.runtimeConfig = runtimeConfig
        self.topology = topology
        self.keyCustodyPreparer = keyCustodyPreparer
        self.captureConsentAuthority = captureConsentAuthority
        self.readinessTimeout = readinessTimeout
        self.captureEnabled = runtimeConfig.captureEnabled
    }

    public func start() {
        guard !captureStopLatched, captureStopTask == nil,
              !shutdownRequested, shutdownTask == nil, !state.isActive, state != .starting else {
            return
        }
        cancelPendingRetry()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startAndWaitForReadiness()
            } catch {
                self.logger.error("supervisor: verified start failed: \(error.localizedDescription)")
            }
        }
    }

    package func startAndWaitForReadiness() async throws {
        guard !captureStopLatched, captureStopTask == nil,
              !shutdownRequested, shutdownTask == nil else {
            throw SupervisorError.transitionInProgress
        }
        if requestedPauseState {
            try captureConsentAuthority.disable()
            stopAncillaryServices()
            state = .paused
            return
        }
        guard let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
        retryCount = 0
        do {
            try captureConsentAuthority.disable()
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
            activateTopology(captureEnabled: runtimeConfig.captureEnabled)
        } catch {
            stopAncillaryServices()
            if topology.isRunning && !captureStopLatched {
                try? await topology.stop(timeout: 2)
            }
            if transitionGate.ownsTransition(transitionID) {
                transitionGate.fail(transitionID: transitionID)
                state = .crashed(reason: error.localizedDescription)
            }
            throw error
        }
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
        if let shutdownTask {
            try await shutdownTask.value
            return
        }

        shutdownRequested = true
        cancelPendingRetry()
        transitionGate.reset()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.revokeConsentAndStopTopology(timeout: timeout)
                self.state = .stopped
            } catch {
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

    public func setPaused(_ paused: Bool) {
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
                    return
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
            activateTopology(captureEnabled: captureEnabled)
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
        cancelPendingRetry()
        guard let transitionID = beginOwnedTransition() else {
            throw SupervisorError.transitionInProgress
        }
        defer { inFlightTransitions.remove(transitionID) }
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
            let generationID = try await startTopology(
                captureEnabled: enabled,
                transitionID: transitionID
            )
            try ensureTransitionIsActive(transitionID)
            try prepareCaptureBoundary(
                captureEnabled: enabled,
                generationID: generationID
            )
            try runtimeConfig.setCaptureEnabled(enabled)
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
            captureEnabled = enabled
            captureStopLatched = false
            activateTopology(captureEnabled: enabled)
        } catch {
            let requestedError = error
            guard transitionGate.ownsTransition(transitionID) else {
                await stopUncommittedTopologyIfNeeded()
                throw requestedError
            }
            do {
                if topology.isRunning {
                    try await topology.stop(timeout: 5)
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
                activateTopology(captureEnabled: prior)
            } catch {
                if transitionGate.ownsTransition(transitionID) {
                    transitionGate.fail(transitionID: transitionID)
                    captureEnabled = prior
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

    private func startTopology(
        captureEnabled requestedCapture: Bool,
        transitionID: UUID
    ) async throws -> String {
        try ensureTransitionIsActive(transitionID)
        guard !requestedCapture || tccRevokedSurface == nil else {
            throw SupervisorError.transitionInProgress
        }
        state = .starting
        guard let helperURL = locator.helperPath() else {
            try failStart(SupervisorError.binaryNotFound("MCICaptureHelper"))
        }
        guard let agentURL = locator.agentPath() else {
            try failStart(SupervisorError.binaryNotFound("mci-agent"))
        }

        let reference = (keyStore as? FileKeyStore)?.keychainReference
            ?? (keyStore as? KeychainKeyStore)?.reference
            ?? .defaultDatabaseKey
        var launched = false
        var launchingGenerationID: String?
        do {
            if let developmentKeyMode {
                try FileKeyStore(path: developmentKeyMode.keyURL).ensureDevelopmentKey()
            } else {
                try await keyCustodyPreparer.prepare(
                    agentURL: agentURL,
                    databaseURL: dbPath,
                    keyReference: reference
                )
            }
            try ensureTransitionIsActive(transitionID)
            _ = try await KeyStoreAccess.readValidatedKey(from: keyStore)
            try ensureTransitionIsActive(transitionID)
            currentKeyReference = reference

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
            captureStartedAt = Date()
            captureReceipt = nil
            health = nil
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
            launched = true
            try ensureTransitionIsActive(transitionID)
            try await topology.waitForReadiness(
                generation: generation,
                timeout: readinessTimeout
            )
            try ensureTransitionIsActive(transitionID)
            guard topology.isRunning else {
                throw SupervisorProcessRuntimeError.invalidReadiness
            }
            return generation.id
        } catch {
            if case SupervisorProcessRuntimeError.helperExited(82) = error,
               launchingGenerationID == currentGenerationID {
                // Readiness can observe the exit before its delegate callback.
                _ = try? await requestCaptureStop().value
            }
            if launched && topology.isRunning && !captureStopLatched {
                try? await topology.stop(timeout: 2)
            }
            stopAncillaryServices()
            if transitionGate.ownsTransition(transitionID) {
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
        guard inFlightTransitions.isEmpty, captureStopTask == nil,
              let id = transitionGate.beginTransition() else { return nil }
        inFlightTransitions.insert(id)
        return id
    }

    /// User intent is latched before any suspension. Persistence, consent and
    /// shutdown are all attempted independently; none can roll capture back on.
    private func requestCaptureStop() -> Task<Void, Error> {
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
            catch { failures.append("Saving capture off: \(error.localizedDescription)") }
            do { try await self.revokeConsentAndStopTopology(timeout: 5) }
            catch { failures.append("Stopping capture: \(error.localizedDescription)") }
            guard failures.isEmpty else {
                let error = SupervisorError.captureStopFailed(failures.joined(separator: "; "))
                self.state = .crashed(reason: error.localizedDescription)
                throw error
            }
            self.state = .stopped
        }
        captureStopTask = task
        return task
    }

    private func activateTopology(captureEnabled: Bool) {
        self.captureEnabled = captureEnabled
        state = .running
        startHealthPolling()
        if recallPresentationGate.consumeIfReady(state: state) {
            openRecallUI(initialTab: "now")
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
        if topology.isRunning {
            try? await topology.stop(timeout: 2)
        }
        stopAncillaryServices()
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
            try await topology.stop(timeout: timeout)
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

    private func failStart(_ error: Error) throws -> Never {
        state = .crashed(reason: error.localizedDescription)
        throw error
    }

    private func handleUnexpectedExit(generationID: String, label: String, status: Int32) {
        if label == "helper", status == 82, generationID == currentGenerationID {
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
        stopAncillaryServices()
        state = .crashed(reason: "\(label) exited (\(status))")
        guard tccRevokedSurface == nil else { return }
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
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
            activateTopology(captureEnabled: runtimeConfig.captureEnabled)
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
        health = HealthSnapshot.readFromLog()
        captureReceipt = CaptureStatusReceipt.read()
    }

    private func stopAncillaryServices(revokeCaptureConsent: Bool = true) {
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

    public func openRecallWhenReady(initialLaunch: Bool = false) {
        if recallPresentationGate.request(initialLaunch: initialLaunch, state: state) {
            openRecallUI(initialTab: "now")
        }
    }

    public func openRecallUI(
        initialTab: String? = nil,
        focusEventId: UInt64? = nil,
        openPopup: Bool = false
    ) {
        var command: [String: Any] = ["open_popup": openPopup]
        if let initialTab, !initialTab.isEmpty { command["tab"] = initialTab }
        if let focusEventId, focusEventId > 0 {
            command["focus_event_id"] = NSNumber(value: focusEventId)
        }

        if let recallProcess, recallProcess.isRunning {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("ai.hippocampus.recall.command.v1"),
                object: nil,
                userInfo: command
            )
            NSRunningApplication(processIdentifier: recallProcess.processIdentifier)?
                .activate(options: [.activateAllWindows])
            return
        }
        recallProcess = nil

        guard let recallPath = locator.recallUIPath() else { return }
        let environment = ProcessSupervisorLaunchPlan.recallEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference,
            developmentKeyMode: developmentKeyMode,
            initialTab: initialTab,
            focusEventId: focusEventId,
            openPopup: openPopup,
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

    /// Retire the commanded Recall child when the owning menu-bar process exits.
    /// Capture restarts intentionally do not call this; Recall remains useful
    /// while capture is paused or a helper generation is being replaced.
    public func closeRecallUI() {
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

    public func openOnboarding(initialStep: String? = nil) -> Bool {
        guard let path = locator.onboardingPath() else { return false }
        let task = ChildProcessEnvironment.makeProcess(
            baseEnvironment: ProcessSupervisorLaunchPlan.onboardingEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                dbPath: dbPath,
                keyReference: currentKeyReference,
                developmentKeyMode: developmentKeyMode,
                initialStep: initialStep
            )
        )
        task.executableURL = path
        try? task.run()
        return true
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
    public var dbPath: URL {
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
