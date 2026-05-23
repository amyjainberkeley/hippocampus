import Foundation
import OnboardingKit
import Security

struct LocalKeyGenerator: KeyGenerator, Sendable {
    private let keyPath: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCI")
        self.keyPath = dir.appendingPathComponent("dev.key")
    }

    func keyExists() async -> Bool {
        FileManager.default.fileExists(atPath: keyPath.path)
    }

    func generateKey() async throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw KeyGenerationError.randomFailed
        }

        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        let parent = keyPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let data = Data(hex.utf8)
        try data.write(to: keyPath, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyPath.path
        )
    }
}

enum KeyGenerationError: LocalizedError {
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .randomFailed: "Failed to generate secure random bytes"
        }
    }
}
