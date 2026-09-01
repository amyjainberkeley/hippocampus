// SPDX-License-Identifier: TBD-private
import Foundation
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
        keyReference: KeychainKeyReference
    ) -> [String: String] {
        var environment = ChildProcessEnvironment.scrubbingReusableKeys(from: baseEnvironment)
        environment["MCI_DB_PATH"] = dbPath.path
        environment["MCI_DB_KEYCHAIN_SERVICE"] = keyReference.service
        environment["MCI_DB_KEYCHAIN_ACCOUNT"] = keyReference.account
        environment["MCI_DB_KEYCHAIN_STORAGE_MODEL"] = KeychainKeyStore.storageModel
        return environment
    }

    static func make(
        helperURL: URL,
        agentURL: URL,
        dbPath: URL,
        keyReference: KeychainKeyReference,
        knownSafeAppsURL: URL?,
        captureEnabled: Bool,
        crashReportOptedIn: Bool,
        generation: SupervisorProcessGeneration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProcessSupervisorLaunchPlan {
        precondition(generation.captureEnabled == captureEnabled)
        var helperArguments = [
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
            keyReference: keyReference
        )
        var agentEnvironment = childEnvironment
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
    @Published public private(set) var captureEnabled: Bool
    @Published public internal(set) var tccRevokedSurface: TCCRevokedReason?

    private let locator: BinaryLocator
    private let keyStore: KeyStore
    private let runtimeConfig: any RuntimeConfiguring
    private let topology: any SupervisorTopologyControlling
    private let keyCustodyPreparer: any KeyCustodyPreparing
    private let readinessTimeout: TimeInterval
    private let logger = Logger(subsystem: "ai.hippocampus", category: "supervisor")
    private var retryTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var safariInboxReader: SafariInboxReader?
    private var currentKeyReference: KeychainKeyReference = .defaultDatabaseKey
    private var retryCount = 0
    private var transitionGate = SupervisorTransitionGate()
    private var pendingRetryGenerationID: String?
    private var shutdownTask: Task<Void, Error>?

    private static let maxRetries = 10
    private static let maxBackoff: TimeInterval = 60

    public convenience init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring = RuntimeConfig()
    ) {
        self.init(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: runtimeConfig,
            topology: FoundationSupervisorTopology(),
            keyCustodyPreparer: AgentKeyCustodyPreparer(),
            readinessTimeout: 10
        )
    }

    package init(
        locator: BinaryLocator,
        keyStore: KeyStore,
        runtimeConfig: any RuntimeConfiguring,
        topology: any SupervisorTopologyControlling,
        keyCustodyPreparer: any KeyCustodyPreparing,
        readinessTimeout: TimeInterval
    ) {
        self.locator = locator
        self.keyStore = keyStore
        self.runtimeConfig = runtimeConfig
        self.topology = topology
        self.keyCustodyPreparer = keyCustodyPreparer
        self.readinessTimeout = readinessTimeout
        self.captureEnabled = runtimeConfig.captureEnabled
    }

    public func start() {
        guard shutdownTask == nil, !state.isActive, state != .starting else { return }
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
        guard shutdownTask == nil else { throw SupervisorError.transitionInProgress }
        guard let transitionID = transitionGate.beginTransition() else {
            throw SupervisorError.transitionInProgress
        }
        retryCount = 0
        do {
            let generationID = try await startTopology(
                captureEnabled: runtimeConfig.captureEnabled,
                publishState: true
            )
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
        } catch {
            transitionGate.fail(transitionID: transitionID)
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

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.cancelPendingRetry()
            self.transitionGate.reset()
            do {
                try await self.topology.stop(timeout: timeout)
                self.stopAncillaryServices()
                self.state = .stopped
            } catch {
                self.state = .crashed(reason: error.localizedDescription)
                throw error
            }
        }
        shutdownTask = task
        do {
            try await task.value
            shutdownTask = nil
        } catch {
            shutdownTask = nil
            throw error
        }
    }

    public func setPaused(_ paused: Bool) {
        guard state == .running || state == .paused else { return }
        do {
            try topology.setPaused(paused)
            state = paused ? .paused : .running
        } catch {
            state = .crashed(reason: error.localizedDescription)
        }
    }

    public func applyCaptureEnabled(_ enabled: Bool) async throws {
        guard shutdownTask == nil else { throw SupervisorError.transitionInProgress }
        guard enabled != captureEnabled else { return }
        cancelPendingRetry()
        guard let transitionID = transitionGate.beginTransition() else {
            throw SupervisorError.transitionInProgress
        }
        let prior = captureEnabled

        do {
            try await topology.stop(timeout: 5)
            stopAncillaryServices()
        } catch {
            transitionGate.fail(transitionID: transitionID)
            state = .crashed(reason: error.localizedDescription)
            throw error
        }

        do {
            let generationID = try await startTopology(
                captureEnabled: enabled,
                publishState: false
            )
            try runtimeConfig.setCaptureEnabled(enabled)
            guard transitionGate.commit(
                generationID: generationID,
                transitionID: transitionID
            ) else {
                throw SupervisorError.transitionInProgress
            }
            captureEnabled = enabled
            state = .running
        } catch {
            let requestedError = error
            do {
                if topology.isRunning {
                    try await topology.stop(timeout: 5)
                }
                stopAncillaryServices()
                let rollbackGenerationID = try await startTopology(
                    captureEnabled: prior,
                    publishState: false
                )
                guard transitionGate.commit(
                    generationID: rollbackGenerationID,
                    transitionID: transitionID
                ) else {
                    throw SupervisorError.transitionInProgress
                }
                captureEnabled = prior
                state = .running
            } catch {
                transitionGate.fail(transitionID: transitionID)
                captureEnabled = prior
                state = .crashed(
                    reason: "Capture change failed and prior topology could not be restored: \(error.localizedDescription)"
                )
            }
            throw requestedError
        }
    }

    private func startTopology(
        captureEnabled requestedCapture: Bool,
        publishState: Bool
    ) async throws -> String {
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
        do {
            try await keyCustodyPreparer.prepare(
                agentURL: agentURL,
                databaseURL: dbPath,
                keyReference: reference
            )
            _ = try await KeyStoreAccess.readValidatedKey(from: keyStore)
            currentKeyReference = reference

            let generation = try SupervisorProcessGeneration.make(
                captureEnabled: requestedCapture
            )
            let plan = ProcessSupervisorLaunchPlan.make(
                helperURL: helperURL,
                agentURL: agentURL,
                dbPath: dbPath,
                keyReference: reference,
                knownSafeAppsURL: locator.knownSafeAppsPath(),
                captureEnabled: requestedCapture,
                crashReportOptedIn: runtimeConfig.crashReportOptedIn,
                generation: generation
            )
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
            try await topology.waitForReadiness(
                generation: generation,
                timeout: readinessTimeout
            )
            guard topology.isRunning else {
                throw SupervisorProcessRuntimeError.invalidReadiness
            }
            if publishState { self.captureEnabled = requestedCapture }
            state = .running
            startHealthPolling()
            startSafariInboxReader()
            return generation.id
        } catch {
            try? await topology.stop(timeout: 2)
            stopAncillaryServices()
            state = .crashed(reason: error.localizedDescription)
            throw error
        }
    }

    private func failStart(_ error: Error) throws -> Never {
        state = .crashed(reason: error.localizedDescription)
        throw error
    }

    private func handleUnexpectedExit(generationID: String, label: String, status: Int32) {
        guard state != .stopped,
              pendingRetryGenerationID == nil,
              transitionGate.acceptsUnexpectedExit(generationID: generationID)
        else { return }
        stopAncillaryServices()
        state = .crashed(reason: "\(label) exited (\(status))")
        pendingRetryGenerationID = generationID
        scheduleRetry(expectedGenerationID: generationID)
    }

    private func scheduleRetry(expectedGenerationID: String) {
        guard retryCount < Self.maxRetries else {
            pendingRetryGenerationID = nil
            return
        }
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), Self.maxBackoff)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.pendingRetryGenerationID == expectedGenerationID,
                  self.transitionGate.canBeginRetry(
                    expectedGenerationID: expectedGenerationID
                  ),
                  let transitionID = self.transitionGate.beginTransition()
            else { return }
            self.pendingRetryGenerationID = nil
            do {
                try await self.topology.stop(timeout: 2)
                let generationID = try await self.startTopology(
                    captureEnabled: self.runtimeConfig.captureEnabled,
                    publishState: true
                )
                guard self.transitionGate.commit(
                    generationID: generationID,
                    transitionID: transitionID
                ) else {
                    throw SupervisorError.transitionInProgress
                }
            } catch {
                self.transitionGate.fail(transitionID: transitionID)
                self.state = .crashed(reason: error.localizedDescription)
            }
        }
    }

    private func cancelPendingRetry() {
        retryTask?.cancel()
        retryTask = nil
        pendingRetryGenerationID = nil
    }

    private func startSafariInboxReader() {
        let reader = SafariInboxReader()
        reader.start()
        safariInboxReader = reader
    }

    private func startHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.health = HealthSnapshot.readFromLog() }
        }
        health = HealthSnapshot.readFromLog()
    }

    private func stopAncillaryServices() {
        safariInboxReader?.stop()
        safariInboxReader = nil
        healthTimer?.invalidate()
        healthTimer = nil
    }

    public func openRecallUI(initialTab: String? = nil) {
        guard let recallPath = locator.recallUIPath() else { return }
        var environment = ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference
        )
        if let initialTab, !initialTab.isEmpty { environment["MCI_INITIAL_TAB"] = initialTab }
        let task = ChildProcessEnvironment.makeProcess(baseEnvironment: environment)
        task.executableURL = recallPath
        try? task.run()
    }

    public func openOnboarding() -> Bool {
        guard let path = locator.onboardingPath() else { return false }
        let task = ChildProcessEnvironment.makeProcess(
            baseEnvironment: ProcessSupervisorLaunchPlan.sanitizedEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                dbPath: dbPath,
                keyReference: currentKeyReference
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
            keyReference: currentKeyReference
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
        droppedDenylist: UInt64,
        droppedSecret: UInt64,
        failedParse: UInt64
    )? {
        guard let reader = safariInboxReader else { return nil }
        return (reader.forwarded, reader.droppedDenylist, reader.droppedSecret, reader.failedParse)
    }
}

extension ProcessSupervisor: CaptureSettingApplying {}

enum SupervisorError: LocalizedError {
    case binaryNotFound(String)
    case transitionInProgress

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): "\(name) binary not found"
        case .transitionInProgress: "A supervisor reconfiguration is already in progress."
        }
    }
}
