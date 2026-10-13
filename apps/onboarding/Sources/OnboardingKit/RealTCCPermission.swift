#if canImport(AppKit)
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Runs `tccutil` for one Hippocampus service. Tests pass a recorder: a real
/// reset changes System Settings for the whole Mac account.
public protocol TCCResetting: Sendable {
    func reset(_ arguments: [String])
}

public struct TCCUtilResetter: TCCResetting {
    public init() {}

    public func reset(_ arguments: [String]) {
        let proc = ChildProcessEnvironment.makeProcess()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = arguments
        try? proc.run()
        proc.waitUntilExit()
    }
}

/// Whether onboarding has asked for Screen Recording before. macOS answers
/// "no" the same way before and after the person said no, so this is what
/// tells "not asked yet" from "turned down".
public protocol ScreenRecordingAttempts: AnyObject, Sendable {
    var attempted: Bool { get set }
}

/// The record in this process's defaults, `MCITCCScreenRecordingAttempted`.
public final class DefaultsScreenRecordingAttempts: ScreenRecordingAttempts, @unchecked Sendable {
    public static let key = "MCITCCScreenRecordingAttempted"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var attempted: Bool {
        get { defaults.bool(forKey: Self.key) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// A record that lives only in memory, for tests: a defaults suite would
/// leave a file in the person's `~/Library/Preferences`.
public final class InMemoryScreenRecordingAttempts: ScreenRecordingAttempts, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(attempted: Bool = false) {
        value = attempted
    }

    public var attempted: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Every reset names Hippocampus. Without a bundle id, tccutil resets the
/// service for every app on the Mac.
enum TCCResetArguments {
    static let screenCapture = ["reset", "ScreenCapture", "ai.hippocampus"]
    static let accessibility = ["reset", "Accessibility", "ai.hippocampus"]
    static let appleEvents = ["reset", "AppleEvents", "ai.hippocampus"]
}

@MainActor
public final class RealScreenRecordingPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .screenRecording
    public private(set) var status: TCCStatus
    /// A grant a fresh process confirmed. It stands for the rest of this
    /// session: the in-process answer can only be stale in the "no"
    /// direction, so nothing this process reads may undo it.
    public private(set) var grantLatched = false

    static let tccAttemptedKey = DefaultsScreenRecordingAttempts.key

    private let preflight: @MainActor () -> Bool
    private let probe: any ScreenRecordingProbe
    private let requester: any ScreenRecordingRequester
    private let resetter: any TCCResetting
    private let attempts: any ScreenRecordingAttempts
    private let openPane: @MainActor (String) -> Void
    private var requestSent = false

    public convenience init() {
        let executable = OnboardingExecutable.current()
        self.init(
            preflight: { CGPreflightScreenCaptureAccess() },
            probe: ChildScreenRecordingProbe(executable: executable),
            requester: ChildScreenRecordingRequester(executable: executable),
            resetter: TCCUtilResetter(),
            attempts: DefaultsScreenRecordingAttempts(),
            openPane: openSystemSettingsPane
        )
    }

    public init(
        preflight: @escaping @MainActor () -> Bool,
        probe: any ScreenRecordingProbe,
        requester: any ScreenRecordingRequester,
        resetter: any TCCResetting,
        attempts: any ScreenRecordingAttempts,
        openPane: @escaping @MainActor (String) -> Void
    ) {
        self.preflight = preflight
        self.probe = probe
        self.requester = requester
        self.resetter = resetter
        self.attempts = attempts
        self.openPane = openPane
        if preflight() {
            status = .granted
        } else if attempts.attempted {
            status = .denied
        } else {
            status = .notRequested
        }
    }

    public func checkCurrent() -> TCCStatus {
        if grantLatched || preflight() {
            status = .granted
        }
        return status
    }

    public func checkCurrentAsync(outOfProcess: Bool) async -> TCCStatus {
        if grantLatched || preflight() {
            status = .granted
            return status
        }
        if outOfProcess, await probe.isGranted() == true {
            grantLatched = true
            status = .granted
            return status
        }
        // This process says no and no fresh process said yes. A grant this
        // process saw earlier has been turned off.
        if status == .granted {
            status = .denied
        }
        return status
    }

    public func requestOrOpenSettings() {
        if preflight() {
            status = .granted
            return
        }
        // Never call CGRequestScreenCaptureAccess() in this process.
        //
        // When the person allows Screen Recording, macOS may end the
        // process that asked, and the onboarding window would vanish from
        // under them ("I clicked Grant and the app died", CEO-reported
        // 2026-05-24). A separate copy of this binary asks instead
        // (`--tcc-request`), once per session, so macOS lists Hippocampus
        // and shows its prompt from a process that then exits. The pane
        // opens as well, so something is on screen even if no prompt
        // appears. The rows' refresh sees the grant without a restart.
        attempts.attempted = true
        if !requestSent {
            requestSent = true
            requester.request()
        }
        openPrivacySettings()
    }

    /// Reset, forget the earlier attempt, and have a fresh process ask
    /// again. Returns at once: the row's refresh does the waiting.
    public func askAgain() async {
        resetter.reset(TCCResetArguments.screenCapture)
        attempts.attempted = false
        grantLatched = false
        status = .notRequested
        requestSent = true
        requester.request()
        openPrivacySettings()
    }

    public func resetAndRetry() async -> Bool {
        resetter.reset(TCCResetArguments.screenCapture)
        grantLatched = false
        status = .notRequested

        try? await Task.sleep(for: .milliseconds(500))

        // Same no-kill discipline as `requestOrOpenSettings`: deep-link
        // to Settings and poll.
        attempts.attempted = true
        openPrivacySettings()

        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if preflight() {
                status = .granted
                return true
            }
        }

        status = .denied
        return false
    }

    public func openPrivacySettings() {
        openPane("Privacy_ScreenCapture")
    }
}

@MainActor
public final class RealAccessibilityPermission: TCCPermission, @unchecked Sendable {
    public let kind: TCCPermissionKind = .accessibility
    public private(set) var status: TCCStatus

    private let isTrusted: @MainActor () -> Bool
    private let prompt: @MainActor () -> Bool
    private let resetter: any TCCResetting
    private let openPane: @MainActor (String) -> Void

    public convenience init() {
        self.init(
            isTrusted: { AXIsProcessTrusted() },
            prompt: {
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                return AXIsProcessTrustedWithOptions(opts)
            },
            resetter: TCCUtilResetter(),
            openPane: openSystemSettingsPane
        )
    }

    public init(
        isTrusted: @escaping @MainActor () -> Bool,
        prompt: @escaping @MainActor () -> Bool,
        resetter: any TCCResetting,
        openPane: @escaping @MainActor (String) -> Void
    ) {
        self.isTrusted = isTrusted
        self.prompt = prompt
        self.resetter = resetter
        self.openPane = openPane
        status = isTrusted() ? .granted : .notRequested
    }

    public func checkCurrent() -> TCCStatus {
        if isTrusted() {
            status = .granted
        }
        return status
    }

    public func checkCurrentAsync(outOfProcess: Bool) async -> TCCStatus {
        if isTrusted() {
            status = .granted
        } else if status == .granted {
            status = .denied
        }
        return status
    }

    public func requestOrOpenSettings() {
        if prompt() {
            status = .granted
        } else {
            status = .denied
            openPrivacySettings()
        }
    }

    /// Reset, then the same request as the first click: macOS's prompt,
    /// and the pane when it is not on.
    public func askAgain() async {
        resetter.reset(TCCResetArguments.accessibility)
        status = .notRequested
        requestOrOpenSettings()
    }

    public func resetAndRetry() async -> Bool {
        resetter.reset(TCCResetArguments.accessibility)

        status = .notRequested

        try? await Task.sleep(for: .milliseconds(500))

        if prompt() {
            status = .granted
            return true
        }

        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if isTrusted() {
                status = .granted
                return true
            }
        }

        status = .denied
        return false
    }

    public func openPrivacySettings() {
        openPane("Privacy_Accessibility")
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
        // Scoped to Hippocampus, never every app's Automation grants.
        TCCUtilResetter().reset(TCCResetArguments.appleEvents)
        status = .notRequested
        return checkCurrent() == .granted
    }

    public func openPrivacySettings() {
        openSystemSettingsPane("Privacy_Automation")
    }
}

@MainActor
func openSystemSettingsPane(_ pane: String) {
    guard let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ) else { return }
    NSWorkspace.shared.open(url)
}
#endif
