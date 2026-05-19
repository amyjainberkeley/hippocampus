// SPDX-License-Identifier: TBD-private
//
// SuppressionInputs — protocol-mockable inputs to the ADR-0013 cascade.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These protocols decouple the
// cascade decision logic from the OS APIs that feed it. In production
// (Phase-1 cycle 2+) the protocols are implemented by concrete adapters
// over Carbon `IsSecureEventInputEnabled()`, AX
// `AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, …)`,
// `NSWorkspace.shared.frontmostApplication`, and the in-helper denylist
// loaded from `core::store::denylist`. In tests they're mocked so the
// cascade's decision logic is exercisable without a running OS pipeline.

import Foundation

/// Process-wide secure-input status — Carbon
/// `IsSecureEventInputEnabled()`. ADR-0013 cascade §3.
public protocol SecureEventInputProbe: Sendable {
    /// Re-poll the bit. Cheap (single syscall). Called on every state
    /// transition before encode/store per ADR-0013 §3.
    func isSecureEventInputEnabled() -> Bool
}

/// Focused-element AX subrole. ADR-0013 cascade §4.
public protocol AXSecureSubroleProbe: Sendable {
    /// Returns true iff the currently focused element's
    /// `kAXSubroleAttribute` is `"AXSecureTextField"`.
    ///
    /// May return `nil` when the AX query cannot be answered with
    /// reasonable confidence — Electron windows with intermittent AX,
    /// permission errors, app-crashed-mid-probe. The cascade treats
    /// `nil` as a fail-safe input per ADR-0013 §3 + §7.
    func focusedHasSecureSubrole() -> Bool?
}

/// App/URL denylist matcher. ADR-0013 cascade §1 (source-level via
/// `SCContentFilter`) and §5 (post-capture belt-and-suspenders).
public protocol DenylistProbe: Sendable {
    /// True iff the given app bundle is in the user's app denylist.
    func appIsDenied(bundleId: String) -> Bool

    /// True iff the given URL matches a user URL pattern.
    func urlIsDenied(_ url: String) -> Bool

    /// True iff the given window title matches a user window-title
    /// pattern.
    func windowTitleIsDenied(_ title: String) -> Bool
}

/// Source-filter ↔ live-policy drift detector. ADR-0013 cascade §5
/// (post-capture denylist belt-and-suspenders).
///
/// ## Why this exists (the gap §5 closes)
///
/// Cascade §1 enforces the denylist at the *earliest* layer: the
/// `SCContentFilter` installed on the live `SCStream`. That filter is
/// built from a **snapshot** of the denylist policy taken at
/// stream-construction time. When the user edits the denylist, the
/// running `SCStream`'s filter is **not** rebuilt instantly — there is
/// a drift window in which a newly-denied source's pixels are still
/// flowing into the pipeline because the *source-level* exclusion
/// predates the policy change.
///
/// §5 closes that window. It compares the policy generation the
/// installed filter was built from against the generation of the
/// denylist as it stands *now*; if they differ AND the live workflow
/// context matches the *current* policy, the cascade suppresses here
/// with `.denylistPostCapture` (a reason distinct from §1's
/// `.denylistSource`, so the privacy tombstone records that the
/// post-capture backstop fired — not the source filter). ADR-0013 §5
/// also requires this §1↔§5 divergence to be observable to the CRS
/// Telemetry-Gap analyst; the distinct `redaction_reason` is that
/// observability surface.
///
/// OS-API-free by construction: the adapter that owns the live
/// `SCStream` implements this protocol (it knows the filter's build
/// generation and can re-match the *current* in-helper denylist). The
/// cascade only consumes the protocol, so the §5 decision logic is
/// unit-testable without a running capture pipeline.
public protocol DenylistDriftProbe: Sendable {
    /// Policy generation the currently-installed `SCContentFilter`
    /// (cascade §1 source-level exclusion) was constructed from.
    func installedFilterGeneration() -> UInt64

    /// Policy generation of the in-helper denylist table as it stands
    /// *now* (monotonic; bumped on every user denylist edit).
    func currentPolicyGeneration() -> UInt64

    /// Does the live workflow context match the *current* denylist
    /// policy — which may be newer than the snapshot the installed
    /// `SCContentFilter` enforces?
    func currentPolicyDenies(_ context: WorkflowContext) -> Bool
}

/// Default `DenylistDriftProbe` sentinel: no drift, ever.
///
/// Reports generation parity and a non-denying current policy, so the
/// §5 backstop is a strict no-op. This is the cascade's default so
/// constructions that have not yet wired live-`SCStream` filter-
/// generation tracking keep their exact prior behavior. Real drift
/// detection is supplied by the live-capture adapter (Track B, on a
/// real machine); the cascade *decision* for it is locked + tested
/// here (Track A).
public struct NoDenylistDrift: DenylistDriftProbe {
    public init() {}
    public func installedFilterGeneration() -> UInt64 { 0 }
    public func currentPolicyGeneration() -> UInt64 { 0 }
    public func currentPolicyDenies(_: WorkflowContext) -> Bool { false }
}

/// OS-blacked-region detector. ADR-0013 cascade §2.
///
/// The helper tracks known windows whose pixels render black to capture
/// clients — `NSWindowSharingType = .none`, FairPlay/DRM playback,
/// `SCContentFilter`-excluded apps. When a captured frame contains a
/// region matching one of these windows, the helper drops the
/// surrounding metadata too.
public protocol BlackedRegionProbe: Sendable {
    /// True iff there is at least one window in the current frame's
    /// bounds whose contents the OS is rendering black to capture
    /// clients.
    func hasBlackedRegion() -> Bool
}

/// Minimal `WorkflowContext` carried into the cascade.
///
/// Mirrors `core::capture::WorkflowContext` but is owned by the Swift
/// side because it lives inside the cascade — never crosses IPC for a
/// suppressed event (per ADR-0013 §2 redaction-before-store guarantee).
public struct WorkflowContext: Sendable, Equatable {
    public let appBundleId: String?
    public let windowTitle: String?
    public let url: String?
    /// Page text extracted from a browser extension. The cascade does
    /// NOT inspect this — `SecretBench`-style regex matching is the
    /// core's responsibility (cascade §6), not the helper's.
    public let pageText: String?

    public init(
        appBundleId: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        pageText: String? = nil
    ) {
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.url = url
        self.pageText = pageText
    }
}
