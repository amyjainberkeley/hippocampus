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
    /// The quick in-process check. It may turn a permission on but never
    /// off: on some macOS versions a process keeps the "no" it read before
    /// the person turned the permission on, and a stale answer must not
    /// undo a grant seen another way.
    func checkCurrent() -> TCCStatus
    /// The check that may also turn a permission off. With `outOfProcess`,
    /// Screen Recording also asks a fresh process, whose answer can only
    /// turn the permission on.
    func checkCurrentAsync(outOfProcess: Bool) async -> TCCStatus
    func requestOrOpenSettings()
    /// "Allow": macOS's own prompt and nothing else. The prompt's Open
    /// System Settings button leads on from there; the row's own "Open
    /// System Settings" is the way when no prompt shows.
    func requestPrompt()
    func resetAndRetry() async -> Bool
    /// Clear this permission for Hippocampus and ask macOS again, then
    /// return at once. The caller's refresh does the waiting.
    func askAgain() async
    func openPrivacySettings()
}

extension TCCPermission {
    public func checkCurrentAsync(outOfProcess: Bool) async -> TCCStatus {
        checkCurrent()
    }

    public func checkCurrentAsync() async -> TCCStatus {
        await checkCurrentAsync(outOfProcess: false)
    }

    public func requestPrompt() {
        requestOrOpenSettings()
    }

    public func askAgain() async {
        requestPrompt()
    }
}
