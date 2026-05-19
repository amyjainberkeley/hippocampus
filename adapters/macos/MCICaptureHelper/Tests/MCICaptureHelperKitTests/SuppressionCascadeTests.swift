// SPDX-License-Identifier: TBD-private
//
// SuppressionCascadeTests — ADR-0013 cascade decisions on synthetic inputs.
//
// The 7-scenario corpus from ADR-0013 §7 is split between:
//   - DECISION tests (this file): cascade returns the right Decision
//     given probe inputs. Pure logic, no OS APIs.
//   - INTEGRATION tests (Phase-1 cycle 2+, against real OS APIs).
//
// Tests here are LAUNCH-BLOCKER regressions: if any of them goes red,
// the cascade is shipping with a behavior the ADR forbids.

import XCTest
@testable import MCICaptureHelperKit

// MARK: - Mock probes

private struct MockSecureEventInput: SecureEventInputProbe {
    let enabled: Bool
    func isSecureEventInputEnabled() -> Bool { enabled }
}

private struct MockAX: AXSecureSubroleProbe {
    let result: Bool?
    func focusedHasSecureSubrole() -> Bool? { result }
}

private struct MockBlackedRegion: BlackedRegionProbe {
    let present: Bool
    func hasBlackedRegion() -> Bool { present }
}

private struct MockDenylist: DenylistProbe {
    let apps: Set<String>
    let urls: [String]
    let titles: [String]
    func appIsDenied(bundleId: String) -> Bool { apps.contains(bundleId) }
    func urlIsDenied(_ url: String) -> Bool { urls.contains(where: { url.hasPrefix($0) }) }
    func windowTitleIsDenied(_ title: String) -> Bool { titles.contains(where: { title.contains($0) }) }
}

// Convenience builder.
private func cascade(
    secureEventInput: Bool = false,
    ax: Bool? = false,
    blackedRegion: Bool = false,
    denyApps: Set<String> = [],
    denyURLs: [String] = [],
    denyTitles: [String] = [],
    knownSafe: Set<String> = []
) -> SuppressionCascade {
    SuppressionCascade(
        secureEventInput: MockSecureEventInput(enabled: secureEventInput),
        axSecureSubrole: MockAX(result: ax),
        denylist: MockDenylist(apps: denyApps, urls: denyURLs, titles: denyTitles),
        blackedRegion: MockBlackedRegion(present: blackedRegion),
        knownSafeAppBundles: knownSafe
    )
}

// MARK: - ADR-0013 cascade §1 — source-level denylist

final class CascadeDenylistTests: XCTestCase {
    func testAppDenylistMatchSuppresses() {
        let c = cascade(denyApps: ["com.1password.1password7"], knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(appBundleId: "com.1password.1password7")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .denylistSource))
    }

    func testURLDenylistMatchSuppresses() {
        let c = cascade(denyURLs: ["https://accounts.google.com/"], knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(
            appBundleId: "com.apple.Safari",
            url: "https://accounts.google.com/signin/v2/identifier"
        )
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .denylistSource))
    }

    func testWindowTitleDenylistMatchSuppresses() {
        let c = cascade(denyTitles: ["Bitwarden — Unlock Vault"], knownSafe: ["com.bitwarden.desktop"])
        let ctx = WorkflowContext(
            appBundleId: "com.bitwarden.desktop",
            windowTitle: "Bitwarden — Unlock Vault"
        )
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .denylistSource))
    }
}

// MARK: - ADR-0013 cascade §2 — OS-blacked-out region

final class CascadeBlackedRegionTests: XCTestCase {
    func testBlackedRegionSuppresses() {
        let c = cascade(blackedRegion: true, knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .osBlackedRegion))
    }
}

// MARK: - ADR-0013 cascade §3 — IsSecureEventInputEnabled

final class CascadeSecureEventInputTests: XCTestCase {
    func testSecureEventInputTrueSuppresses() {
        let c = cascade(secureEventInput: true, knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .secureEventInput))
    }

    /// Coverage-honesty test (ADR-0013 §6): even on Electron / Chromium
    /// where AX is intermittent, the OS-bit catches Terminal sudo /
    /// pinentry / 1Password vault — anything that calls
    /// `EnableSecureEventInput()`.
    func testSecureEventInputCatchesElectronWhenAXSilent() {
        let c = cascade(
            secureEventInput: true,  // Bit set by 1Password vault unlock
            ax: nil,                  // AX query couldn't classify
            knownSafe: ["com.electron.app"]
        )
        let ctx = WorkflowContext(appBundleId: "com.electron.app")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .secureEventInput))
    }
}

// MARK: - ADR-0013 cascade §4 — AX secure subrole

final class CascadeAXSubroleTests: XCTestCase {
    func testAXSecureSubroleTrueSuppresses() {
        let c = cascade(ax: true, knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .axSecureSubrole))
    }
}

// MARK: - ADR-0013 cascade §7 — fail-safe (unknown ⇒ redact)

final class CascadeFailsafeTests: XCTestCase {
    /// AX could not classify; no other signal fired. Fail-safe MUST
    /// redact, not allow. This is the load-bearing rule per
    /// ADR-0013 §3 — flipping it requires a fresh CSO ADR amendment.
    func testAXSilentAndAppUnknownReturnsFailsafeRedact() {
        let c = cascade(ax: nil)  // empty known-safe list
        let ctx = WorkflowContext(appBundleId: "com.unknown.electron.app")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .failsafeUnknown))
    }

    /// AX positively said non-secure, but the app is NOT on the
    /// known-safe list. Fail-safe still redacts.
    func testAXSaysNonSecureButAppNotKnownSafeReturnsFailsafeRedact() {
        let c = cascade(ax: false)  // empty known-safe list
        let ctx = WorkflowContext(appBundleId: "com.unknown.app")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .failsafeUnknown))
    }

    /// AX silent + app IS known-safe is STILL a redact — we need a
    /// positive AX classification, not just a quiet AX + safe app.
    /// This guards the "unknown ⇒ redact" semantics.
    func testAXSilentAndKnownSafeAppReturnsFailsafeRedact() {
        let c = cascade(ax: nil, knownSafe: ["com.apple.Safari"])
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .failsafeUnknown))
    }
}

// MARK: - The ONLY allow path

final class CascadeAllowPathTests: XCTestCase {
    /// The single positive-classification path: AX says non-secure
    /// AND the app is on the curated known-safe list AND no other
    /// signal fired. This is the only `.allow` answer.
    func testFullPositiveClassificationAllows() {
        let c = cascade(
            secureEventInput: false,
            ax: false,
            blackedRegion: false,
            knownSafe: ["com.apple.Safari"]
        )
        let ctx = WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: "Wikipedia",
            url: "https://en.wikipedia.org/wiki/Memory"
        )
        XCTAssertEqual(c.decide(context: ctx), .allow)
    }
}

// MARK: - Order matters — first match wins

final class CascadeOrderingTests: XCTestCase {
    /// Source-level denylist fires before secure-event-input even when
    /// both would suppress. Reason must be `.denylistSource`, not
    /// `.secureEventInput` — the cascade's first-match-wins order.
    func testDenylistFiresBeforeSecureEventInput() {
        let c = cascade(
            secureEventInput: true,
            denyApps: ["com.1password.1password7"]
        )
        let ctx = WorkflowContext(appBundleId: "com.1password.1password7")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .denylistSource))
    }

    /// Blacked-region fires before secure-event-input.
    func testBlackedRegionFiresBeforeSecureEventInput() {
        let c = cascade(secureEventInput: true, blackedRegion: true, knownSafe: ["com.x"])
        let ctx = WorkflowContext(appBundleId: "com.x")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .osBlackedRegion))
    }

    /// Secure-event-input fires before AX subrole.
    func testSecureEventInputFiresBeforeAXSubrole() {
        let c = cascade(secureEventInput: true, ax: true, knownSafe: ["com.x"])
        let ctx = WorkflowContext(appBundleId: "com.x")
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .secureEventInput))
    }
}

// MARK: - ADR-0013 cascade §5 — post-capture denylist drift backstop

/// Mock `DenylistDriftProbe`. `installedGen != currentGen` models a
/// denylist edit not yet propagated to the live `SCContentFilter`;
/// `deniesCurrent` models the live context matching the *current*
/// (post-edit) policy that the stale source filter does not enforce.
private struct MockDenylistDrift: DenylistDriftProbe {
    let installedGen: UInt64
    let currentGen: UInt64
    let deniesCurrent: Bool
    func installedFilterGeneration() -> UInt64 { installedGen }
    func currentPolicyGeneration() -> UInt64 { currentGen }
    func currentPolicyDenies(_: WorkflowContext) -> Bool { deniesCurrent }
}

/// Builder that injects a `DenylistDriftProbe`. §1 denylist is empty
/// and the app is known-safe + AX non-secure by default, so absent §5
/// the cascade would `.allow` — isolating §5's effect.
private func driftCascade(
    installedGen: UInt64,
    currentGen: UInt64,
    deniesCurrent: Bool,
    secureEventInput: Bool = false,
    ax: Bool? = false,
    denyApps: Set<String> = [],
    knownSafe: Set<String> = ["com.example.app"]
) -> SuppressionCascade {
    SuppressionCascade(
        secureEventInput: MockSecureEventInput(enabled: secureEventInput),
        axSecureSubrole: MockAX(result: ax),
        denylist: MockDenylist(apps: denyApps, urls: [], titles: []),
        blackedRegion: MockBlackedRegion(present: false),
        denylistDrift: MockDenylistDrift(
            installedGen: installedGen,
            currentGen: currentGen,
            deniesCurrent: deniesCurrent
        ),
        knownSafeAppBundles: knownSafe
    )
}

final class CascadeDenylistDriftTests: XCTestCase {
    private let ctx = WorkflowContext(appBundleId: "com.example.app")

    /// Generation parity ⇒ no drift ⇒ §5 is a strict no-op even when
    /// the current policy *would* deny. The cascade reaches its normal
    /// terminal decision (`.allow` here: known-safe + AX non-secure).
    func testNoDriftIsNoOpEvenIfCurrentPolicyWouldDeny() {
        let c = driftCascade(installedGen: 7, currentGen: 7, deniesCurrent: true)
        XCTAssertEqual(c.decide(context: ctx), .allow)
    }

    /// Drift + current policy denies the live context ⇒ §5 suppresses
    /// with `.denylistPostCapture` (NOT `.denylistSource` — the
    /// post-capture backstop fired, not the source filter). This is
    /// the gap §5 closes.
    func testDriftPlusCurrentPolicyDenySuppressesPostCapture() {
        let c = driftCascade(installedGen: 1, currentGen: 2, deniesCurrent: true)
        XCTAssertEqual(
            c.decide(context: ctx),
            .suppress(reason: .denylistPostCapture)
        )
    }

    /// Drift present but the current policy does NOT deny the live
    /// context ⇒ §5 does not fire. Drift alone is not suppression;
    /// only a current-policy match in the drift window is.
    func testDriftWithoutCurrentPolicyDenyDoesNotFire() {
        let c = driftCascade(installedGen: 1, currentGen: 9, deniesCurrent: false)
        XCTAssertEqual(c.decide(context: ctx), .allow)
    }

    /// First-match-wins: §1 source-level denylist fires before §5 even
    /// when drift + current-policy-deny would also fire. Reason must
    /// be `.denylistSource`.
    func testSourceDenylistFiresBeforeDriftBackstop() {
        let c = driftCascade(
            installedGen: 1,
            currentGen: 2,
            deniesCurrent: true,
            denyApps: ["com.example.app"]
        )
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .denylistSource))
    }

    /// Cascade order: §3 secure-event-input fires before the §5 drift
    /// backstop. Reason must be `.secureEventInput`.
    func testSecureEventInputFiresBeforeDriftBackstop() {
        let c = driftCascade(
            installedGen: 1,
            currentGen: 2,
            deniesCurrent: true,
            secureEventInput: true
        )
        XCTAssertEqual(c.decide(context: ctx), .suppress(reason: .secureEventInput))
    }

    /// Regression guard: the default `NoDenylistDrift` sentinel (used
    /// by every pre-existing construction) reports generation parity,
    /// so §5 can never fire — prior cascade behavior is preserved.
    func testDefaultSentinelNeverFiresSection5() {
        let c = cascade(knownSafe: ["com.example.app"])
        XCTAssertEqual(c.decide(context: ctx), .allow)
    }
}
