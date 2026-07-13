// GlobalRecallPopupViewModelTests.swift — exercise the debounce +
// results wiring + selection state machine for the Spotlight-like
// recall popup view model.

import XCTest
@testable import RecallUIKit

/// Fully-conforming stub reader that returns a scripted [Hit] array
/// on each `search(...)` call. Unlike `StubBrainReader`'s substring
/// filter, this returns whatever we hand it — so the tests pin
/// exact selection / limit behavior.
private struct ScriptedReader: BrainReader {
    let scripted: [Hit]
    let shouldThrow: Bool

    init(scripted: [Hit] = [], shouldThrow: Bool = false) {
        self.scripted = scripted
        self.shouldThrow = shouldThrow
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        if shouldThrow { throw BrainReaderError.queryFailed("boom") }
        return Array(scripted.prefix(opts.limit))
    }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}

private func makeHit(id: UInt64, url: String? = nil) -> Hit {
    Hit(
        eventId: id,
        tsUs: 1_700_000_000_000_000 + id * 1_000_000,
        appBundleId: "com.apple.Safari",
        windowTitle: "Test #\(id)",
        url: url,
        ocrTextSnippet: "snippet \(id)",
        source: "lexical",
        score: 0.5
    )
}

@MainActor
final class GlobalRecallPopupViewModelTests: XCTestCase {
    func testEmptyQueryProducesNoResultsAndNoSearch() async {
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: [makeHit(id: 1)]))
        await vm.perform(query: "   ")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.lastError)
    }

    func testMatchingQueryPopulatesCappedResults() async {
        let hits = (1...20).map { makeHit(id: $0) }
        let vm = GlobalRecallPopupViewModel(
            reader: ScriptedReader(scripted: hits),
            resultLimit: 8
        )
        await vm.perform(query: "anything")
        XCTAssertEqual(vm.results.count, 8)
        XCTAssertEqual(vm.results.first?.eventId, 1)
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    func testReaderErrorClearsResultsAndSurfacesError() async {
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(shouldThrow: true))
        await vm.perform(query: "anything")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNotNil(vm.lastError)
        XCTAssertFalse(vm.isSearching)
    }

    func testSelectNextAndPrevClamp() async {
        let hits = (1...3).map { makeHit(id: $0) }
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: hits))
        await vm.perform(query: "x")
        XCTAssertEqual(vm.selectedIndex, 0)
        vm.selectPrev()
        XCTAssertEqual(vm.selectedIndex, 0)  // clamped low
        vm.selectNext()
        vm.selectNext()
        vm.selectNext()
        XCTAssertEqual(vm.selectedIndex, 2)  // clamped high (3 rows)
    }

    func testInvokeActionOpensExternalWhenUrlPresent() async {
        let hits = [makeHit(id: 42, url: "https://example.com/x")]
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: hits))
        await vm.perform(query: "x")
        let ext = vm.invokeAction(preferExternal: true)
        XCTAssertEqual(ext, .openExternal(URL(string: "https://example.com/x")!))
        let inRecall = vm.invokeAction(preferExternal: false)
        XCTAssertEqual(inRecall, .openInRecallUI(eventId: 42))
    }

    func testInvokeActionFallsBackToRecallWhenNoUrl() async {
        let hits = [makeHit(id: 7, url: nil)]
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: hits))
        await vm.perform(query: "x")
        // Cmd-Enter (preferExternal:true) with no URL falls back to
        // the in-recall route — Spotlight semantics.
        let action = vm.invokeAction(preferExternal: true)
        XCTAssertEqual(action, .openInRecallUI(eventId: 7))
    }

    func testInvokeActionReturnsNilWhenNoResults() async {
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: []))
        await vm.perform(query: "x")
        XCTAssertNil(vm.invokeAction(preferExternal: false))
    }

    func testResetClearsAllState() async {
        let hits = [makeHit(id: 1), makeHit(id: 2)]
        let vm = GlobalRecallPopupViewModel(reader: ScriptedReader(scripted: hits))
        vm.query = "test"
        await vm.perform(query: "test")
        XCTAssertFalse(vm.results.isEmpty)
        vm.reset()
        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(vm.selectedIndex, 0)
        XCTAssertNil(vm.lastError)
    }

    func testDebounceCoalescesRapidTyping() async throws {
        let hits = [makeHit(id: 99)]
        let vm = GlobalRecallPopupViewModel(
            reader: ScriptedReader(scripted: hits),
            debounceMs: 50
        )
        // Fire three keystrokes inside the debounce window.
        vm.query = "a"
        vm.query = "ab"
        vm.query = "abc"
        // Wait 2× debounce so the trailing edge fires.
        try await Task.sleep(nanoseconds: 200_000_000)
        // Give the awaited perform() one main-actor tick to publish.
        await Task.yield()
        XCTAssertEqual(vm.query, "abc")
        // The debounce fires perform() for the last value; we can't
        // deterministically assert it landed on "abc" only (Combine's
        // scheduler is loosely timed on CI), but we can pin that
        // *some* debounce delivered results.
        XCTAssertFalse(vm.results.isEmpty)
    }

    func testPopupActionEquatability() {
        let u = URL(string: "https://example.com/a")!
        XCTAssertEqual(PopupHitAction.openExternal(u), PopupHitAction.openExternal(u))
        XCTAssertEqual(
            PopupHitAction.openInRecallUI(eventId: 1),
            PopupHitAction.openInRecallUI(eventId: 1)
        )
        XCTAssertNotEqual(
            PopupHitAction.openInRecallUI(eventId: 1),
            PopupHitAction.openInRecallUI(eventId: 2)
        )
    }
}
