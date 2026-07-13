// TierGateTests.swift — pin the freemium tier gate contract (cycle 8.48).
// See `docs/business/tier-structure.md` for the trust invariants.

import XCTest
@testable import RecallUIKit

final class TierGateTests: XCTestCase {

    func testDefaultTierIsFree() {
        // Trust invariant #1 — the shared manager MUST start on `.free`.
        // Changing this default gates v1.0 features (CEO + CSO sign-off).
        XCTAssertEqual(TierManager.shared.current, .free)
    }

    func testTierOrdering() {
        // Enterprise > Pro > Free. `hasProAccess` depends on it.
        XCTAssertLessThan(Tier.free, Tier.pro)
        XCTAssertLessThan(Tier.pro, Tier.enterprise)
    }

    func testHasProAccessOnFree() {
        XCTAssertFalse(TierManager.shared.hasProAccess)
    }

    func testGrandfatheredClosureRunsOnFree() {
        // Every v1.0 call site is grandfathered; runs on Free.
        var ran = false
        TierGate.ifPro { ran = true }
        XCTAssertTrue(ran, "grandfathered gate must run on Free tier")
    }

    func testNonGrandfatheredClosureDoesNotRunOnFree() {
        // Future Pro-only features pass `grandfathered: false` — dormant on Free.
        var ran = false
        let result: Int? = TierGate.isPro(grandfathered: false) {
            ran = true
            return 42
        }
        XCTAssertFalse(ran, "non-grandfathered gate must NOT run on Free")
        XCTAssertNil(result)
    }

    func testDisplayLabels() {
        XCTAssertEqual(Tier.free.displayLabel, "Free forever")
        XCTAssertEqual(Tier.pro.displayLabel, "Pro")
        XCTAssertEqual(Tier.enterprise.displayLabel, "Enterprise")
    }
}
