// SPDX-License-Identifier: TBD-private
//
// ConcreteProbesTests — exercises the concrete OS-API probes that
// implement the ADR-0013 cascade input protocols.
//
// Scope honesty: the production code calls live OS APIs. The test
// runner itself is an `xctest` process WITHOUT the AX entitlement
// granted via System Settings, so AX queries return `.apiDisabled`
// and the probe correctly answers `nil` (cascade fail-safe path).
// `IsSecureEventInputEnabled()` is a system-wide bit — when no
// secure-input-active app is in the foreground (CI / dev shell)
// it returns `false`. Both classes of behavior are predictable
// enough to assert below.

import XCTest

@testable import MCICaptureHelperKit

final class CarbonSecureEventInputProbeTests: XCTestCase {
    /// In a normal test process with no password field focused, the
    /// process-wide secure-event-input bit is false. The probe must
    /// reflect that. (If someone is somehow running the test suite
    /// while a 1Password vault is unlocking, this test is allowed to
    /// be flaky — but in CI / dev it pins behavior.)
    func testIsSecureEventInputDisabledInTestProcess() {
        let probe = CarbonSecureEventInputProbe()
        XCTAssertFalse(
            probe.isSecureEventInputEnabled(),
            "test process must not have secure event input enabled"
        )
    }

    /// Repeated calls return consistent results. The probe is supposed
    /// to be cheap and re-pollable on every state transition per
    /// ADR-0013 §3.
    func testRepeatedCallsAreStable() {
        let probe = CarbonSecureEventInputProbe()
        let a = probe.isSecureEventInputEnabled()
        let b = probe.isSecureEventInputEnabled()
        XCTAssertEqual(a, b)
    }

    /// The struct satisfies the protocol surface the cascade consumes.
    /// If anyone changes the protocol shape, this test stops compiling.
    func testConformsToProtocol() {
        let probe: any SecureEventInputProbe = CarbonSecureEventInputProbe()
        _ = probe.isSecureEventInputEnabled()
    }
}

final class AXSubroleProbeTests: XCTestCase {
    /// XCTest is not an AX-entitled binary, so AX queries return
    /// `.apiDisabled`. The probe MUST return `nil` for that case
    /// (cascade fail-safe) — never `false`, which would silently
    /// allow capture.
    func testReturnsNilWhenAXIsDisabled() {
        let probe = AXSubroleProbe()
        let result = probe.focusedHasSecureSubrole()
        XCTAssertNil(
            result,
            "AX disabled in xctest process; probe must return nil for fail-safe"
        )
    }

    /// Repeated calls return consistent results (`nil == nil`).
    func testRepeatedCallsAreStable() {
        let probe = AXSubroleProbe()
        let a = probe.focusedHasSecureSubrole()
        let b = probe.focusedHasSecureSubrole()
        XCTAssertEqual(a, b)
    }

    /// Protocol conformance gate.
    func testConformsToProtocol() {
        let probe: any AXSecureSubroleProbe = AXSubroleProbe()
        _ = probe.focusedHasSecureSubrole()
    }
}

final class ConcreteProbeIntegrationWithCascadeTests: XCTestCase {
    /// End-to-end: the concrete probes drive the production cascade
    /// orchestrator. With AX disabled (nil) + secure-event-input
    /// false + no denylist match + no blacked region, the cascade
    /// must redact via the fail-safe path. This is the binding
    /// ADR-0013 §7 invariant: unknown ⇒ redact.
    func testFailsafePathFiresWhenConcreteProbesAreUnclassified() {
        struct EmptyDenylist: DenylistProbe {
            func appIsDenied(bundleId _: String) -> Bool { false }
            func urlIsDenied(_: String) -> Bool { false }
            func windowTitleIsDenied(_: String) -> Bool { false }
        }
        struct NoBlackedRegion: BlackedRegionProbe {
            func hasBlackedRegion() -> Bool { false }
        }

        let cascade = SuppressionCascade(
            secureEventInput: CarbonSecureEventInputProbe(),
            axSecureSubrole: AXSubroleProbe(),
            denylist: EmptyDenylist(),
            blackedRegion: NoBlackedRegion(),
            knownSafeAppBundles: []  // empty allowlist
        )

        let ctx = WorkflowContext(
            appBundleId: "com.unknown.app",
            windowTitle: "Test window",
            url: nil
        )

        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .failsafeUnknown),
            "concrete probes + unknown app must hit cascade fail-safe"
        )
    }
}
