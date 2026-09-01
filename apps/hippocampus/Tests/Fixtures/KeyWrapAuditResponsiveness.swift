import Foundation
import Security

private final class DelayedAuditClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var readWasOnMainThread = false

    func readGenericPassword(query: KeychainItemQuery) -> KeychainReadResult {
        _ = query
        lock.withLock { readWasOnMainThread = Thread.isMainThread }
        Thread.sleep(forTimeInterval: 0.2)
        return .success(Data(String(repeating: "ab", count: 32).utf8))
    }

    func addGenericPassword(
        query: KeychainItemQuery,
        data: Data,
        trustedApplicationPaths: [String]
    ) -> OSStatus {
        _ = (query, data, trustedApplicationPaths)
        return errSecUnimplemented
    }

    var observedMainThreadRead: Bool {
        lock.withLock { readWasOnMainThread }
    }
}

private enum AuditFixtureError: LocalizedError {
    case failed

    var errorDescription: String? { "fixture audit failed" }
}

@main
struct KeyWrapAuditResponsiveness {
    @MainActor
    static func main() async {
        let client = DelayedAuditClient()
        let store = KeychainKeyStore(client: client, trustedApplicationPaths: { [] })
        let model = KeyWrapAuditViewModel(store: store)
        let start = ContinuousClock.now
        let refresh = Task { @MainActor in await model.refresh() }

        try? await Task.sleep(for: .milliseconds(25))
        precondition(model.state == .loading, "audit must expose loading state")
        precondition(
            start.duration(to: .now) < .milliseconds(100),
            "MainActor heartbeat was blocked by Keychain audit"
        )
        await refresh.value
        guard case .loaded(let report) = model.state else {
            preconditionFailure("audit did not publish loaded state: \(model.state)")
        }
        precondition(report.keyReadable, "valid key should be reported readable")
        precondition(
            report.accessControlVerification == .unverified,
            "a value read must not fabricate ACL verification"
        )
        precondition(!client.observedMainThreadRead, "Security.framework read ran on MainActor")

        let failing = KeyWrapAuditViewModel(audit: { throw AuditFixtureError.failed })
        await failing.refresh()
        guard case .failed(let message) = failing.state else {
            preconditionFailure("audit did not publish failure state: \(failing.state)")
        }
        precondition(message.contains("fixture audit failed"), "failure detail was lost")
    }
}
