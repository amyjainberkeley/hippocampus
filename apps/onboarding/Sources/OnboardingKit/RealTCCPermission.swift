#if canImport(AppKit)
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
public final class RealScreenRecordingPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .screenRecording
    public private(set) var status: TCCStatus

    public init() {
        status = CGPreflightScreenCaptureAccess() ? .granted : .notRequested
    }

    public func checkCurrent() -> TCCStatus {
        status = CGPreflightScreenCaptureAccess() ? .granted : .denied
        return status
    }

    public func requestOrOpenSettings() {
        if CGPreflightScreenCaptureAccess() {
            status = .granted
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            status = .granted
        } else {
            status = .denied
            openSystemSettingsPane("Privacy_ScreenCapture")
        }
    }
}

@MainActor
public final class RealAccessibilityPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .accessibility
    public private(set) var status: TCCStatus

    public init() {
        status = AXIsProcessTrusted() ? .granted : .notRequested
    }

    public func checkCurrent() -> TCCStatus {
        status = AXIsProcessTrusted() ? .granted : .denied
        return status
    }

    public func requestOrOpenSettings() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted {
            status = .granted
        } else {
            status = .denied
            openSystemSettingsPane("Privacy_Accessibility")
        }
    }
}

@MainActor
public final class RealAutomationPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .automation
    public private(set) var status: TCCStatus = .notRequested

    public init() {}

    public func checkCurrent() -> TCCStatus {
        let script = NSAppleScript(source:
            "tell application \"System Events\" to return name of first process"
        )
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let error = errorInfo,
           let num = error[NSAppleScript.errorNumber] as? Int {
            if num == -1743 {
                status = .denied
                return .denied
            }
            // Other script errors — can't determine TCC state.
            return status
        }
        status = .granted
        return .granted
    }

    public func requestOrOpenSettings() {
        let probe = checkCurrent()
        if probe != .granted {
            openSystemSettingsPane("Privacy_Automation")
        }
    }
}

private func openSystemSettingsPane(_ pane: String) {
    guard let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ) else { return }
    NSWorkspace.shared.open(url)
}
#endif
