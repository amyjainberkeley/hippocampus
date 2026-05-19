// SPDX-License-Identifier: TBD-private
//
// SuppressionCascade — ADR-0013 binding cascade orchestrator.
//
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5.
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// This file IS the cascade. Every Phase-1 capture-spine PR that lands
// SCStream lifecycle must wire this orchestrator end-to-end. SCStream
// without this is rejected at CSO review (no "follow-up" path).
//
// The cascade is OS-API-free by design: it takes the four probe
// protocols + a `WorkflowContext` + a `BlackedRegionProbe` signal and
// returns a `Decision`. The actual OS-API plumbing (Carbon syscall, AX
// query, denylist load) lives in adapter implementations of these
// protocols. This separation is what lets the binding decision logic
// be testable without a running OS pipeline.

import Foundation

/// What the cascade decided about a candidate event.
///
/// `.allow` means "this event survived; the helper may encode and
/// forward to the core." `.suppress(reason)` means "this event MUST be
/// dropped before any pixel/text/metadata crosses IPC; emit a privacy
/// tombstone with this reason."
public enum SuppressionDecision: Sendable, Equatable {
    case allow
    case suppress(reason: RedactionReason)
}

/// Cascade orchestrator.
///
/// Initialize once per helper-process lifetime with the four probes +
/// the denylist matcher. Call `decide(context:)` on every state
/// transition. The orchestrator is `Sendable` and re-entrant; tests
/// exercise it from multiple synthetic call sites in parallel.
public struct SuppressionCascade: Sendable {
    private let secureEventInput: any SecureEventInputProbe
    private let axSecureSubrole: any AXSecureSubroleProbe
    private let denylist: any DenylistProbe
    private let blackedRegion: any BlackedRegionProbe
    private let knownSafeAppBundles: Set<String>

    /// Construct a cascade orchestrator.
    ///
    /// `knownSafeAppBundles` is the curated allowlist from ADR-0013 §3
    /// — bundle IDs whose AX coverage has been positively characterized
    /// by Phase-1 integration tests. Initially empty (no app is
    /// "known-safe" until earned). Additions are CSO-gated.
    public init(
        secureEventInput: any SecureEventInputProbe,
        axSecureSubrole: any AXSecureSubroleProbe,
        denylist: any DenylistProbe,
        blackedRegion: any BlackedRegionProbe,
        knownSafeAppBundles: Set<String> = []
    ) {
        self.secureEventInput = secureEventInput
        self.axSecureSubrole = axSecureSubrole
        self.denylist = denylist
        self.blackedRegion = blackedRegion
        self.knownSafeAppBundles = knownSafeAppBundles
    }

    /// Apply the ADR-0013 cascade in binding order. First match wins.
    ///
    /// Order:
    ///   §1 — source-level denylist (app / URL / window title).
    ///   §2 — OS-blacked-out region present.
    ///   §3 — `IsSecureEventInputEnabled()` true.
    ///   §4 — focused AX element has `kAXSecureTextFieldSubrole`.
    ///   §5 — post-capture denylist (belt-and-suspenders; should have
    ///        been caught by §1's `SCContentFilter` exclusion, but if
    ///        the source-level config drifted from the policy table
    ///        we catch it here).
    ///   (§6 OCR-time regex runs in `core/`, NOT here.)
    ///   §7 — fail-safe default: unknown classification ⇒ redact.
    public func decide(context: WorkflowContext) -> SuppressionDecision {
        // §1 — source-level denylist (the load-bearing primitive).
        if let bundle = context.appBundleId, denylist.appIsDenied(bundleId: bundle) {
            return .suppress(reason: .denylistSource)
        }
        if let url = context.url, denylist.urlIsDenied(url) {
            return .suppress(reason: .denylistSource)
        }
        if let title = context.windowTitle, denylist.windowTitleIsDenied(title) {
            return .suppress(reason: .denylistSource)
        }

        // §2 — OS-already-blacked-out region.
        if blackedRegion.hasBlackedRegion() {
            return .suppress(reason: .osBlackedRegion)
        }

        // §3 — process-wide secure-input bit.
        if secureEventInput.isSecureEventInputEnabled() {
            return .suppress(reason: .secureEventInput)
        }

        // §4 — focused AX secure subrole.
        // `nil` from the probe means "AX could not answer with reasonable
        // confidence" — that falls through to §7 (fail-safe) below, NOT
        // to allow.
        let axResult = axSecureSubrole.focusedHasSecureSubrole()
        if axResult == true {
            return .suppress(reason: .axSecureSubrole)
        }

        // §5 — post-capture denylist (no-op duplicate of §1 in this
        // skeleton; in production the §1 check uses the SCContentFilter
        // configuration while §5 uses the live WorkflowContext at OCR
        // time. They diverge under denylist updates not yet propagated
        // to the SCStream — and that's the gap §5 closes).
        // Phase-1 cycle 2+ wires the divergence detection; here §5
        // shares the same denylist probe, so it cannot find anything
        // §1 missed.

        // §7 — fail-safe default: unknown ⇒ redact.
        // The cascade treats a positive classification ("AX returned a
        // non-secure subrole" + "no secure-event-input" + "app is on
        // the known-safe list OR the focused element has a recognizable
        // non-secure AX role") as the ONLY path to `.allow`. Everything
        // else redacts.
        let isKnownSafeApp = context.appBundleId.map(knownSafeAppBundles.contains) ?? false

        switch (axResult, isKnownSafeApp) {
        case (false, true):
            // AX positively identified the focused element as non-secure,
            // AND the foreground app is on the curated known-safe list.
            // This is the only `.allow` path.
            return .allow
        default:
            return .suppress(reason: .failsafeUnknown)
        }
    }
}
