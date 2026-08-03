// BriefDeepLinkRoutingTests.swift — pin the `hippocampus://recall?tab=…`
// → `Tab` routing per `docs/design/brief-viewer-spec.md`.

import XCTest
@testable import RecallUIKit

final class BriefDeepLinkRoutingTests: XCTestCase {

    // MARK: known values

    func testKnownDeepLinkValuesRouteToTheRightTab() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "brief"),    .brief)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "search"),   .search)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "timeline"), .timeline)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "privacy"),  .privacy)
    }

    func testDeepLinkValueIsCaseInsensitive() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "BRIEF"), .brief)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "Brief"), .brief)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "bRiEf"), .brief)
    }

    // MARK: unknown values fall through

    func testUnknownDeepLinkValuesReturnNil() {
        XCTAssertNil(RecallTab.from(deepLinkValue: ""))
        XCTAssertNil(RecallTab.from(deepLinkValue: "nope"))
        XCTAssertNil(RecallTab.from(deepLinkValue: "0"))
        // "settings" used to be listed here. It is a real tab now
        // (RecallTab.settings, wired in Tab.swift), so asserting it routes
        // to nil is wrong. This test never compiled, so nobody caught it.
        XCTAssertEqual(RecallTab.from(deepLinkValue: "settings"), .settings)
    }

    // MARK: env-var name is stable

    func testInitialTabEnvVarKeyIsStable() {
        // Hippocampus.app's ProcessSupervisor passes this exact key when
        // spawning the recall-ui executable; changing it without updating
        // the supervisor would silently break deep-linking.
        XCTAssertEqual(RecallTab.initialTabEnvVar, "MCI_INITIAL_TAB")
    }

    // MARK: URL parsing the way HippocampusApp.application(_, open:) does

    func testEndToEndUrlParsingMatchesTabBrief() {
        let url = URL(string: "hippocampus://recall?tab=brief")!
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tab" }?
            .value
        let tab: RecallTab? = raw.flatMap { RecallTab.from(deepLinkValue: $0) }
        XCTAssertEqual(tab, .brief)
    }

    func testEndToEndUrlParsingNoTabQueryReturnsNil() {
        let url = URL(string: "hippocampus://recall")!
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tab" }?
            .value
        let tab: RecallTab? = raw.flatMap { RecallTab.from(deepLinkValue: $0) }
        XCTAssertNil(tab)
    }
}
