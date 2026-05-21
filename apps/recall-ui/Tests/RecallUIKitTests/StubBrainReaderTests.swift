// StubBrainReaderTests.swift — pin the canned-data shape so SwiftUI
// scenes render predictably and downstream view-model tests have a
// stable input corpus.

import XCTest
@testable import RecallUIKit

final class StubBrainReaderTests: XCTestCase {
    func testDemoHitsAreThreeRows() {
        XCTAssertEqual(StubBrainReader.demoHits.count, 3)
    }

    func testDemoPrivacyMomentsAreThreeRows() {
        XCTAssertEqual(StubBrainReader.demoPrivacyMoments.count, 3)
    }

    func testRecentEventsReturnsMostRecentFirst() async throws {
        let r = StubBrainReader()
        let out = try await r.recentEvents(limit: 10)
        XCTAssertEqual(out.count, 3)
        // demoHits[2] is the newest by tsUs.
        XCTAssertEqual(out.first?.eventId, 103)
        XCTAssertEqual(out.last?.eventId, 101)
    }

    func testRecentEventsRespectsLimit() async throws {
        let r = StubBrainReader()
        let out = try await r.recentEvents(limit: 1)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.eventId, 103)
    }

    func testRecentEventsZeroLimitReturnsEmpty() async throws {
        let r = StubBrainReader()
        let out = try await r.recentEvents(limit: 0)
        XCTAssertTrue(out.isEmpty)
    }

    func testSearchEmptyQueryReturnsEmpty() async throws {
        let r = StubBrainReader()
        let out = try await r.search(SearchOptions(text: "", limit: 50))
        XCTAssertTrue(out.isEmpty)
    }

    func testSearchSubstringMatchesSnippet() async throws {
        let r = StubBrainReader()
        let out = try await r.search(SearchOptions(text: "privacy", limit: 50))
        // Matches both demoHits[0] (snippet + title) and nothing else.
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.eventId, 101)
    }

    func testSearchIsCaseInsensitive() async throws {
        let r = StubBrainReader()
        let upper = try await r.search(SearchOptions(text: "PRIVACY", limit: 50))
        let lower = try await r.search(SearchOptions(text: "privacy", limit: 50))
        XCTAssertEqual(upper.map(\.eventId), lower.map(\.eventId))
    }

    func testSearchMatchesUrl() async throws {
        let r = StubBrainReader()
        let out = try await r.search(SearchOptions(text: "apple.com", limit: 50))
        XCTAssertEqual(out.first?.eventId, 101)
    }

    func testRecentPrivacyMomentsReturnsMostRecentFirst() async throws {
        let r = StubBrainReader()
        let out = try await r.recentPrivacyMoments(limit: 10)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.first?.reasonCode, 7) // nil-app catchall, newest ts
    }
}
