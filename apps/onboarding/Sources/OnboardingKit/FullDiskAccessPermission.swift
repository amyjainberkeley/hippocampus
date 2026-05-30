// SPDX-License-Identifier: TBD-private
//
// FullDiskAccessPermission — V2-P10 onboarding-side TCC gate for the
// per-app deep-hook opt-in.
//
// ADR-0032 §3(b) binding: reading `~/Library/Messages/chat.db` and the
// Mail Envelope Index requires macOS Full Disk Access. The onboarding
// UI MUST surface this as a separate "Grant Full Disk Access" card on
// any deep-hook toggle that flips ON; the consent IS the OS dialog.
//
// Per ADR-0017 §1.3 (re-asserting ADR-0015 §4.4): no `tccutil`, no
// private API, no click-through bypass. The "Grant ..." button opens
// `System Settings → Privacy & Security → Full Disk Access` via the
// `x-apple.systempreferences:` URL scheme; the OS dialog firing is
// the consent.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum FullDiskAccessStatus: Sendable, Equatable {
    /// User has not yet been asked / has not opened Settings.
    case notRequested
    /// User opened Settings; cannot programmatically confirm grant
    /// without attempting a read (which would require an FDA-gated
    /// resource — deferred to the actual plugin code at agent start).
    case requested
    /// Set only after the plugin process has performed an FDA-gated
    /// read successfully. UI cannot verify this directly.
    case granted
    /// Set when the user dismisses without opening Settings.
    case declined
}

public protocol FullDiskAccessPermission: Sendable {
    func status() async -> FullDiskAccessStatus
    /// Open System Settings → Privacy & Security → Full Disk Access.
    /// Returns true if the deep-link was launched, false on failure.
    @discardableResult
    func requestGrant() async -> Bool
}

/// Real impl that deep-links into Settings via the
/// `x-apple.systempreferences:` URL scheme. Status starts at
/// `.notRequested` and advances to `.requested` after the deep-link
/// fires. Confirmation that the grant landed is owed to the agent-
/// side plugin process (V2-P7b).
public actor RealFullDiskAccessPermission: FullDiskAccessPermission {
    private var _status: FullDiskAccessStatus = .notRequested

    public init() {}

    public func status() async -> FullDiskAccessStatus { _status }

    @discardableResult
    public func requestGrant() async -> Bool {
        _status = .requested
        #if canImport(AppKit)
        // Settings pane URL — Privacy & Security → Full Disk Access.
        // Pre-macOS 13 used `com.apple.preference.security`; the
        // anchor `Privacy_AllFiles` lands the user directly on FDA.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        return false
        #endif
    }
}

public actor StubFullDiskAccessPermission: FullDiskAccessPermission {
    private var _status: FullDiskAccessStatus

    public init(initial: FullDiskAccessStatus = .notRequested) {
        self._status = initial
    }

    public func status() async -> FullDiskAccessStatus { _status }

    @discardableResult
    public func requestGrant() async -> Bool {
        _status = .requested
        return true
    }

    /// Test-only — push status forward to simulate grant landing.
    public func setStatus(_ next: FullDiskAccessStatus) {
        _status = next
    }
}
