import Foundation

private final class DelayedKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadRead = false

    func readKey() throws -> String {
        lock.withLock { mainThreadRead = Thread.isMainThread }
        Thread.sleep(forTimeInterval: 0.2)
        return String(repeating: "ab", count: 32)
    }

    func writeKey(_ hex: String) throws {
        _ = hex
    }

    var readOccurredOnMainThread: Bool {
        lock.withLock { mainThreadRead }
    }
}

@main
struct KeyStoreResponsiveness {
    @MainActor
    static func main() async throws {
        let store = DelayedKeyStore()
        let start = ContinuousClock.now
        let read = Task {
            try await KeyStoreAccess.readValidatedKey(from: store)
        }

        try await Task.sleep(for: .milliseconds(25))
        let heartbeatElapsed = start.duration(to: .now)
        precondition(
            heartbeatElapsed < .milliseconds(100),
            "MainActor heartbeat was blocked by key access: \(heartbeatElapsed)"
        )
        _ = try await read.value
        precondition(!store.readOccurredOnMainThread, "Keychain read ran on MainActor")
    }
}
