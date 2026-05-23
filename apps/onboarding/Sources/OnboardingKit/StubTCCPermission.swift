import Foundation

@MainActor
public final class StubTCCPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind
    public private(set) var status: TCCStatus
    public private(set) var openSettingsCallCount = 0
    public private(set) var resetCallCount = 0
    public var resetShouldSucceed = true

    public init(kind: TCCPermissionKind, status: TCCStatus = .notRequested) {
        self.kind = kind
        self.status = status
    }

    public func checkCurrent() -> TCCStatus {
        status
    }

    public func requestOrOpenSettings() {
        openSettingsCallCount += 1
    }

    public func resetAndRetry() async -> Bool {
        resetCallCount += 1
        if resetShouldSucceed {
            status = .granted
            return true
        }
        status = .denied
        return false
    }

    public func openPrivacySettings() {
        openSettingsCallCount += 1
    }

    public func simulateGrant() {
        status = .granted
    }

    public func simulateDeny() {
        status = .denied
    }
}
