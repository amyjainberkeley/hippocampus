// HippocampusURLRouteTests — cycle 8.48. Verifies the pure parser
// that `HippocampusApp.application(_:open:)` uses to decide what to
// do with a `hippocampus://…` URL.
//
// The AppDelegate itself needs a real NSApplication run-loop to
// exercise; keeping the parse logic in `HippocampusURLRoute.parse`
// means we can test the routing decisions headlessly here.

import XCTest
@testable import HippocampusKit

final class HippocampusURLRouteTests: XCTestCase {

    // MARK: - Recall route (existing surfaces, regression-guarded)

    func testRecallWithoutTabQuery() {
        let url = URL(string: "hippocampus://recall")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .openRecall(tab: nil))
    }

    func testRecallWithTabQuery() {
        let url = URL(string: "hippocampus://recall?tab=brief")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .openRecall(tab: "brief"))
    }

    func testRecallWithPopupQuery() {
        // `popup=1` is consumed by the recall-ui process itself, not
        // the top-level shell — from HippocampusApp's perspective we
        // still just spawn the recall UI (tab: nil).
        let url = URL(string: "hippocampus://recall?popup=1")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .openRecall(tab: nil))
    }

    // MARK: - Onboarding route (cycle 8.48 — new)

    func testShowOnboardingPathForm() {
        // Canonical form — matches the Raycast-style path pattern.
        let url = URL(string: "hippocampus://onboarding/show")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .showOnboarding)
    }

    func testShowOnboardingQueryForm() {
        // Legacy form the cycle 8.46 Action Panel initially shipped.
        // Kept working so any older external caller doesn't break.
        let url = URL(string: "hippocampus://onboarding?show=1")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .showOnboarding)
    }

    func testOnboardingWithoutRecognizedPathOrQueryIsUnknown() {
        // `hippocampus://onboarding` by itself doesn't do anything —
        // requires the explicit `/show` or `?show=1`. Prevents a
        // stray future host from accidentally re-opening onboarding.
        let url = URL(string: "hippocampus://onboarding")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown)
    }

    // MARK: - Rejection cases

    func testForeignSchemeReturnsNil() {
        // AppKit may hand us URLs from other schemes registered
        // against the bundle (e.g. `onboarding://start?migration=…`).
        // Those aren't ours to route.
        let url = URL(string: "onboarding://start")!
        XCTAssertNil(HippocampusURLRoute.parse(url))
    }

    func testUnknownHostIsUnknownNotNil() {
        // Scheme is ours, host isn't. Distinct from a foreign scheme
        // so callers can log-and-ignore without swallowing bugs.
        let url = URL(string: "hippocampus://banana")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown)
    }
}
