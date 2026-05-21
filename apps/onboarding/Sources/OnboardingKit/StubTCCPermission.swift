import Foundation

@MainActor
public final class StubTCCPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind
    public private(set) var status: TCCStatus
    public private(set) var openSettingsCallCount = 0

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

    // Test helper: simulate OS grant
    public func simulateGrant() {
        status = .granted
    }

    public func simulateDeny() {
        status = .denied
    }
}
