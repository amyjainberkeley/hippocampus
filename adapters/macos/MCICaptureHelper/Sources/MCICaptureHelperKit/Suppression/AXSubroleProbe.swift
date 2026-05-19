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
//                     bridges), OR a §4 BACKSTOP signal positively
//                     identified a nested secure field that the
//                     focused-element subrole alone did not surface.
//   - `Some(false)` — focused element exists and has a non-secure
//                     subrole AND no backstop signal fired.
//   - `nil`         — AX could not answer with reasonable confidence
//                     (permission denied, no focused element on a
//                     queryable app, Electron AX intermittency, API
//                     disabled, OR every backstop signal errored
//                     without a positive answer). The cascade treats
//                     `nil` as fail-safe per ADR-0013 §3 + §7.
//
// AX permission is a hard prerequisite. The agent shell requests it
// during onboarding (DESIGN.md §3, R1); without it this probe
// returns `nil` and the cascade redacts the event.
//
// ## STEP-2-FINDING-001 §4 backstop (this file)
//
// Step-2 (`docs/audit/2026-05-19-step2-sec-7-corpus.md`) diagnosed the
// root cause: `AXUIElementCopyAttributeValue(systemWide,
// kAXFocusedUIElementAttribute, …)` returns the focused CONTAINER
// (e.g. an `AXGroup` whose subrole is `AXApplicationDialog`, title
// "Login"; or an `AXWindow` titled "TV") — NOT the descendant active
// input. The prior probe inspected only the focused element's own
// subrole and never traversed, so secure text fields nested inside
// dialogs / sheets / web views were invisible to it. macOS 26 Tahoe
// SwiftUI + Catalyst bridges make this the common case for system
// password fields.
//
// The backstop runs ONLY when the focused element's own subrole is
// not `kAXSecureTextFieldSubrole` (i.e. the original probe would
// have returned `false`). Three additive signals — any one positive
// ⇒ `true`. Each signal is bounded, each is testable in isolation
// against the pure `classify(...)` function, and each is evaluated
// against the SAME focused element the original switch consulted.
//
//   1. **Descendant traversal** (`descendantSecureSubrole`) — walk
//      `kAXChildrenAttribute` and the focused descendant chain
//      (`kAXFocusedUIElementAttribute`) of the focused element to a
//      max depth of 3 and a max total budget of 32 nodes. Any
//      descendant whose `kAXSubroleAttribute` equals
//      `kAXSecureTextFieldSubrole` ⇒ positive. Bounded; O(constant);
//      aborts immediately on first match.
//
//   2. **Value-attribute-hidden heuristic** (`valueAttributeHidden`)
//      — for the focused element itself: if `kAXValueAttribute` is
//      `AXUIElementIsAttributeSettable` true (i.e. the field accepts
//      input) BUT the value read returns nil / empty / a string of
//      pure mask glyphs (`•`, `●`, `*`, `·`) AND
//      `kAXRoleAttribute` is `AXTextField` or `AXTextArea`, treat as
//      secure. This is the macOS-native pattern: secure fields accept
//      input but hide the read-back value from AX.
//
//   3. **Identifier / title / placeholder regex backstop**
//      (`identifierRegexBackstop`) — case-insensitive token-set match
//      against `kAXIdentifierAttribute`, `kAXTitleAttribute`, and
//      `kAXPlaceholderValueAttribute` of the focused element OR (if
//      the focused element is a container like dialog / window /
//      sheet / group) any descendant up to depth 3. Tokenization
//      splits on non-alphanumerics AND CamelCase humps; a match
//      requires (a) any token in the positive set
//      {password, passcode, passphrase, pin, secret, unlock, secure}
//      AND (b) no token in the negative-context set
//      {recovery, link, info, hint, help, label, learn, more,
//       forgot, reset, button, tutorial, docs, what, why, how}.
//      This is the operational interpretation of the brief's
//      "\b(password|…)\b" — bare `\b` cannot satisfy both
//      "MyPasswordField → positive" (CamelCase, no `\b` between
//      `y` and `P`) and "password-recovery-link → negative"
//      (literal `\b` matches at the hyphens) — token-set matching
//      satisfies both at the price of a small stoplist.
//
// Evaluation order is cheap-first (signal 2 → signal 3 → signal 1).
// A signal's individual AX-error path ⇒ `.errored` outcome (do NOT
// widen to false). Combining rule (in `classify(...)`):
//   - any `.positive` ⇒ true.
//   - all-negative (no errors, no positive) ⇒ preserve prior false.
//   - any `.errored` with no `.positive` ⇒ nil (fail-safe; do NOT
//     widen to false on a partially-blind signal).
//
// ## `--probe-debug` instrumentation
//
// `AXProbeObservation` records the four AX-read fields (role,
// subrole, identifier, title) AND the three backstop outcomes. The
// helper's `--probe-debug` formatter (`main.swift`) writes one
// stderr line per probe call: which signal fired, or whether every
// signal was negative / errored. Next Step-2 re-run uses these
// lines to attribute the `reason=4` (or its absence) at signal
// granularity.
//
// **Steady-state cost when no sink is wired is zero on the focus +
// subrole reads**: the production path makes the same two AX calls
// the prior implementation made. The backstop signals run ONLY on
// the `prior == false` path and ONLY make AX calls on the focused
// element + bounded descendants (≤32 nodes, depth ≤3). They are
// not gated behind the debug sink — they are part of the cascade
// answer.

import ApplicationServices
import Foundation

/// Outcome of one §4 backstop signal evaluation.
///
/// `positive` — the signal asserts the focus context contains a
/// secure-text affordance; the cascade should suppress.
/// `negative` — the signal positively asserts the focus context does
/// NOT contain such an affordance.
/// `errored` — the signal could not be evaluated (AX call failed
/// catastrophically, permission revoked mid-probe, etc.). Treated as
/// "no data"; per the STEP-2-FINDING-001 contract this never widens
/// to `false` — the combining rule fails safe to `nil` instead.
public enum AXBackstopOutcome: Sendable, Equatable {
    case positive
    case negative
    case errored
}

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
    /// Outcome of signal 1 (descendant subrole traversal).
    public let descendantSecure: AXBackstopOutcome
    /// Outcome of signal 2 (value-attribute-hidden heuristic).
    public let valueAttributeHidden: AXBackstopOutcome
    /// Outcome of signal 3 (identifier / title / placeholder regex).
    public let identifierRegexMatch: AXBackstopOutcome
    /// The cascade-facing classification: `true` (secure), `false`
    /// (not secure / no focus), `nil` (cannot classify, fail-safe).
    public let classification: Bool?

    public init(
        focusResult: AXError,
        role: String?,
        subrole: String?,
        identifier: String?,
        title: String?,
        descendantSecure: AXBackstopOutcome = .negative,
        valueAttributeHidden: AXBackstopOutcome = .negative,
        identifierRegexMatch: AXBackstopOutcome = .negative,
        classification: Bool?
    ) {
        self.focusResult = focusResult
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.descendantSecure = descendantSecure
        self.valueAttributeHidden = valueAttributeHidden
        self.identifierRegexMatch = identifierRegexMatch
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

        // Compute the prior (pre-backstop) shape so we can decide
        // whether the backstops need to run at all. The full `classify`
        // is called below with the actual outcomes; this is a tiny
        // gate that lets us skip live AX traversal on the prior-true
        // and prior-nil paths (which the backstops cannot widen).
        let priorClassification = Self.classify(
            focusResult: focusResult,
            focusedRefMatched: focusedElement != nil,
            subroleResult: subroleResult,
            subroleValue: subroleValue,
            descendantSecure: .negative,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .negative
        )

        // Cheap-first signal order (per spec): value-hidden → regex →
        // descendant traversal. Only evaluate when prior was false —
        // backstops never override `true` (already secure) or `nil`
        // (already fail-safe).
        let valueHidden: AXBackstopOutcome
        let regexMatch: AXBackstopOutcome
        let descendantSecure: AXBackstopOutcome
        if priorClassification == false, let element = focusedElement {
            valueHidden = Self.valueAttributeHiddenSignal(of: element)
            if valueHidden == .positive {
                // Short-circuit: a positive signal will produce true
                // regardless of the others. Save the remaining AX
                // calls. The observation still records `.negative` for
                // unevaluated signals — they did not fire, by
                // construction.
                regexMatch = .negative
                descendantSecure = .negative
            } else {
                regexMatch = Self.identifierRegexSignal(of: element)
                if regexMatch == .positive {
                    descendantSecure = .negative
                } else {
                    descendantSecure = Self.descendantSecureSubroleSignal(of: element)
                }
            }
        } else {
            valueHidden = .negative
            regexMatch = .negative
            descendantSecure = .negative
        }

        let classification = Self.classify(
            focusResult: focusResult,
            focusedRefMatched: focusedElement != nil,
            subroleResult: subroleResult,
            subroleValue: subroleValue,
            descendantSecure: descendantSecure,
            valueAttributeHidden: valueHidden,
            identifierRegexMatch: regexMatch
        )

        // STEADY-STATE FAST PATH. When no sink is wired (default
        // production build), skip the role / identifier / title reads
        // entirely. Zero added AX traffic over the prior implementation
        // on the focus + subrole reads. Backstops only ran when prior
        // was false; that's the structural cost the §4 contract pays.
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
                    descendantSecure: descendantSecure,
                    valueAttributeHidden: valueHidden,
                    identifierRegexMatch: regexMatch,
                    classification: classification
                ))
        }

        return classification
    }

    /// Pure classifier — the AX-result → cascade-input mapping that
    /// STEP-2-FINDING-001 needs to unit-test in isolation. Makes no AX
    /// calls; tests inject synthetic `AXError` + subrole strings +
    /// backstop outcomes and assert the cascade-input shape.
    ///
    /// The three backstop params default to `.negative` so call sites
    /// that pre-date STEP-2-FINDING-001 stay byte-equivalent.
    static func classify(
        focusResult: AXError,
        focusedRefMatched: Bool,
        subroleResult: AXError,
        subroleValue: String?,
        descendantSecure: AXBackstopOutcome = .negative,
        valueAttributeHidden: AXBackstopOutcome = .negative,
        identifierRegexMatch: AXBackstopOutcome = .negative
    ) -> Bool? {
        // First compute the prior (pre-backstop) classification. This
        // is the exact switch the original probe used.
        let prior = priorClassify(
            focusResult: focusResult,
            focusedRefMatched: focusedRefMatched,
            subroleResult: subroleResult,
            subroleValue: subroleValue
        )

        // Backstops only widen `false` toward `true` (or `nil` when
        // every signal errored). They never override `true` (already
        // secure) or `nil` (already fail-safe).
        guard prior == false else { return prior }

        return combineBackstops(
            descendantSecure: descendantSecure,
            valueAttributeHidden: valueAttributeHidden,
            identifierRegexMatch: identifierRegexMatch,
            priorFalse: false
        )
    }

    /// The original `classify(...)` switch arms, factored out so the
    /// backstop layer can ask "what would the prior probe have
    /// returned?" without re-running the live AX queries.
    static func priorClassify(
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
                // don't). That's a prior "not secure" answer the
                // backstop layer is free to widen.
                return false
            default:
                // Any failure path on the subrole read — treat as
                // cannot-classify.
                return nil
            }

        case .noValue:
            // No focused element on the system — nothing to classify.
            // Prior "not secure"; the backstop layer also gets a
            // chance (it will be all-negative because there is no
            // focused element to traverse, so the combiner just
            // returns the prior false unchanged).
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

    /// Pure backstop combiner — given three signal outcomes and the
    /// prior `false` classification, decide the §4 answer.
    ///
    /// Rule:
    ///   - any `.positive` ⇒ `true`.
    ///   - all `.negative` ⇒ `priorFalse` (preserve the prior answer).
    ///   - any `.errored` with no `.positive` ⇒ `nil` (do NOT widen
    ///     to false on a partially-blind signal — fail-safe).
    static func combineBackstops(
        descendantSecure: AXBackstopOutcome,
        valueAttributeHidden: AXBackstopOutcome,
        identifierRegexMatch: AXBackstopOutcome,
        priorFalse: Bool
    ) -> Bool? {
        let signals = [descendantSecure, valueAttributeHidden, identifierRegexMatch]
        if signals.contains(.positive) { return true }
        if signals.contains(.errored) { return nil }
        return priorFalse
    }

    /// Pure token-set match for the §4 identifier / title /
    /// placeholder regex backstop.
    ///
    /// Returns `true` iff `s`, after tokenization on non-alphanumeric
    /// boundaries AND CamelCase humps, contains at least one token in
    /// the positive set AND no token in the negative-context set.
    ///
    /// Positive set: password, passcode, passphrase, pin, secret,
    /// unlock, secure.
    /// Negative-context set: recovery, link, info, hint, help, label,
    /// learn, more, forgot, reset, button, tutorial, docs, what, why,
    /// how.
    ///
    /// Pure / side-effect-free / unit-testable in isolation.
    static func passwordIdentifierMatches(_ s: String) -> Bool {
        let tokens = tokenize(s).map { $0.lowercased() }
        let tset = Set(tokens)
        guard !tset.isDisjoint(with: positiveKeywordTokens) else { return false }
        guard tset.isDisjoint(with: negativeContextTokens) else { return false }
        return true
    }

    /// Split `s` on (a) any non-letter/non-digit character, and (b)
    /// CamelCase humps (lowercase → uppercase transition). Returns the
    /// resulting token list, preserving original case.
    ///
    /// Examples:
    ///   "MyPasswordField"        → ["My", "Password", "Field"]
    ///   "password-recovery-link" → ["password", "recovery", "link"]
    ///   "PASSCODE"               → ["PASSCODE"]
    ///   "secret-pin"             → ["secret", "pin"]
    ///   ""                       → []
    static func tokenize(_ s: String) -> [String] {
        let chunks = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var out: [String] = []
        for chunk in chunks {
            var current = ""
            var prev: Character? = nil
            for ch in chunk {
                if let p = prev, p.isLowercase, ch.isUppercase {
                    if !current.isEmpty { out.append(current) }
                    current = String(ch)
                } else {
                    current.append(ch)
                }
                prev = ch
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    /// Positive password-keyword token set. Lowercased.
    static let positiveKeywordTokens: Set<String> = [
        "password", "passcode", "passphrase", "pin", "secret", "unlock", "secure",
    ]

    /// Negative-context token set — tokens that, when co-occurring with
    /// a positive token, indicate the string is about passwords
    /// (recovery flow, hint, link, …) rather than IS a password field.
    /// Lowercased.
    static let negativeContextTokens: Set<String> = [
        "recovery", "link", "info", "hint", "help", "label", "learn", "more",
        "forgot", "reset", "button", "tutorial", "docs", "what", "why", "how",
    ]

    /// Container roles whose descendants the regex backstop walks (to
    /// catch nested fields when AX focus is the dialog / sheet / group
    /// itself — the STEP-2-FINDING-001 root cause).
    static let containerRoles: Set<String> = [
        "AXWindow", "AXGroup", "AXSheet", "AXScrollArea",
        "AXSplitGroup", "AXDialog", "AXDrawer", "AXPopover",
    ]

    /// Mask glyphs that, on a settable text-field value attribute,
    /// indicate the field is masking user input (heuristic for
    /// secure-text fields whose subrole AX does not surface).
    static let maskGlyphs: Set<Character> = ["•", "●", "*", "·"]

    /// Bounded budget for descendant traversal: max depth and max
    /// total visited nodes. Per the brief: depth ≤ 3, nodes ≤ 32.
    static let backstopMaxDepth = 3
    static let backstopMaxNodes = 32

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

    /// Read any string AX attribute on `element`. Used by the
    /// `--probe-debug` slow path AND by signals 2 / 3 (the steady-state
    /// production cost when prior was false). Returns `nil` on any
    /// non-`.success` AX result OR on a non-String value.
    private static func readStringAttribute(
        _ element: AXUIElement, _ attribute: CFString
    ) -> String? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard r == .success else { return nil }
        return ref as? String
    }

    // MARK: - §4 backstop signals (live AX)

    /// Signal 1 — bounded descendant traversal looking for a node
    /// whose `kAXSubroleAttribute` equals `kAXSecureTextFieldSubrole`.
    ///
    /// Walk includes both `kAXChildrenAttribute` AND the focused
    /// descendant chain (`kAXFocusedUIElementAttribute`). Depth ≤ 3
    /// and total visited nodes ≤ 32; aborts on first match.
    static func descendantSecureSubroleSignal(
        of root: AXUIElement
    ) -> AXBackstopOutcome {
        var budget = backstopMaxNodes
        var anyTraversalError = false
        var madeProgress = false

        func recurse(_ node: AXUIElement, depth: Int) -> Bool {
            if budget <= 0 { return false }
            if depth >= backstopMaxDepth { return false }

            // Children of `node` — both the focused-descendant link
            // (priority — the user's actual input target) and the
            // structural child array.
            var queued: [AXUIElement] = []
            if let focusedChild = readElementAttribute(
                node, kAXFocusedUIElementAttribute as CFString)
            {
                queued.append(focusedChild)
            }
            switch readElementArrayAttribute(node, kAXChildrenAttribute as CFString) {
            case .success(let arr):
                queued.append(contentsOf: arr)
            case .empty:
                break
            case .errored:
                anyTraversalError = true
            }

            for child in queued {
                if budget <= 0 { return false }
                budget -= 1
                madeProgress = true
                if let subrole = readStringAttribute(child, kAXSubroleAttribute as CFString),
                    subrole == (kAXSecureTextFieldSubrole as String)
                {
                    return true
                }
                if recurse(child, depth: depth + 1) { return true }
            }
            return false
        }

        if recurse(root, depth: 0) { return .positive }
        if anyTraversalError && !madeProgress { return .errored }
        return .negative
    }

    /// Signal 2 — value-attribute-hidden heuristic. Positive iff the
    /// focused element is an `AXTextField` / `AXTextArea` whose
    /// `kAXValueAttribute` is settable but reads back as nil / empty
    /// / a pure mask-glyph string.
    static func valueAttributeHiddenSignal(
        of element: AXUIElement
    ) -> AXBackstopOutcome {
        // 1. Role gate. Only text-input-shaped roles can produce a
        //    meaningful value-hidden signal.
        guard let role = readStringAttribute(element, kAXRoleAttribute as CFString) else {
            // No readable role — cannot assert hidden-value semantics.
            return .errored
        }
        guard role == "AXTextField" || role == "AXTextArea" else {
            return .negative
        }

        // 2. Settable check. A non-settable value attribute is not an
        //    input field; the heuristic does not apply.
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        switch settableResult {
        case .success:
            guard settable.boolValue else { return .negative }
        case .attributeUnsupported, .noValue:
            return .negative
        default:
            return .errored
        }

        // 3. Value read.
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef)
        switch valueResult {
        case .success:
            guard let s = valueRef as? String else {
                // Settable text-field role with a non-string value is
                // suspicious enough that we treat it as hidden — a
                // standard `NSSecureTextField`'s AX value read returns
                // a value of variable type depending on the binding.
                return .positive
            }
            if s.isEmpty { return .positive }
            if isAllMaskGlyphs(s) { return .positive }
            return .negative
        case .noValue:
            // Settable text field with no readable value — secure-input
            // shape.
            return .positive
        case .attributeUnsupported:
            return .negative
        default:
            return .errored
        }
    }

    /// Signal 3 — identifier / title / placeholder regex backstop.
    /// Checks the focused element's
    /// `kAXIdentifierAttribute` / `kAXTitleAttribute` /
    /// `kAXPlaceholderValueAttribute`; if the focused element is a
    /// container role, also checks descendants up to depth 3 (budget
    /// shared with signal 1's bound, conservatively).
    static func identifierRegexSignal(
        of element: AXUIElement
    ) -> AXBackstopOutcome {
        var anyError = false
        var madeProgress = false

        func checkOne(_ el: AXUIElement) -> Bool? {
            // Return `true` on positive, `false` on negative-after-read,
            // `nil` if every attribute read errored (so the caller can
            // mark `anyError`).
            var sawAny = false
            for attr in [
                kAXIdentifierAttribute, kAXTitleAttribute,
                kAXPlaceholderValueAttribute,
            ] as [String] {
                if let s = readStringAttribute(el, attr as CFString) {
                    sawAny = true
                    if passwordIdentifierMatches(s) { return true }
                }
            }
            return sawAny ? false : nil
        }

        // Check the focused element itself first.
        switch checkOne(element) {
        case .some(true): return .positive
        case .some(false): madeProgress = true
        case .none: anyError = true
        }

        // If the focused element is a container, walk its descendants
        // up to depth 3. Bounded budget shared conceptually with
        // signal 1 — but the brief specifies the regex backstop also
        // bounds at depth 3, so we cap independently here.
        let role = readStringAttribute(element, kAXRoleAttribute as CFString)
        guard let role, containerRoles.contains(role) else {
            return anyError && !madeProgress ? .errored : .negative
        }

        var budget = backstopMaxNodes
        var found = false

        func recurse(_ node: AXUIElement, depth: Int) {
            if found || budget <= 0 { return }
            if depth >= backstopMaxDepth { return }

            var queued: [AXUIElement] = []
            if let focusedChild = readElementAttribute(
                node, kAXFocusedUIElementAttribute as CFString)
            {
                queued.append(focusedChild)
            }
            switch readElementArrayAttribute(node, kAXChildrenAttribute as CFString) {
            case .success(let arr):
                queued.append(contentsOf: arr)
            case .empty:
                break
            case .errored:
                anyError = true
            }
            for child in queued {
                if found || budget <= 0 { return }
                budget -= 1
                madeProgress = true
                switch checkOne(child) {
                case .some(true): found = true; return
                case .some(false): break
                case .none: anyError = true
                }
                recurse(child, depth: depth + 1)
            }
        }

        recurse(element, depth: 0)
        if found { return .positive }
        if anyError && !madeProgress { return .errored }
        return .negative
    }

    // MARK: - AX read helpers used by the backstops

    /// Read a single AXUIElement attribute (e.g.
    /// `kAXFocusedUIElementAttribute`). Returns the element on
    /// success, `nil` on any non-success or type mismatch.
    private static func readElementAttribute(
        _ element: AXUIElement, _ attribute: CFString
    ) -> AXUIElement? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard r == .success, let ref else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXUIElement)
    }

    /// Result of an AX array attribute read (e.g.
    /// `kAXChildrenAttribute`).
    enum ArrayReadResult {
        /// Read returned `.success` with a non-empty array.
        case success([AXUIElement])
        /// Read returned `.success` empty array, `.noValue`, or
        /// `.attributeUnsupported` — the node legitimately has no
        /// children.
        case empty
        /// Read returned a catastrophic AX error.
        case errored
    }

    private static func readElementArrayAttribute(
        _ element: AXUIElement, _ attribute: CFString
    ) -> ArrayReadResult {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, attribute, &ref)
        switch r {
        case .success:
            guard let ref else { return .empty }
            guard CFGetTypeID(ref) == CFArrayGetTypeID() else { return .empty }
            // swiftlint:disable:next force_cast
            let arr = ref as! CFArray
            let count = CFArrayGetCount(arr)
            if count == 0 { return .empty }
            var out: [AXUIElement] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let p = CFArrayGetValueAtIndex(arr, i)
                guard let p else { continue }
                let item = Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue()
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { continue }
                // swiftlint:disable:next force_cast
                out.append(item as! AXUIElement)
            }
            return out.isEmpty ? .empty : .success(out)
        case .noValue, .attributeUnsupported:
            return .empty
        default:
            return .errored
        }
    }

    /// True iff `s` is non-empty AND every character is a known mask
    /// glyph (used by the value-hidden heuristic).
    private static func isAllMaskGlyphs(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s {
            if !maskGlyphs.contains(ch) { return false }
        }
        return true
    }
}
