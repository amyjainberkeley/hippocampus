import XCTest
@testable import RecallUIKit

@MainActor
final class EventTextViewModelTests: XCTestCase {
    private func hit(_ id: UInt64, tsUs: UInt64 = 100, app: String? = nil) -> Hit {
        Hit(eventId: id, tsUs: tsUs, appBundleId: app, windowTitle: "Original metadata",
            url: nil, ocrTextSnippet: "original preview", source: "timeline", score: nil)
    }

    func testDeletionAndReplacementWithSameIdCannotPublishOrCopyUnderOriginalHit() async throws {
        let original = hit(1)
        let reader = ControlledEventTextReader()
        let vm = EventTextViewModel()
        await vm.load(hit: original, reader: reader)
        XCTAssertNotNil(vm.text(for: original))
        await reader.setMissing()
        await vm.load(hit: original, reader: reader)
        XCTAssertNil(vm.text(for: original))
        for (timestamp, app) in [(UInt64(200), nil), (UInt64(100), "test.replacement")] {
            await reader.replace(tsUs: timestamp, app: app)
            await vm.load(hit: original, reader: reader)
            XCTAssertEqual(vm.state(for: original), .unavailable)
            XCTAssertNil(vm.text(for: original))
            XCTAssertEqual(vm.copyText(for: original), original.ocrTextSnippet)
            XCTAssertEqual(vm.copyTitle(for: original), "Copy Snippet")
            let replacement = hit(1, tsUs: timestamp, app: app)
            await vm.load(hit: replacement, reader: reader)
            XCTAssertNotNil(vm.text(for: replacement))
            XCTAssertNil(vm.text(for: original), "same ID must not expose another snapshot's cached text")
        }
    }

    func testSameIdSnapshotChangeHidesCachedTextBeforeReloadStarts() async {
        let original = hit(1)
        let vm = EventTextViewModel()
        await vm.load(hit: original, reader: ControlledEventTextReader())
        XCTAssertNotNil(vm.text(for: original))
        for replacement in [hit(1, tsUs: 101), hit(1, app: "test.replacement")] {
            XCTAssertNil(vm.text(for: replacement))
            XCTAssertEqual(vm.state(for: replacement), .idle)
            XCTAssertEqual(vm.copyText(for: replacement), replacement.ocrTextSnippet)
        }
    }

    func testInFlightOldIdentityCannotReplaceSameIdNewSnapshot() async {
        let started = expectation(description: "old identity read started")
        let reader = ControlledEventTextReader(started: started)
        let vm = EventTextViewModel()
        let original = hit(1)
        let replacement = hit(1, tsUs: 200, app: "test.replacement")
        let old = Task { await vm.load(hit: original, reader: reader) }
        await fulfillment(of: [started], timeout: 2)
        await reader.replace(tsUs: 200, app: "test.replacement")
        await vm.load(hit: replacement, reader: reader)
        await reader.finish(failing: false)
        await old.value
        XCTAssertNotNil(vm.text(for: replacement))
        XCTAssertNil(vm.text(for: original))
    }

    func testReadsOnlySelectedEventOnDemandAndKeepsExactText() async throws {
        let reader = ControlledEventTextReader()
        let vm = EventTextViewModel()
        let initialCalls = await reader.calls
        XCTAssertTrue(initialCalls.isEmpty)
        XCTAssertEqual(vm.state(for: hit(1)), .idle)
        await vm.load(hit: hit(1), reader: reader)
        let calls = await reader.calls
        XCTAssertEqual(calls, [1])
        XCTAssertEqual(vm.text(for: hit(1))?.text, ControlledEventTextReader.body)
        XCTAssertGreaterThan(try XCTUnwrap(vm.text(for: hit(1))).text.count, 280)
        XCTAssertNil(vm.text(for: hit(2)), "selection must hide old text before its new task even starts")
        XCTAssertEqual(vm.state(for: hit(2)), .idle)
    }

    func testNilReaderAndCompatibilityDefaultAreUnavailable() async {
        let vm = EventTextViewModel()
        await vm.load(hit: hit(1), reader: nil)
        XCTAssertEqual(vm.state(for: hit(1)), .unavailable)
        await vm.load(hit: hit(101), reader: StubBrainReader())
        XCTAssertEqual(vm.state(for: hit(101)), .unavailable)
        XCTAssertNil(vm.text(for: hit(101)))
    }

    func testOlderSuccessAndFailureCannotReplaceNewerSelection() async {
        for failing in [false, true] {
            let started = expectation(description: "old read started")
            let reader = ControlledEventTextReader(started: started)
            let vm = EventTextViewModel()
            let old = Task { await vm.load(hit: hit(1), reader: reader) }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(vm.state(for: hit(1)), .loading)
            await vm.load(hit: hit(2), reader: reader)
            await reader.finish(failing: failing)
            await old.value
            XCTAssertEqual(vm.text(for: hit(2))?.eventId, 2)
            XCTAssertEqual(vm.text(for: hit(2))?.text, ControlledEventTextReader.body)
            XCTAssertNil(vm.text(for: hit(1)))
        }
    }

    func testSameIdReloadRejectsOlderGeneration() async {
        let started = expectation(description: "old read started")
        let reader = ControlledEventTextReader(started: started)
        let vm = EventTextViewModel()
        let old = Task { await vm.load(hit: hit(1), reader: reader) }
        await fulfillment(of: [started], timeout: 2)
        await vm.load(hit: hit(1), reader: reader)
        await reader.finish(failing: false)
        await old.value
        XCTAssertEqual(vm.text(for: hit(1))?.text, ControlledEventTextReader.body)
    }

    func testCanceledReadCannotPublishEvenWhenReaderIgnoresCancellation() async {
        let started = expectation(description: "read started")
        let reader = ControlledEventTextReader(started: started)
        let vm = EventTextViewModel()
        let task = Task { await vm.load(hit: hit(1), reader: reader) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await reader.finish(failing: false)
        await task.value
        XCTAssertNil(vm.text(for: hit(1)))
        XCTAssertEqual(vm.state(for: hit(1)), .idle)
    }

    func testClearReleasesLoadedTextAndInvalidatesInFlightRead() async {
        let started = expectation(description: "read started")
        let reader = ControlledEventTextReader(started: started)
        let vm = EventTextViewModel()
        let task = Task { await vm.load(hit: hit(1), reader: reader) }
        await fulfillment(of: [started], timeout: 2)
        vm.clear()
        await reader.finish(failing: false)
        await task.value
        XCTAssertEqual(vm.state(for: hit(1)), .idle)
        XCTAssertNil(vm.text(for: hit(1)))
        await vm.load(hit: hit(2), reader: reader)
        XCTAssertNotNil(vm.text(for: hit(2)))
        vm.clear()
        XCTAssertNil(vm.text(for: hit(2)))
    }

    func testDeletedTextClearsPreviouslyLoadedValue() async {
        let reader = ControlledEventTextReader()
        let vm = EventTextViewModel()
        await vm.load(hit: hit(1), reader: reader)
        XCTAssertNotNil(vm.text(for: hit(1)))
        await reader.setMissing()
        await vm.load(hit: hit(1), reader: reader)
        XCTAssertEqual(vm.state(for: hit(1)), .unavailable)
        XCTAssertNil(vm.text(for: hit(1)))
    }

    func testEmptyTextAndTruncationAreNotReplacedWithSnippet() async {
        let reader = ControlledEventTextReader(body: "", truncated: true)
        let vm = EventTextViewModel()
        await vm.load(hit: hit(1), reader: reader)
        XCTAssertEqual(vm.text(for: hit(1))?.text, "")
        XCTAssertEqual(vm.text(for: hit(1))?.isTruncated, true)
    }

    func testCurrentFailureIsDistinctFromMissingText() async {
        let started = expectation(description: "read started")
        let reader = ControlledEventTextReader(started: started)
        let vm = EventTextViewModel()
        let task = Task { await vm.load(hit: hit(1), reader: reader) }
        await fulfillment(of: [started], timeout: 2)
        await reader.finish(failing: true)
        await task.value
        XCTAssertEqual(vm.state(for: hit(1)), .failed)
        XCTAssertNil(vm.text(for: hit(1)))
    }

    func testCopyUsesExactStoredTextAndLabelsCappedTextHonestly() async {
        let hit = self.hit(1)
        let vm = EventTextViewModel()
        XCTAssertEqual(vm.copyTitle(for: hit), "Copy Snippet")
        XCTAssertEqual(vm.copyText(for: hit), Formatters.stripContextHeader(hit.ocrTextSnippet))
        let stored = "[app=fixture | title=Fixture]\n" + ControlledEventTextReader.body
        await vm.load(hit: hit, reader: ControlledEventTextReader(body: stored))
        XCTAssertEqual(vm.copyTitle(for: hit), "Copy Full Text")
        XCTAssertEqual(vm.copyText(for: hit), stored, "copy must not silently discard stored header text")
        await vm.load(hit: hit, reader: ControlledEventTextReader(body: "prefix", truncated: true))
        XCTAssertEqual(vm.copyTitle(for: hit), "Copy Shown Text")
        XCTAssertEqual(vm.copyText(for: hit), "prefix")
        let other = self.hit(2)
        XCTAssertEqual(vm.copyTitle(for: other), "Copy Snippet")
        XCTAssertEqual(vm.copyText(for: other), Formatters.stripContextHeader(other.ocrTextSnippet))
    }
}

// Control only the asynchronous boundary; all publication and stale guards
// run in the production model. No database or personal memory is opened.
private actor ControlledEventTextReader: BrainReader {
    static let body = String(repeating: "stored line\n", count: 60)
    let started: XCTestExpectation?
    let body: String
    let truncated: Bool
    var calls: [UInt64] = []
    var pending: CheckedContinuation<EventText?, Error>?
    var missing = false
    var tsUs: UInt64 = 100
    var app: String?

    init(started: XCTestExpectation? = nil, body: String = ControlledEventTextReader.body, truncated: Bool = false) {
        self.started = started
        self.body = body
        self.truncated = truncated
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        calls.append(eventId)
        if calls.count == 1, let started {
            return try await withCheckedThrowingContinuation {
                pending = $0
                started.fulfill()
            }
        }
        return missing ? nil : try EventText(eventId: eventId, tsUs: tsUs, appBundleId: app, text: body, isTruncated: truncated)
    }

    func finish(failing: Bool) {
        if failing {
            pending?.resume(throwing: BrainReaderError.queryFailed("private-fixture-marker"))
        } else {
            pending?.resume(with: Result { try EventText(eventId: 1, tsUs: 100, appBundleId: nil, text: "stale", isTruncated: false) })
        }
        pending = nil
    }

    func setMissing() { missing = true }
    func replace(tsUs: UInt64, app: String?) {
        missing = false
        self.tsUs = tsUs
        self.app = app
    }
    func search(_ opts: SearchOptions) async throws -> [Hit] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
