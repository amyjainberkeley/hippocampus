import XCTest
@testable import RecallUIKit

@MainActor
final class ScreenshotRereadTests: XCTestCase {
    private func hit(_ id: UInt64) -> Hit {
        Hit(eventId: id, tsUs: id, appBundleId: "test.app", windowTitle: "Synthetic notes", url: nil,
            ocrTextSnippet: "original stored text", source: "timeline", score: nil,
            thumbnailPath: "/synthetic/\(id).bin", sourceKind: "screen_ocr")
    }

    func testReReadDoesNotOverwriteOriginalAndCopyIsExplicit() async {
        let evidence = hit(1)
        let reader = RereadReader(hits: [evidence])
        let service = RereadService()
        let model = ScreenshotRereadViewModel(service: service)
        XCTAssertEqual(model.state(for: evidence), .idle)
        await model.start(hit: evidence, reader: reader).value
        XCTAssertEqual(model.state(for: evidence), .finished(.text("new local reading", omittedLines: 2)))
        XCTAssertEqual(evidence.ocrTextSnippet, "original stored text")
        let copy = await model.copyText(for: evidence, reader: reader)
        XCTAssertEqual(copy, "new local reading")
        await reader.removeAll()
        let removed = await model.copyText(for: evidence, reader: reader)
        XCTAssertNil(removed)
        XCTAssertEqual(model.state(for: evidence), .idle)
    }

    func testOldRequestCannotPublishIntoNewSelectionEvenIfServiceIgnoresCancellation() async {
        let started = expectation(description: "first OCR started")
        let service = RereadService(started: started)
        let reader = RereadReader(hits: [hit(1), hit(2)])
        let model = ScreenshotRereadViewModel(service: service)
        let old = model.start(hit: hit(1), reader: reader)
        await fulfillment(of: [started], timeout: 2)
        await model.start(hit: hit(2), reader: reader).value
        await service.finish()
        await old.value
        XCTAssertEqual(model.state(for: hit(1)), .idle)
        XCTAssertEqual(model.state(for: hit(2)), .finished(.text("new local reading", omittedLines: 2)))
    }

    func testDeletionDuringRecognitionAndDismissalClearAllOutput() async {
        let evidence = hit(1)
        let started = expectation(description: "OCR started")
        let service = RereadService(started: started)
        let reader = RereadReader(hits: [evidence])
        let model = ScreenshotRereadViewModel(service: service)
        let run = model.start(hit: evidence, reader: reader)
        await fulfillment(of: [started], timeout: 2)
        await reader.removeAll()
        await service.finish()
        await run.value
        XCTAssertEqual(model.state(for: evidence), .finished(.unavailable))
        model.clear()
        XCTAssertEqual(model.state(for: evidence), .idle)
    }

    func testUnreadableAndTimeoutAreNotReportedAsSuccess() async {
        let evidence = hit(1)
        for outcome in [ScreenshotRereadOutcome.unreadable, .timedOut, .blocked, .unavailable] {
            let model = ScreenshotRereadViewModel(service: RereadService(outcome: outcome))
            let reader = RereadReader(hits: [evidence])
            await model.start(hit: evidence, reader: reader).value
            XCTAssertEqual(model.state(for: evidence), .finished(outcome))
            let copy = await model.copyText(for: evidence, reader: reader)
            XCTAssertNil(copy)
        }
    }
}

private actor RereadService: ScreenshotRereading {
    let started: XCTestExpectation?
    let outcome: ScreenshotRereadOutcome
    var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation? = nil, outcome: ScreenshotRereadOutcome = .text("new local reading", omittedLines: 2)) {
        self.started = started
        self.outcome = outcome
    }
    func read(url: URL) async -> ScreenshotRereadOutcome {
        if started != nil, url.lastPathComponent == "1.bin" {
            await withCheckedContinuation { continuation = $0; started?.fulfill() }
        }
        return outcome
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor RereadReader: BrainReader {
    var hits: [Hit]
    init(hits: [Hit]) { self.hits = hits }
    func removeAll() { hits = [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { hits.filter { ids.contains($0.id) } }
    func search(_ options: SearchOptions) async throws -> [Hit] { [] }
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
