import Foundation

public protocol KeyGenerator: Sendable {
    func keyExists() async -> Bool
    func generateKey() async throws
}

public actor StubKeyGenerator: KeyGenerator {
    private var exists: Bool

    public init(exists: Bool = false) {
        self.exists = exists
    }

    public func keyExists() -> Bool { exists }

    public func generateKey() throws {
        exists = true
    }

    public func simulateFailure() {
        exists = false
    }
}
