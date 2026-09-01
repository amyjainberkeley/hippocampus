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
        var environment = baseEnvironment
        for key in [
            "MCI_DB_KEY_HEX",
            "MCI_DB_KEY_FILE",
            "MCI_DEVELOPMENT_FILE_KEY",
            "HIPPOCAMPUS_ENABLE_V2P1",
        ] {
            environment.removeValue(forKey: key)
        }
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

    init(
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
        guard !state.isActive, state != .starting else { return }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startAndWaitForReadiness()
            } catch {
                self.logger.error("supervisor: verified start failed: \(error.localizedDescription)")
            }
        }
    }

    func startAndWaitForReadiness() async throws {
        retryCount = 0
        try await startTopology(captureEnabled: runtimeConfig.captureEnabled, publishState: true)
    }

    public func stop() {
        retryTask?.cancel()
        retryTask = nil
        stopAncillaryServices()
        state = .stopped
        Task { @MainActor [topology] in
            try? await topology.stop(timeout: 2)
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
        guard enabled != captureEnabled else { return }
        let prior = captureEnabled

        do {
            try await topology.stop(timeout: 5)
            stopAncillaryServices()
        } catch {
            state = .crashed(reason: error.localizedDescription)
            throw error
        }

        do {
            try await startTopology(captureEnabled: enabled, publishState: false)
            try runtimeConfig.setCaptureEnabled(enabled)
            captureEnabled = enabled
            state = .running
        } catch {
            let requestedError = error
            do {
                if topology.isRunning {
                    try await topology.stop(timeout: 5)
                }
                stopAncillaryServices()
                try await startTopology(captureEnabled: prior, publishState: false)
                captureEnabled = prior
                state = .running
            } catch {
                captureEnabled = prior
                state = .crashed(
                    reason: "Capture change failed and prior topology could not be restored: \(error.localizedDescription)"
                )
            }
            throw requestedError
        }
    }

    private func startTopology(captureEnabled requestedCapture: Bool, publishState: Bool) async throws {
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
            _ = try keyStore.readKey()
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
            try topology.launch(
                plan: plan,
                generation: generation,
                onUnexpectedExit: { [weak self] label, status in
                    self?.handleUnexpectedExit(label: label, status: status)
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

    private func handleUnexpectedExit(label: String, status: Int32) {
        guard state != .stopped else { return }
        stopAncillaryServices()
        state = .crashed(reason: "\(label) exited (\(status))")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryCount < Self.maxRetries else { return }
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), Self.maxBackoff)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            try? await self.topology.stop(timeout: 2)
            try? await self.startTopology(
                captureEnabled: self.runtimeConfig.captureEnabled,
                publishState: true
            )
        }
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
        let task = Process()
        task.executableURL = recallPath
        var environment = ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference
        )
        if let initialTab, !initialTab.isEmpty { environment["MCI_INITIAL_TAB"] = initialTab }
        task.environment = environment
        try? task.run()
    }

    public func openOnboarding() -> Bool {
        guard let path = locator.onboardingPath() else { return false }
        let task = Process()
        task.executableURL = path
        task.environment = ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            dbPath: dbPath,
            keyReference: currentKeyReference
        )
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

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): "\(name) binary not found"
        }
    }
}
