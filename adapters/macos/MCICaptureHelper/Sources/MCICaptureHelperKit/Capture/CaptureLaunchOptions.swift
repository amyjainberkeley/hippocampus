// SPDX-License-Identifier: TBD-private
//
// CaptureLaunchOptions — the single source of truth for the
// "is live SCStream capture allowed to start?" decision.
//
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ ADR-0013 Amendment 1 §4 — CAPTURE STAYS DEFAULT-OFF              │
// │                                                                  │
// │ Live `SCStream` capture MUST NOT start in any default or shipped │
// │ process without the app supervisor's explicit argv authority.    │
// │                                                                  │
// │ This type makes that gate a single, unit-tested predicate:       │
// │ `captureEnabled` is `false` unless the operator explicitly       │
// │ passes the non-default `--capture` flag. The default             │
// │ (no flag) path never constructs an `SCStream`.                   │
// └──────────────────────────────────────────────────────────────────┘

import Foundation

/// Parsed launch options that gate the live-capture path.
public struct CaptureLaunchOptions: Sendable, Equatable {
    /// The explicit, non-default supervisor flag. Named verbosely so it
    /// can never be confused with an innocuous flag and so a grep for
    /// the live-capture entry point lands here.
    public static let captureFlag = "--capture"

    /// `true` only if `--capture` was explicitly passed. The default
    /// build path leaves this `false` (Amendment 1 §4). The persisted app
    /// preference is translated to this argv token transactionally.
    public let captureEnabled: Bool

    public init(captureEnabled: Bool) {
        self.captureEnabled = captureEnabled
    }

    /// Parse argv. The ONLY way `captureEnabled` becomes `true` is an
    /// explicit `--capture` token. Absence ⇒ default-OFF.
    public static func parse(
        _ argv: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CaptureLaunchOptions {
        _ = environment
        return CaptureLaunchOptions(captureEnabled: argv.contains(captureFlag))
    }
}

/// Narrow capability for the live overlap verifier to exercise OCR while the
/// production kill switch remains engaged. This is diagnostic authorization,
/// not a persisted setting: every independent signal must be present on the
/// helper process that owns the isolated test brain.
#if DEBUG
public enum LiveOCRQualification {
    public static let flag = "--live-overlap-qualification"

    public static func isRequested(_ argv: [String]) -> Bool {
        argv.contains(flag)
    }

    public static func isAuthorized(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        isRequested(arguments)
            && arguments.contains(CaptureLaunchOptions.captureFlag)
            && arguments.contains("--probe-debug")
            && environment["MCI_DEVELOPMENT_FILE_KEY"] == "1"
            && environment["MCI_OCR_TRACE"] == "1"
    }
}
#endif
