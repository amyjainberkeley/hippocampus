import Foundation
import OnboardingKit

/// Delegates database-key preparation to the bundled ACL-trusted agent.
struct LocalKeyGenerator: KeyGenerator, Sendable {
    func keyExists() async -> Bool {
        // Onboarding is deliberately absent from the Keychain item's ACL, so it
        // cannot probe custody directly. `generateKey` is an idempotent ensure.
        false
    }

    func generateKey() async throws {
        guard let executable = Bundle.main.executableURL else {
            throw KeyGenerationError.invalidBundle
        }
        let agentURL = executable.deletingLastPathComponent().appendingPathComponent("mci-agent")
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw KeyGenerationError.missingAgent
        }

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/mci.sqlite")
        var environment = ProcessInfo.processInfo.environment
        for name in [
            "MCI_DB_KEY_HEX",
            "MCI_DB_KEY_FILE",
            "MCI_DEVELOPMENT_FILE_KEY",
            "HIPPOCAMPUS_ENABLE_V2P1",
        ] {
            environment.removeValue(forKey: name)
        }
        environment["MCI_DB_PATH"] = databaseURL.path
        environment["MCI_DB_KEYCHAIN_SERVICE"] = "ai.hippocampus.brain"
        environment["MCI_DB_KEYCHAIN_ACCOUNT"] = "database-key-v1"
        environment["MCI_DB_KEYCHAIN_STORAGE_MODEL"] = "file-keychain-acl-v1"

        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["ensure-key", "--db-path", databaseURL.path]
        process.environment = environment
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KeyGenerationError.agentFailed(process.terminationStatus)
        }
    }
}

enum KeyGenerationError: LocalizedError {
    case invalidBundle
    case missingAgent
    case agentFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBundle: "Hippocampus cannot verify the onboarding bundle."
        case .missingAgent: "Hippocampus cannot find its database-key service."
        case .agentFailed(let status): "Database-key preparation failed (\(status))."
        }
    }
}
