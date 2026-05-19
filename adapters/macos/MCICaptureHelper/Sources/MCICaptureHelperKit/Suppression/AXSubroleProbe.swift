// SPDX-License-Identifier: TBD-private
//
// AXSubroleProbe — concrete `AXSecureSubroleProbe` backed by the
// macOS Accessibility API.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This is the ADR-0013 cascade
// §4 probe. It queries the system-wide focused UI element and reads
// its `kAXSubroleAttribute`; if it matches `kAXSecureTextFieldSubrole`
// the cascade suppresses the event.
//
// The probe correctly distinguishes three result classes:
//   - `Some(true)`  — focused element is a secure text field
//                     (`NSSecureTextField` or its SwiftUI / Catalyst
//                     bridges)
//   - `Some(false)` — focused element exists and has a non-secure
//                     subrole (e.g. `AXTextField`, `AXButton`)
//   - `nil`         — AX could not answer with reasonable confidence
//                     (permission denied, no focused element on a
//                     queryable app, Electron AX intermittency, API
//                     disabled). The cascade treats `nil` as
//                     fail-safe per ADR-0013 §3 + §7.
//
// AX permission is a hard prerequisite. The agent shell requests it
// during onboarding (DESIGN.md §3, R1); without it this probe
// returns `nil` and the cascade redacts the event.
//
// ## STEP-2-FINDING-001 instrumentation (`--probe-debug`)
//
// On Step-2 (`docs/audit/2026-05-19-step2-sec-7-corpus.md`) this probe
// returned `false` / `nil` on every System Settings password sheet +
// 1Password master-password + sudo focus despite a confirmed
// Accessibility TCC grant — five fault surfaces filed, top suspect
// the macOS 26 Tahoe SwiftUI/Catalyst AX bridge no longer exposing
// `kAXSecureTextFieldSubrole` on system password fields.
//
// To diagnose without bumping the wire schema or widening any
// allow-path, the probe accepts an optional `DebugSink` closure. When
// wired (only by `mci-capture-helper --probe-debug`, a dev-only flag),
// every call emits one structured observation — role, subrole,
// identifier, title, the raw AX result, and the classification —
// to the closure (helper writes it to stderr).
//
// **Steady-state cost when no sink is wired is zero**: the production
// path is byte-for-byte the prior implementation. The extra AX role /
// identifier / title lookups are gated behind `if debugLog != nil`.

import ApplicationServices
import Foundation

/// Structured snapshot of one `focusedHasSecureSubrole()` call, used by
/// the `--probe-debug` diagnostic sink. Plain-data + `Sendable` so it
/// can cross task boundaries; the helper just stringifies it onto
/// stderr.
///
/// Never serialized to the wire. Never reaches the Rust core. Never
/// touches the encoded frame path. Diagnostic-only.
public struct AXProbeObservation: Sendable, Equatable {
    /// Raw result of `AXUIElementCopyAttributeValue(systemWide,
    /// kAXFocusedUIElement, …)`.
    public let focusResult: AXError
    /// Focused element's `kAXRoleAttribute` (`AXTextField`, `AXButton`,
    /// …). `nil` when AX returned no focused element or the role
    /// attribute is unreadable.
    public let role: String?
    /// Focused element's `kAXSubroleAttribute`. `kAXSecureTextFieldSubrole`
    /// ("AXSecureTextField") iff the field is a secure-input widget.
    /// `nil` if absent or unreadable.
    public let subrole: String?
    /// Focused element's `kAXIdentifierAttribute` — the test/automation
    /// identifier some Apple system pages set. Surfaces suspect-#1 hints
    /// (e.g. SwiftUI / Catalyst bridges that emit identifiers but no
    /// secure subrole).
    public let identifier: String?
    /// Focused element's `kAXTitleAttribute` — the field's label.
    public let title: String?
    /// The cascade-facing classification: `true` (secure), `false`
    /// (not secure / no focus), `nil` (cannot classify, fail-safe).
    public let classification: Bool?

    public init(
        focusResult: AXError,
        role: String?,
        subrole: String?,
        identifier: String?,
        title: String?,
        classification: Bool?
    ) {
        self.focusResult = focusResult
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.classification = classification
    }
}

/// Concrete `AXSecureSubroleProbe` backed by the macOS Accessibility API.
///
/// `Sendable` because it holds no mutable state beyond an optional
/// `@Sendable` debug closure — every call creates a fresh
/// `AXUIElementCreateSystemWide()` reference. AX is not designed for
/// cached use across long-lived processes; the system-wide handle is
/// cheap to recreate.
public struct AXSubroleProbe: AXSecureSubroleProbe {
    /// Optional dev-only sink for per-call diagnostic observations.
    /// Wired by `mci-capture-helper --probe-debug` only. Production
    /// (no flag) leaves this `nil` — the steady-state path then makes
    /// only the two AX calls the prior implementation made.
    public typealias DebugSink = @Sendable (AXProbeObservation) -> Void

    private let debugLog: DebugSink?

    public init(debugLog: DebugSink? = nil) {
        self.debugLog = debugLog
    }

    public func focusedHasSecureSubrole() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        // Resolve the focused AXUIElement once (defensively type-checked
        // for the same reason as the prior impl: hostile shims could
        // return a non-AXUIElement CFType).
        let focusedElement: AXUIElement?
        if focusResult == .success, let ref = focusedRef,
            CFGetTypeID(ref) == AXUIElementGetTypeID()
        {
            // SAFETY: CFTypeRef→AXUIElement bridge via `as!` is the
            // documented Swift pattern for AX results once
            // `CFGetTypeID()` matches.
            // swiftlint:disable:next force_cast
            focusedElement = (ref as! AXUIElement)
        } else {
            focusedElement = nil
        }

        // Read the subrole iff we have a focused element; otherwise
        // pass through synthetic .success / nil so the pure classifier
        // sees the same shape.
        let subroleValue: String?
        let subroleResult: AXError
        if let element = focusedElement {
            (subroleValue, subroleResult) = Self.readSubroleAttribute(of: element)
        } else {
            subroleValue = nil
            subroleResult = .success
        }

        let classification = Self.classify(
            focusResult: focusResult,
            focusedRefMatched: focusedElement != nil,
            subroleResult: subroleResult,
            subroleValue: subroleValue
        )

        // STEADY-STATE FAST PATH. When no sink is wired (default
        // production build), skip the role / identifier / title reads
        // entirely. Zero added AX traffic over the prior implementation.
        if let sink = debugLog {
            let role = focusedElement.flatMap {
                Self.readStringAttribute($0, kAXRoleAttribute as CFString)
            }
            let identifier = focusedElement.flatMap {
                Self.readStringAttribute($0, kAXIdentifierAttribute as CFString)
            }
            let title = focusedElement.flatMap {
                Self.readStringAttribute($0, kAXTitleAttribute as CFString)
            }
            sink(
                AXProbeObservation(
                    focusResult: focusResult,
                    role: role,
                    subrole: subroleValue,
                    identifier: identifier,
                    title: title,
                    classification: classification
                ))
        }

        return classification
    }

    /// Pure classifier — the AX-result → cascade-input mapping that
    /// STEP-2-FINDING-001 needs to unit-test in isolation. Makes no AX
    /// calls; tests inject synthetic `AXError` + subrole strings and
    /// assert the cascade-input shape. Mirrors the original switch
    /// arms in `focusedHasSecureSubrole()` byte-for-byte.
    static func classify(
        focusResult: AXError,
        focusedRefMatched: Bool,
        subroleResult: AXError,
        subroleValue: String?
    ) -> Bool? {
        switch focusResult {
        case .success:
            // No focused element returned (or hostile non-AXUIElement
            // CFType): cannot classify, fail-safe.
            guard focusedRefMatched else { return nil }
            switch subroleResult {
            case .success:
                guard let s = subroleValue else { return nil }
                return s == (kAXSecureTextFieldSubrole as String)
            case .noValue, .attributeUnsupported:
                // Element has no subrole attribute (lots of elements
                // don't). That's a positive "not secure" answer.
                return false
            default:
                // Any failure path on the subrole read — treat as
                // cannot-classify.
                return nil
            }

        case .noValue:
            // No focused element on the system — nothing to classify.
            // Treated as non-secure; the rest of the cascade (denylist,
            // secure-event-input, blacked region) still has a chance to
            // fire. Fail-safe §7 still catches the unknown-app case.
            return false

        case .apiDisabled, .notImplemented:
            // Accessibility permission has not been granted, or this
            // app lacks the entitlement. Cascade redacts.
            return nil

        case .cannotComplete, .attributeUnsupported, .invalidUIElement,
            .invalidUIElementObserver, .illegalArgument,
            .notificationUnsupported, .notificationAlreadyRegistered,
            .notificationNotRegistered, .actionUnsupported,
            .parameterizedAttributeUnsupported, .failure, .notEnoughPrecision:
            // Any other AX failure on the focus read — treat as
            // cannot-classify. Cascade redacts.
            return nil

        @unknown default:
            return nil
        }
    }

    /// Read the focused element's subrole attribute, returning the raw
    /// string value (if any) alongside the raw `AXError`. The pure
    /// `classify(...)` consumer turns that pair into the cascade input.
    private static func readSubroleAttribute(
        of element: AXUIElement
    ) -> (String?, AXError) {
        var subroleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleRef
        )
        return (subroleRef as? String, result)
    }

    /// Read any string AX attribute on `element`. Used only by the
    /// `--probe-debug` slow path to populate the observation; the fast
    /// path never calls this.
    private static func readStringAttribute(
        _ element: AXUIElement, _ attribute: CFString
    ) -> String? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard r == .success else { return nil }
        return ref as? String
    }
}
