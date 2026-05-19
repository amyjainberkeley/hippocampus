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

import ApplicationServices
import Foundation

/// Concrete `AXSecureSubroleProbe` backed by the macOS Accessibility API.
///
/// `Sendable` because it holds no mutable state — every call creates a
/// fresh `AXUIElementCreateSystemWide()` reference. AX is not designed
/// for cached use across long-lived processes; the system-wide handle
/// is cheap to recreate.
public struct AXSubroleProbe: AXSecureSubroleProbe {
    public init() {}

    public func focusedHasSecureSubrole() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        switch focusResult {
        case .success:
            guard let focused = focusedRef else { return nil }
            // The returned `CFTypeRef` is guaranteed by AX to be an
            // `AXUIElement` when the attribute is `kAXFocusedUIElement`,
            // but we still check defensively because hostile
            // accessibility shims (or future-OS behavior changes) could
            // return something else and we'd rather redact than misclassify.
            guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                return nil
            }
            // SAFETY: CFTypeRef→AXUIElement bridge via `as!` is the
            // documented Swift pattern for AX results once
            // `CFGetTypeID()` matches. Sendable + immutable.
            // swiftlint:disable:next force_cast
            let focusedElement = focused as! AXUIElement
            return subroleIsSecure(focusedElement)

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
            // Any other AX failure — treat as cannot-classify. Cascade
            // redacts. The exhaustive `case` keeps the switch covering
            // all known `AXError` values; an OS update that adds a new
            // variant falls into the `@unknown default` below.
            return nil

        @unknown default:
            return nil
        }
    }

    /// Read the focused element's subrole. Returns:
    /// - `Some(true)`  if `kAXSubroleAttribute == kAXSecureTextFieldSubrole`
    /// - `Some(false)` if the subrole is present and is something else
    /// - `nil`         if the subrole could not be read (cascade fail-safe)
    private func subroleIsSecure(_ element: AXUIElement) -> Bool? {
        var subroleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleRef
        )

        switch result {
        case .success:
            guard let subrole = subroleRef as? String else { return nil }
            return subrole == (kAXSecureTextFieldSubrole as String)

        case .noValue, .attributeUnsupported:
            // Element has no subrole attribute (lots of elements don't).
            // That's a positive "not secure" answer.
            return false

        default:
            // Any failure path — treat as cannot-classify.
            return nil
        }
    }
}
