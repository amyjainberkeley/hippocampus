// SPDX-License-Identifier: TBD-private
//
// CaptureLaunchOptions — the single source of truth for the
// "is live SCStream capture allowed to start?" decision.
//
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ ADR-0013 Amendment 1 §4 — CAPTURE STAYS DEFAULT-OFF / DEV-ONLY   │
// │                                                                  │
// │ Live `SCStream` capture MUST NOT start in any default or shipped │
// │ build until the §7 secure-surface corpus is green on a real      │
// │ machine and its audit artifact is committed. Flipping this       │
// │ default ON is a CSO-protected change — NOT an autonomous one.    │
// │                                                                  │
// │ This type makes that gate a single, unit-tested predicate:       │
// │ `captureEnabled` is `false` unless the operator explicitly       │
// │ passes the non-default `--capture` dev flag. The default         │
// │ (no flag) path never constructs an `SCStream`.                   │
// └──────────────────────────────────────────────────────────────────┘

import Foundation

/// Parsed launch options that gate the live-capture path.
public struct CaptureLaunchOptions: Sendable, Equatable {
    /// The explicit, non-default dev opt-in flag. Named verbosely so it
    /// can never be confused with an innocuous flag and so a grep for
    /// the live-capture entry point lands here.
    public static let captureFlag = "--capture"

    /// `true` only if `--capture` was explicitly passed. The default
    /// build path leaves this `false` (Amendment 1 §4). Until the §7
    /// corpus is green on a real machine, even `true` only reaches a
    /// path with NO IOSurface retain and NO encoder (PR-1) — it still
    /// cannot store a frame; the flag exists so the live wiring can be
    /// driven by a human in a dev session, never by default.
    public let captureEnabled: Bool

    public init(captureEnabled: Bool) {
        self.captureEnabled = captureEnabled
    }

    /// Parse argv. The ONLY way `captureEnabled` becomes `true` is an
    /// explicit `--capture` token. Absence ⇒ default-OFF.
    public static func parse(_ argv: [String]) -> CaptureLaunchOptions {
        CaptureLaunchOptions(captureEnabled: argv.contains(captureFlag))
    }
}
