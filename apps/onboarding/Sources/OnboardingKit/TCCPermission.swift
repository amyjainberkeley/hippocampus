import Foundation

public enum TCCStatus: String, Sendable, Equatable {
    case notRequested
    case granted
    case denied
}

public enum TCCPermissionKind: String, Sendable, Equatable, CaseIterable {
    case screenRecording
    case accessibility
    case automation
}

@MainActor
public protocol TCCPermission: AnyObject, Sendable {
    var kind: TCCPermissionKind { get }
    var status: TCCStatus { get }
    func checkCurrent() -> TCCStatus
    func requestOrOpenSettings()
    func resetAndRetry() async -> Bool
    func openPrivacySettings()
}
