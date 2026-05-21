// SPDX-License-Identifier: TBD-private
import Foundation
import os

@MainActor
public final class ProcessSupervisor: ObservableObject, Sendable {
    @Published public private(set) var state: SupervisorState = .idle
    @Published public private(set) var health: HealthSnapshot?

    private let locator: BinaryLocator
    private let keyStore: KeyStore
    private let runtimeConfig: RuntimeConfig
    private let logger = Logger(subsystem: "ai.hippocampus", category: "supervisor")

    private var helperProcess: Process?
    private var agentProcess: Process?
    private var pipe: Pipe?
    private var helperStderrHandle: FileHandle?
    private var agentStderrHandle: FileHandle?
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var brainStatsTask: Task<Void, Never>?
    private var currentKeyHex: String?

    private static let maxRetries = 10
    private static let maxBackoff: TimeInterval = 60

    public init(locator: BinaryLocator, keyStore: KeyStore, runtimeConfig: RuntimeConfig = RuntimeConfig()) {
        self.locator = locator
        self.keyStore = keyStore
        self.runtimeConfig = runtimeConfig
    }

    public func start() {
        guard !state.isActive else { return }
        state = .starting
        retryCount = 0

        do {
            let keyHex = try resolveKey()
            currentKeyHex = keyHex
            try spawnChildren(keyHex: keyHex)
            state = .running
            startHealthPolling()
            logger.info("supervisor: started. helper PID \(self.helperProcess?.processIdentifier ?? -1), agent PID \(self.agentProcess?.processIdentifier ?? -1)")
        } catch {
            state = .crashed(reason: error.localizedDescription)
            logger.error("supervisor: start failed: \(error.localizedDescription)")
        }
    }

    public func stop() {
        retryTask?.cancel()
        retryTask = nil
        brainStatsTask?.cancel()
        brainStatsTask = nil
        healthTimer?.invalidate()
        healthTimer = nil

        terminateChild(helperProcess, label: "helper")
        terminateChild(agentProcess, label: "agent")

        helperProcess = nil
        agentProcess = nil
        pipe = nil

        try? helperStderrHandle?.close()
        try? agentStderrHandle?.close()
        helperStderrHandle = nil
        agentStderrHandle = nil

        state = .stopped
        logger.info("supervisor: stopped")
    }

    public func setPaused(_ paused: Bool) {
        guard state == .running || state == .paused else { return }
        guard let helper = helperProcess, helper.isRunning else { return }

        if paused {
            // SIGSTOP preserves SCStream session — not killed.
            // Limit: the OS may still deliver frames to the kernel
            // buffer; they drain when resumed. Acceptable for this PR.
            // TODO: IPC-based pause protocol (send "pause" message)
            // when the helper supports it.
            kill(helper.processIdentifier, SIGSTOP)
            state = .paused
            logger.info("supervisor: paused helper PID \(helper.processIdentifier) via SIGSTOP")
        } else {
            kill(helper.processIdentifier, SIGCONT)
            state = .running
            logger.info("supervisor: resumed helper PID \(helper.processIdentifier) via SIGCONT")
        }
    }

    public func openRecallUI() {
        guard let recallPath = locator.recallUIPath() else {
            logger.warning("supervisor: recall-ui binary not found")
            return
        }
        let task = Process()
        task.executableURL = recallPath
        var env = ProcessInfo.processInfo.environment
        if let keyHex = try? keyStore.readKey() {
            env["MCI_DB_KEY_HEX"] = keyHex
        }
        task.environment = env
        try? task.run()
    }

    public func openOnboarding() -> Bool {
        guard let onboardingPath = locator.onboardingPath() else {
            return false
        }
        let task = Process()
        task.executableURL = onboardingPath
        try? task.run()
        return true
    }

    public var hasOnboarding: Bool {
        locator.onboardingPath() != nil
    }

    public var dbPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/mci.sqlite")
    }

    public var devKeyPath: String {
        (try? keyStore.readKey()) != nil
            ? (keyStore as? FileKeyStore)?.path.path ?? "unknown"
            : "not set"
    }

    // MARK: - Private

    private func resolveKey() throws -> String {
        do {
            return try keyStore.readKey()
        } catch KeyStoreError.noKeyFound {
            let hex = FileKeyStore.generateHexKey()
            try keyStore.writeKey(hex)
            logger.info("supervisor: generated new dev key at \((self.keyStore as? FileKeyStore)?.path.path ?? "unknown", privacy: .public). TEMP — Phase-4 Keychain integration (ADR-0017 §6) replaces this.")
            return hex
        }
    }

    private func spawnChildren(keyHex: String) throws {
        guard let helperURL = locator.helperPath() else {
            throw SupervisorError.binaryNotFound("MCICaptureHelper")
        }
        guard let agentURL = locator.agentPath() else {
            throw SupervisorError.binaryNotFound("mci-agent")
        }

        let bridgePipe = Pipe()
        self.pipe = bridgePipe

        // Stderr log rotation
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI")
        let helperStderrLog = LogRotator(path: logDir.appendingPathComponent("helper.stderr.log"))
        let agentStderrLog = LogRotator(path: logDir.appendingPathComponent("agent.stderr.log"))
        let hStderr = try helperStderrLog.fileHandle()
        let aStderr = try agentStderrLog.fileHandle()
        self.helperStderrHandle = hStderr
        self.agentStderrHandle = aStderr

        // Spawn helper
        let helper = Process()
        helper.executableURL = helperURL
        var helperArgs = ["--capture", "--output", "/dev/stdout"]
        if let allowlistPath = locator.knownSafeAppsPath() {
            helperArgs += ["--allowlist-path", allowlistPath.path]
        }
        helper.arguments = helperArgs
        helper.standardOutput = bridgePipe
        helper.standardError = hStderr
        helper.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleChildExit(proc, label: "helper")
            }
        }

        // Spawn agent
        let agent = Process()
        agent.executableURL = agentURL
        let dbPathStr = dbPath.path
        agent.arguments = ["--drain-stdin", "--db-path", dbPathStr]
        agent.standardInput = bridgePipe
        var agentEnv = ProcessInfo.processInfo.environment
        agentEnv["MCI_DB_KEY_HEX"] = keyHex
        if runtimeConfig.crashReportOptedIn {
            agentEnv["MCI_CRASH_REPORT_OPTED_IN"] = "1"
        }
        agent.environment = agentEnv
        agent.standardError = aStderr
        agent.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleChildExit(proc, label: "agent")
            }
        }

        // Start helper FIRST so it begins writing to the pipe
        try helper.run()
        self.helperProcess = helper

        try agent.run()
        self.agentProcess = agent
    }

    private func handleChildExit(_ process: Process, label: String) {
        let code = process.terminationStatus
        let reason = process.terminationReason
        logger.warning("supervisor: \(label) exited. status=\(code), reason=\(reason.rawValue)")

        if state == .stopped { return }

        stop()
        state = .crashed(reason: "\(label) exited (\(code))")

        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryCount < Self.maxRetries else {
            logger.error("supervisor: max retries (\(Self.maxRetries)) reached. Giving up.")
            return
        }

        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), Self.maxBackoff)
        logger.info("supervisor: retry \(self.retryCount)/\(Self.maxRetries) in \(delay)s")

        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func terminateChild(_ process: Process?, label: String) {
        guard let proc = process, proc.isRunning else { return }

        // If paused (SIGSTOP'd), resume first so it can receive SIGTERM
        kill(proc.processIdentifier, SIGCONT)

        proc.terminate()  // SIGTERM
        logger.info("supervisor: sent SIGTERM to \(label) PID \(proc.processIdentifier)")

        // 2s grace then SIGKILL
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    public var isCrashReportOptedIn: Bool {
        runtimeConfig.crashReportOptedIn
    }

    public func setCrashReportOptedIn(_ value: Bool) {
        try? runtimeConfig.setCrashReportOptedIn(value)
    }

    private func startHealthPolling() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if var snapshot = HealthSnapshot.readFromLog() {
                    if let existing = self.health {
                        snapshot = snapshot.withBrainEventCount(existing.brainEventCount)
                    }
                    self.health = snapshot
                }
            }
        }
        health = HealthSnapshot.readFromLog()
        startBrainStatsPolling()
    }

    private func startBrainStatsPolling() {
        brainStatsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let brainPath = self.locator.brainCLIPath()
                let keyHex = self.currentKeyHex
                let count = await Task.detached {
                    HealthSnapshot.readBrainStats(brainPath: brainPath, keyHex: keyHex)
                }.value
                if let h = self.health {
                    self.health = h.withBrainEventCount(count)
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
}

enum SupervisorError: LocalizedError {
    case binaryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): return "\(name) binary not found"
        }
    }
}
