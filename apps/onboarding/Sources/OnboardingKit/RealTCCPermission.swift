#if canImport(AppKit)
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
public final class RealScreenRecordingPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .screenRecording
    public private(set) var status: TCCStatus

    private static let tccAttemptedKey = "MCITCCScreenRecordingAttempted"

    public init() {
        if CGPreflightScreenCaptureAccess() {
            status = .granted
        } else if UserDefaults.standard.bool(forKey: Self.tccAttemptedKey) {
            status = .denied
        } else {
            status = .notRequested
        }
    }

    public func checkCurrent() -> TCCStatus {
        if CGPreflightScreenCaptureAccess() {
            status = .granted
        } else if status == .granted {
            status = .denied
        }
        return status
    }

    public func requestOrOpenSettings() {
        if CGPreflightScreenCaptureAccess() {
            status = .granted
            return
        }
        UserDefaults.standard.set(true, forKey: Self.tccAttemptedKey)
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            status = .granted
        } else {
            status = .denied
            openPrivacySettings()
        }
    }

    public func resetAndRetry() async -> Bool {
        let bundleIDs = ["ai.hippocampus"]
        for bid in bundleIDs {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", "ScreenCapture", bid]
            try? proc.run()
            proc.waitUntilExit()
        }

        status = .notRequested

        try? await Task.sleep(for: .milliseconds(500))

        UserDefaults.standard.set(true, forKey: Self.tccAttemptedKey)
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            status = .granted
            return true
        }

        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if CGPreflightScreenCaptureAccess() {
                status = .granted
                return true
            }
        }

        status = .denied
        return false
    }

    public func openPrivacySettings() {
        openSystemSettingsPane("Privacy_ScreenCapture")
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
        if AXIsProcessTrusted() {
            status = .granted
        } else if status == .granted || status == .notRequested {
            status = status == .granted ? .denied : status
        }
        return status
    }

    public func requestOrOpenSettings() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted {
            status = .granted
        } else {
            status = .denied
            openPrivacySettings()
        }
    }

    public func resetAndRetry() async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility"]
        try? proc.run()
        proc.waitUntilExit()

        status = .notRequested

        try? await Task.sleep(for: .milliseconds(500))

        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted {
            status = .granted
            return true
        }

        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if AXIsProcessTrusted() {
                status = .granted
                return true
            }
        }

        status = .denied
        return false
    }

    public func openPrivacySettings() {
        openSystemSettingsPane("Privacy_Accessibility")
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
            return status
        }
        status = .granted
        return .granted
    }

    public func requestOrOpenSettings() {
        let probe = checkCurrent()
        if probe != .granted {
            openPrivacySettings()
        }
    }

    public func resetAndRetry() async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "AppleEvents"]
        try? proc.run()
        proc.waitUntilExit()
        status = .notRequested
        return checkCurrent() == .granted
    }

    public func openPrivacySettings() {
        openSystemSettingsPane("Privacy_Automation")
    }
}

private func openSystemSettingsPane(_ pane: String) {
    guard let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ) else { return }
    NSWorkspace.shared.open(url)
}
#endif
