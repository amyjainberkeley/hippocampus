// SPDX-License-Identifier: TBD-private
//
// SuppressionCascadeAllowlistTests — integration between the bundled
// `known-safe-apps.toml` seed and `SuppressionCascade`'s §1 source-
// level allow path. Pins the ADR-0017 §3.1 invariant: the CSO-ratified
// allowlist STRICTLY ADDS `.allow` decisions and cannot widen past any
// §2-§7 redaction signal.
//
// PROTECTED-SET per AGENT_PROTOCOL §5.

import XCTest

@testable import MCICaptureHelperKit

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
    func appIsDenied(bundleId: String) -> Bool { apps.contains(bundleId) }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private func cascadeWithBundledAllowlist(
    secureEventInput: Bool = false,
    ax: Bool? = false,
    blackedRegion: Bool = false,
    denyApps: Set<String> = []
) throws -> SuppressionCascade {
    let allowlist = try AllowlistTOMLLoader.loadBundled()
    return SuppressionCascade(
        secureEventInput: MockSecureEventInput(enabled: secureEventInput),
        axSecureSubrole: MockAX(result: ax),
        denylist: MockDenylist(apps: denyApps),
        blackedRegion: MockBlackedRegion(present: blackedRegion),
        knownSafeAppBundles: allowlist.bundleIdSet
    )
}

final class SuppressionCascadeAllowlistTests: XCTestCase {
    /// Required scenario (task spec): allowlist + Safari + AX non-secure
    /// + no other redaction signals ⇒ `.allow`. This is the one path
    /// that turns the brain on for a demo.
    func testSafariContextWithAllowlistAllowsWhenAxNonSecure() throws {
        let cascade = try cascadeWithBundledAllowlist()
        let ctx = WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: "Wikipedia",
            url: "https://en.wikipedia.org/wiki/Memory"
        )
        XCTAssertEqual(cascade.decide(context: ctx), .allow)
    }

    /// Required scenario (task spec): allowlist + unknown app + no
    /// other redaction signals ⇒ `.suppress(reason=.failsafeUnknown)`.
    /// The default cascade behavior is preserved verbatim for
    /// non-ratified surfaces.
    func testUnknownAppFailsClosedWithFailsafeReason7() throws {
        let cascade = try cascadeWithBundledAllowlist()
        let ctx = WorkflowContext(appBundleId: "com.example.UnknownApp")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .failsafeUnknown)
        )
    }

    /// Required scenario (task spec): allowlist + Safari + secure-event
    /// -input true ⇒ `.suppress(reason=.secureEventInput)`. §3 wins
    /// over the allowlist — the fail-closed direction is preserved.
    func testSecureEventInputOverridesAllowlist() throws {
        let cascade = try cascadeWithBundledAllowlist(secureEventInput: true)
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .secureEventInput)
        )
    }

    /// Defense-in-depth: §4 AX secure subrole also wins over the
    /// allowlist. Any redaction signal in §2-§7 STRICTLY beats the
    /// per-bundle allow gate.
    func testAXSecureSubroleOverridesAllowlist() throws {
        let cascade = try cascadeWithBundledAllowlist(ax: true)
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .axSecureSubrole)
        )
    }

    /// §2 OS-blacked-region also wins over the allowlist (FairPlay /
    /// `NSWindowSharingType=.none`). Allowlist is per-bundle; §2 is
    /// per-frame and never relaxed.
    func testBlackedRegionOverridesAllowlist() throws {
        let cascade = try cascadeWithBundledAllowlist(blackedRegion: true)
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .osBlackedRegion)
        )
    }

    /// §1 user-denylist STILL fires when a bundle is on BOTH the
    /// user denylist and the CSO allowlist. The user's deny intent
    /// wins. (This shape is hypothetical — the bundled seed is
    /// CSO-curated and users in v1 can only ADD to the denylist —
    /// but the cascade order guarantees it.)
    func testDenylistOverridesAllowlist() throws {
        let cascade = try cascadeWithBundledAllowlist(
            denyApps: ["com.apple.Safari"]
        )
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .denylistSource)
        )
    }

    /// Every bundle in the seed allows when AX returns non-secure and
    /// no redaction signal fires. Sweeps the full ratified set so a
    /// later allowlist-population PR cannot silently break per-bundle
    /// allow for an existing ratified surface.
    func testEveryBundledSeedBundleAllowsWhenAxNonSecure() throws {
        let cascade = try cascadeWithBundledAllowlist()
        let allowlist = try AllowlistTOMLLoader.loadBundled()
        for bundleId in allowlist.bundleIdSet {
            let ctx = WorkflowContext(appBundleId: bundleId)
            XCTAssertEqual(
                cascade.decide(context: ctx),
                .allow,
                "Ratified bundle \(bundleId) should allow when AX is non-secure"
            )
        }
    }

    /// AX silent (`nil`) on a ratified bundle STILL fails closed. The
    /// allow path requires a POSITIVE AX classification, not merely
    /// "ratified app + silent AX." Pins the ADR-0013 §3 fail-safe
    /// invariant against an allowlist-induced regression.
    func testAxSilentOnRatifiedBundleStillFailsClosed() throws {
        let cascade = try cascadeWithBundledAllowlist(ax: nil)
        let ctx = WorkflowContext(appBundleId: "com.apple.Safari")
        XCTAssertEqual(
            cascade.decide(context: ctx),
            .suppress(reason: .failsafeUnknown)
        )
    }
}
