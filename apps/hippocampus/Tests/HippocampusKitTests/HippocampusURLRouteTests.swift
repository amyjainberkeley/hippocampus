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

    func testPreferencesRecognizesEachExactSectionPath() throws {
        let sections: [(String, PreferencesSection)] = [
            ("general", .general), ("capture", .capture), ("sources", .sources),
            ("privacy", .privacy), ("advanced", .advanced), ("about", .about),
        ]
        for (path, section) in sections {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences/\(path)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .openPreferences(section: section), path)
        }
    }

    func testPreferencesRejectsUnknownAndNoncanonicalPaths() throws {
        for suffix in [
            "", "/", "/unknown", "/General", "/general/", "/general/extra",
            "//general", "/./general", "/privacy/../general", "/%67eneral",
            "/general%2F", "/general%00", "/general;capture", "/general%20",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences\(suffix)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, suffix)
        }
    }

    func testPreferencesRejectsQueriesAndFragmentsInsteadOfPerformingActions() throws {
        for suffix in [
            "?", "?section=capture", "?enable=1", "?install=claude",
            "?show=1", "?tab=privacy&capture=on", "#", "#capture",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences/sources\(suffix)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, suffix)
        }
    }

    func testPreferencesRejectsDecoratedAuthorities() throws {
        for authority in [
            "user@preferences", "user:password@preferences", "preferences:123",
            "preferences:", "%70references", "preferences.", "preferences.example.com",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://\(authority)/general"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, authority)
        }
    }

    // MARK: - Recall route (existing surfaces, regression-guarded)

    func testRecallWithoutTabQuery() {
        let url = URL(string: "hippocampus://recall")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
    }

    func testRecallWithTabQuery() {
        let url = URL(string: "hippocampus://recall?tab=brief")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: "brief", focusEventId: nil, openPopup: false)
        )
    }

    func testRecallWithPopupQuery() {
        let url = URL(string: "hippocampus://recall?popup=1")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: nil, focusEventId: nil, openPopup: true)
        )
    }

    func testRecallCarriesFocusedEvent() {
        let url = URL(string: "hippocampus://recall?tab=search&focus=42")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: "search", focusEventId: 42, openPopup: false)
        )
    }

    func testRecallRejectsZeroAndMalformedFocusValues() {
        let zero = URL(string: "hippocampus://recall?focus=0")!
        let malformed = URL(string: "hippocampus://recall?focus=not-a-number")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(zero),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
        XCTAssertEqual(
            HippocampusURLRoute.parse(malformed),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
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
