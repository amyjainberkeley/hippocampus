import XCTest
@testable import RecallUIKit

final class DailyMemoryTests: XCTestCase {
    func testProductionWireDecodersKeepAcquisitionSeparateFromRetrievalAndDefaultUnknown() throws {
        let json = """
        {"event_id":42,"ts_us":100,"ocr_text_snippet":"Imported text",
         "source":"lexical","source_kind":"transcript_import"}
        """
        let hit = try JSONDecoder().decode(HitWire.self, from: Data(json.utf8)).toHit()
        XCTAssertEqual(hit.source, "lexical")
        XCTAssertEqual(hit.sourceKind, "transcript_import")
        XCTAssertEqual(MemorySourceKind.label(hit.sourceKind), "Imported transcript")
        let legacy = try JSONDecoder().decode(HitWire.self, from: Data("{\"event_id\":1,\"ts_us\":0,\"ocr_text_snippet\":\"old\",\"source\":\"timeline\"}".utf8)).toHit()
        XCTAssertNil(legacy.sourceKind)
        XCTAssertEqual(MemorySourceKind.label(legacy.sourceKind), "Unknown source")
        let timeline = try JSONDecoder().decode(TimelineEventWire.self, from: Data("{\"event_id\":1,\"ts_us\":0,\"snippet\":\"screen\",\"source_kind\":\"screen_ocr\"}".utf8)).toTimelineEvent()
        XCTAssertEqual(timeline.sourceKind, "screen_ocr")
        XCTAssertEqual(MemorySourceKind.label("future_source"), "Unknown source")
    }

    func testLocalDayUsesCalendarBoundariesAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let day = MemoryDay(date: date, calendar: calendar)
        XCTAssertEqual(day.dateLocal, "2026-03-08")
        XCTAssertEqual(day.endUs - day.startUs + 1, 23 * 3_600_000_000)
        XCTAssertTrue(day.contains(day.startUs))
        XCTAssertTrue(day.contains(day.endUs))
        XCTAssertFalse(day.contains(day.endUs + 1))
    }

    func testVisualEpisodesExcludeImportsAndSplitAppChangesAndLongGaps() {
        let events = [
            event(1, seconds: 0), event(2, seconds: 60),
            event(3, seconds: 90, screenshot: false),
            event(4, seconds: 120, app: "com.apple.Terminal"),
            event(5, seconds: 180), event(6, seconds: 900),
        ]
        let episodes = VisualMemoryEpisode.group(events.reversed())
        XCTAssertEqual(episodes.map { $0.events.map(\.id) }, [[1, 2], [4], [5], [6]])
        XCTAssertEqual(episodes.reduce(0) { $0 + $1.observedSeconds }, 60)
    }

    func testWhitespacePathIsNotAScreenshot() {
        let row = TimelineEvent(eventId: 1, tsUs: 0, appBundleId: nil, snippet: "OCR", thumbnailPath: "  ")
        XCTAssertFalse(row.hasScreenshot)
    }

    func testExportCitesOnlySelectedEvidenceAndMarksSnippetLimits() {
        let hit = Hit(eventId: 42, tsUs: 1_700_000_000_000_000,
                      appBundleId: "com.apple.Safari", windowTitle: "A page",
                      url: "https://example.com", ocrTextSnippet: "Stored text",
                      source: "timeline", score: nil, thumbnailPath: "/private/blob.bin")
        let packet = VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])
        XCTAssertTrue(packet.contains("hippocampus://recall?tab=search&focus=42"))
        XCTAssertTrue(packet.contains("https://example.com"))
        XCTAssertTrue(packet.contains("Stored text"))
        XCTAssertTrue(packet.contains("snippet"))
        XCTAssertFalse(packet.contains("/private/blob.bin"))
    }

    func testCaptureReceiptRejectsInvalidSchemaAndCountsAndHandlesFractionalSeconds() throws {
        let json = """
        {"schema_version":1,"updated_at":"2026-09-05T12:00:00.125Z",
        "last_stored_frame_at":"2026-09-05T11:59:58Z","stored_frame_count":8,
        "stored_screenshot_count":3,"suppression_reason":null,"blocked_reason":null}
        """
        let receipt = try CaptureHealthReceipt.decode(Data(json.utf8))
        XCTAssertEqual(receipt.storedScreenshotCount, 3)
        XCTAssertNotNil(receipt.lastStoredFrameAt)
        XCTAssertTrue(receipt.isStale(now: receipt.updatedAt.addingTimeInterval(120)))
        XCTAssertFalse(receipt.isStale(now: receipt.updatedAt.addingTimeInterval(10)))
        XCTAssertThrowsError(try CaptureHealthReceipt.decode(Data(json.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2").utf8)))
        XCTAssertThrowsError(try CaptureHealthReceipt.decode(Data(json.replacingOccurrences(of: "\"stored_frame_count\":8", with: "\"stored_frame_count\":-1").utf8)))
    }

    private func event(_ id: UInt64, seconds: UInt64, app: String = "com.apple.Safari", screenshot: Bool = true) -> TimelineEvent {
        TimelineEvent(eventId: id, tsUs: seconds * 1_000_000, appBundleId: app,
                      snippet: "Stored text", thumbnailPath: screenshot ? "/tmp/\(id).bin" : nil)
    }
}

@MainActor
final class DailyMemoryViewModelTests: XCTestCase {
    func testRefreshReadsNewScreenshotsAndBriefFailureDoesNotHideThem() async {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        await model.reload()
        XCTAssertEqual(model.screenshots.map(\.id), [1])
        await reader.set(eventID: 2, briefFails: true)
        await model.reload()
        XCTAssertEqual(model.screenshots.map(\.id), [2])
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.briefError)
        XCTAssertNotNil(model.refreshedAt)
        XCTAssertFalse(model.isLoading)
    }

    func testLatePreviousDayReadCannotOverwriteSelectedDay() async {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        let previousDay = model.day
        await reader.delay(start: previousDay.startUs)
        let oldRequest = Task { await model.reload() }
        await reader.waitForDelayedRead()
        model.moveDay(-1)
        let selectedDay = model.day
        await reader.set(eventID: 2)
        await model.reload()
        await reader.finishDelayedRead()
        await oldRequest.value
        XCTAssertEqual(model.events.map(\.id), [2])
        XCTAssertTrue(model.events.allSatisfy { selectedDay.contains($0.tsUs) })
        XCTAssertFalse(model.isLoading)
    }

    func testDaySearchUsesDatabaseBoundsAndExcludesTextOnlyResults() async {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        model.query = "stored text"
        await model.search()
        XCTAssertEqual(model.searchHits.map(\.id), [2])
        XCTAssertEqual(model.visibleScreenshots.first?.snippet, "Stored text")
        let options = await reader.lastSearch
        XCTAssertEqual(options?.text, "stored text")
        XCTAssertEqual(options?.timeFromUs, model.day.startUs)
        XCTAssertEqual(options?.timeToUs, model.day.endUs)
        model.query = ""
        await model.search()
        XCTAssertTrue(model.searchHits.isEmpty)
        XCTAssertFalse(model.isSearching)
    }
}

private actor DailyTestReader: BrainReader {
    var eventID: UInt64 = 1
    var briefFails = false
    var lastSearch: SearchOptions?
    var delayedStart: UInt64?
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var hasStarted = false

    func set(eventID: UInt64, briefFails: Bool = false) {
        self.eventID = eventID
        self.briefFails = briefFails
    }
    func delay(start: UInt64) { delayedStart = start }
    func waitForDelayedRead() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishDelayedRead() { pending?.resume(); pending = nil }

    func timelineEvents(startTsUs: UInt64, endTsUs: UInt64, resolution: TimelineResolution) async throws -> [TimelineEvent] {
        let id = eventID
        if delayedStart == startTsUs {
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { pending = $0 }
        }
        return [TimelineEvent(eventId: id, tsUs: startTsUs, appBundleId: "com.apple.Safari",
                              snippet: "Stored text", thumbnailPath: "/tmp/\(id).bin", sourceKind: "screen_ocr")]
    }
    func search(_ opts: SearchOptions) async throws -> [Hit] {
        lastSearch = opts
        return [
            Hit(eventId: 1, tsUs: opts.timeFromUs!, appBundleId: nil, windowTitle: nil,
                url: nil, ocrTextSnippet: "Stored text", source: "lexical", score: nil),
            Hit(eventId: 2, tsUs: opts.timeFromUs!, appBundleId: nil, windowTitle: nil,
                url: nil, ocrTextSnippet: "[app=editor | title=title | url=? | ts=now]\nStored text",
                source: "lexical", score: nil, thumbnailPath: "/tmp/2.bin"),
            Hit(eventId: 3, tsUs: opts.timeToUs! + 1, appBundleId: nil, windowTitle: nil,
                url: nil, ocrTextSnippet: "Stored text", source: "lexical", score: nil, thumbnailPath: "/tmp/3.bin"),
        ]
    }
    func briefForDate(_ dateLocal: String) async throws -> Brief? {
        if briefFails { throw BrainReaderError.queryFailed("fixture") }
        return nil
    }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
