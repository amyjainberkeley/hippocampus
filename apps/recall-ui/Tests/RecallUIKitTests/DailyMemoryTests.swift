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
        XCTAssertTrue(packet.contains("https&#58;//example.com"))
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

    func testExportTreatsCapturedMarkdownAndMetadataAsLiteralBoundedData() {
        let hit = Hit(eventId: 42, tsUs: 100, appBundleId: "unknown\n## Forged app",
                      windowTitle: "Title\n## Forged heading", url: "javascript:alert(1)",
                      ocrTextSnippet: "![image](https://example.invalid/tracker)\n<script>run()</script>\n"
                        + String(repeating: "x", count: 200_000), source: "timeline", score: nil)
        let packet = VisualMemoryExport.markdown(title: "Day\n## Forged title", hits: [hit])
        XCTAssertFalse(packet.contains("\n## Forged"))
        XCTAssertFalse(packet.contains("![image]("))
        XCTAssertFalse(packet.contains("<script>"))
        XCTAssertFalse(packet.contains("javascript:"))
        XCTAssertLessThan(packet.utf8.count, 131_072)
        XCTAssertTrue(packet.contains("shortened"))
        XCTAssertTrue(packet.contains("Review before sharing"))
        XCTAssertTrue(packet.contains("focus=42"))
    }

    private func event(_ id: UInt64, seconds: UInt64, app: String = "com.apple.Safari", screenshot: Bool = true) -> TimelineEvent {
        TimelineEvent(eventId: id, tsUs: seconds * 1_000_000, appBundleId: app,
                      snippet: "Stored text", thumbnailPath: screenshot ? "/tmp/\(id).bin" : nil)
    }
}

@MainActor
final class DailyMemoryViewModelTests: XCTestCase {
    func testLegacyBriefOpensYesterdaysDateAndExpandsItsSavedDraft() async throws {
        let reader = DailyTestReader()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
        let model = DailyMemoryViewModel(reader: reader, selectedDate: today, calendar: calendar, healthLoader: { nil })
        await reader.setLatestBrief(date: "2026-09-06")
        await model.openLatestBrief()
        XCTAssertEqual(model.day.dateLocal, "2026-09-06")
        XCTAssertEqual(model.brief?.dateLocal, "2026-09-06")
        XCTAssertTrue(model.showsSavedDraft)
        model.moveDay(1)
        XCTAssertNil(model.brief)
        XCTAssertFalse(model.showsSavedDraft)
    }

    func testLateLatestBriefCannotOverrideManualDayNavigation() async {
        let reader = DailyTestReader()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
        let model = DailyMemoryViewModel(reader: reader, selectedDate: today, calendar: calendar, healthLoader: { nil })
        await reader.setLatestBrief(date: "2026-09-06")
        await reader.delayLatestBrief()
        let opening = Task { await model.openLatestBrief() }
        await reader.waitForDelayedRead()
        model.moveDay(-2)
        await reader.finishDelayedRead()
        await opening.value
        XCTAssertEqual(model.day.dateLocal, "2026-09-05")
        XCTAssertNil(model.brief)
        XCTAssertFalse(model.showsSavedDraft)
    }

    func testLatestBriefRejectsInvalidDateAndMissingDraftWithoutInventingContent() async {
        for date in [nil, "2026-02-30", "not-a-date"] as [String?] {
            let reader = DailyTestReader()
            let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
            if let date { await reader.setLatestBrief(date: date) }
            let originalDay = model.day
            await model.openLatestBrief()
            XCTAssertEqual(model.day, originalDay)
            XCTAssertNil(model.brief)
            XCTAssertFalse(model.showsSavedDraft)
            XCTAssertNotNil(model.briefError)
        }
    }

    func testFullTextReadCannotPublishAfterDeletionReuseOrDateChange() async throws {
        for change in ["deleted", "timestamp", "app", "source", "date"] {
            let reader = DailyTestReader()
            let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
            await model.reload()
            await reader.configureExport(day: model.day)
            try await model.prepareHandoff()
            await reader.delayText()
            let confirmation = Task { try await model.validatedHandoff() }
            await reader.waitForDelayedRead()
            if change == "deleted" { await reader.removeExportEvidence() }
            else if change == "date" { model.moveDay(-1) }
            else { await reader.reuseExportID(changing: change) }
            await reader.finishDelayedRead()
            do {
                _ = try await confirmation.value
                XCTFail("A full-text read cannot confirm evidence after \(change).")
            } catch {}
            XCTAssertNil(model.handoffPreview)
        }
    }

    func testMismatchedFullTextIdentityCannotReplaceSelectedBody() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        await reader.mismatchTextIdentity()
        do {
            try await model.prepareHandoff()
            XCTFail("Full text from another timestamp must be rejected.")
        } catch {}
        XCTAssertNil(model.handoffPreview)
    }

    func testDenseDayHandoffDoesNotInventCaptureGapsFromExcerptSpacing() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: Date(timeIntervalSince1970: 1_788_739_200), healthLoader: { nil })
        await reader.configureDenseDay(day: model.day)
        await model.reload()
        XCTAssertFalse(model.review.observations.contains { $0.kind == .captureGap })
        let packet = try await model.exportSummary()
        XCTAssertTrue(packet.contains("24 rechecked evidence excerpts"))
        XCTAssertFalse(packet.contains("## Capture gap"), "Sampling a minute-by-minute day must not invent a gap.")
        XCTAssertFalse(packet.contains("## Returned to"), "A sampled packet cannot reconstruct app visits.")
    }

    func testHandoffReadsBodyBeyondLongHeaderBeforeApplyingExcerptLimit() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        await reader.configureLongHeader()
        let packet = try await model.exportSummary()
        XCTAssertTrue(packet.contains("Actual saved body beyond the context header"))
        XCTAssertFalse(packet.contains("HeaderMetadata"))
        XCTAssertLessThan(packet.utf8.count, 80_000)
    }

    func testReusedIDCannotReplaceReviewedEvidence() async throws {
        for mismatch in ["timestamp", "app", "source"] {
            let reader = DailyTestReader()
            let model = DailyMemoryViewModel(reader: reader, selectedDate: Date(timeIntervalSince1970: 1_788_739_200), healthLoader: { nil })
            await model.reload()
            await reader.configureExport(day: model.day)
            try await model.prepareHandoff()
            await reader.reuseExportID(changing: mismatch)
            do {
                _ = try await model.validatedHandoff()
                XCTFail("Reused ID with different \(mismatch) must not be exported.")
            } catch {}
            XCTAssertNil(model.handoffPreview, "A replacement record cannot become the updated preview.")
        }
    }

    func testChangingDateDuringHandoffReadRejectsTheOldPacket() async {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: Date(timeIntervalSince1970: 1_788_739_200), healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        await reader.delayExport()
        let preparation = Task { try await model.prepareHandoff() }
        await reader.waitForDelayedRead()
        model.moveDay(-1)
        await reader.finishDelayedRead()
        do {
            try await preparation.value
            XCTFail("Previous-date preparation must not publish under the new date.")
        } catch {}
        XCTAssertNil(model.handoffPreview)
    }

    func testPreviewRechecksEvidenceAndRequiresReviewAgainAfterAChange() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: Date(timeIntervalSince1970: 1_788_739_200), healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        try await model.prepareHandoff()
        let preview = try XCTUnwrap(model.handoffPreview)
        XCTAssertTrue(preview.contains("Selected"))
        let validated = try await model.validatedHandoff()
        XCTAssertEqual(validated, preview)
        await reader.replaceExportText("Fresh authoritative text")
        do {
            _ = try await model.validatedHandoff()
            XCTFail("Changed evidence must be reviewed before copying.")
        } catch {}
        XCTAssertTrue(model.handoffPreview?.contains("Fresh authoritative text") == true)
        model.moveDay(-1)
        XCTAssertNil(model.handoffPreview)
    }

    func testDeletedEvidenceClearsPreviewAndCannotBeCopied() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        try await model.prepareHandoff()
        await reader.removeExportEvidence()
        do {
            _ = try await model.validatedHandoff()
            XCTFail("Deleted evidence cannot remain in a handoff.")
        } catch {}
        XCTAssertNil(model.handoffPreview)
    }

    func testBriefOnlyDayCannotExportUnrecheckedDraftAsCurrentEvidence() async throws {
        let reader = DailyTestReader()
        await reader.configureBriefOnly()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        XCTAssertFalse(model.canExportSummary)
        await model.reload()
        XCTAssertTrue(model.screenshots.isEmpty)
        XCTAssertFalse(model.canExportSummary)
        do {
            _ = try await model.exportSummary()
            XCTFail("A saved brief alone is not freshly checked evidence.")
        } catch {}
        model.moveDay(-1)
        XCTAssertFalse(model.canExportSummary)
        XCTAssertNil(model.brief, "A date change must hide the previous day's draft before its read finishes.")
        do {
            _ = try await model.exportSummary()
            XCTFail("Stale data must not be exported under the newly selected date.")
        } catch {}
    }

    func testDayExportDoesNotIncludeUnselectedOrOutOfDayFetchedEvidence() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, healthLoader: { nil })
        await model.reload()
        await reader.configureExport(day: model.day)
        let packet = try await model.exportSummary()
        XCTAssertTrue(packet.contains("focus=1"))
        XCTAssertFalse(packet.contains("focus=999"))
        XCTAssertFalse(packet.contains("Other day"))
        XCTAssertTrue(packet.contains("Last saved context"))
        XCTAssertTrue(packet.contains("1 saved text samples"))
        XCTAssertTrue(packet.contains("0 saved image samples"), "Counts must come from fresh evidence, not the old thumbnail list.")
        XCTAssertTrue(packet.contains("Screen capture"))
        XCTAssertFalse(packet.contains("1 available screenshot samples"))
    }

    func testPartialHandoffCountsOnlyRecheckedSamplesAndNeverIncludesSavedDraft() async throws {
        let reader = DailyTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: Date(timeIntervalSince1970: 1_788_739_200), healthLoader: { nil })
        await reader.configurePartialDay(day: model.day)
        await model.reload()
        let packet = try await model.exportSummary()
        XCTAssertTrue(packet.contains("Partial evidence: 1 requested samples"))
        XCTAssertTrue(packet.contains("1 saved text samples / 0 saved image samples"))
        XCTAssertTrue(packet.contains("focus=1"))
        XCTAssertFalse(packet.contains("focus=2"))
        XCTAssertFalse(packet.contains("Synthetic saved draft"))
        XCTAssertFalse(packet.contains("focus=7"))
    }

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
    var briefOnly = false
    var exportHits: [Hit] = []
    var shouldDelayExport = false
    var partialDay: MemoryDay?
    var denseRows: [TimelineEvent]?
    var fullTextOverride: String?
    var shouldDelayText = false
    var textIdentityMismatch = false
    var savedLatestBrief: Brief?
    var shouldDelayLatestBrief = false

    func setLatestBrief(date: String) {
        savedLatestBrief = Brief(rowId: 9, dateLocal: date, generatedTsUs: 1_788_739_200_000_000,
            modelId: "hippocampus-extractive", modelVersion: "2", title: "Saved day",
            body: "Synthetic latest draft", wordCount: 3, sourceEventCount: 1)
    }
    func delayLatestBrief() { shouldDelayLatestBrief = true; hasStarted = false }

    func delayText() { shouldDelayText = true; hasStarted = false }
    func mismatchTextIdentity() { textIdentityMismatch = true }

    func configureLongHeader() {
        let header = "[app=Safari | title=" + String(repeating: "HeaderMetadata", count: 800)
            + " | url=https://example.test | ts=now]\n"
        fullTextOverride = header + "Actual saved body beyond the context header"
        replaceExportText(String(header.prefix(280)))
    }

    func configureDenseDay(day: MemoryDay) {
        denseRows = (0..<480).map { (minute: Int) -> TimelineEvent in
            let timestamp = day.startUs + UInt64(minute) * 60_000_000
            let app = minute % 2 == 0 ? "com.apple.Safari" : "com.apple.Terminal"
            return TimelineEvent(eventId: UInt64(minute + 1), tsUs: timestamp,
                appBundleId: app,
                snippet: "Minute sample", sourceKind: "screen_ocr")
        }
        exportHits = denseRows!.map {
            Hit(eventId: $0.id, tsUs: $0.tsUs, appBundleId: $0.appBundleId, windowTitle: nil, url: nil,
                ocrTextSnippet: $0.snippet, source: "timeline", score: nil, sourceKind: $0.sourceKind)
        }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        guard let hit = exportHits.first(where: { $0.id == eventId }) else { return nil }
        let result = try EventText(eventId: hit.id, tsUs: hit.tsUs + (textIdentityMismatch ? 1 : 0), appBundleId: hit.appBundleId,
            text: fullTextOverride ?? hit.ocrTextSnippet, isTruncated: false)
        if shouldDelayText {
            shouldDelayText = false
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { pending = $0 }
        }
        return result
    }

    func configurePartialDay(day: MemoryDay) { partialDay = day; configureExport(day: day) }

    func delayExport() { shouldDelayExport = true; hasStarted = false }
    func reuseExportID(changing field: String) {
        exportHits = exportHits.filter { $0.id == 1 }.prefix(1).map {
            Hit(eventId: $0.id, tsUs: $0.tsUs + (field == "timestamp" ? 1 : 0),
                appBundleId: field == "app" ? "com.apple.Terminal" : $0.appBundleId,
                windowTitle: nil, url: nil, ocrTextSnippet: "Replacement record",
                source: "timeline", score: nil,
                sourceKind: field == "source" ? "transcript_import" : $0.sourceKind)
        }
    }

    func removeExportEvidence() { exportHits = [] }
    func replaceExportText(_ text: String) {
        exportHits = exportHits.map {
            Hit(eventId: $0.id, tsUs: $0.tsUs, appBundleId: $0.appBundleId, windowTitle: nil,
                url: nil, ocrTextSnippet: text, source: $0.source, score: nil, sourceKind: $0.sourceKind)
        }
    }

    func configureBriefOnly() { briefOnly = true }
    func configureExport(day: MemoryDay) {
        exportHits = [(UInt64(1), day.startUs, "Selected"), (999, day.startUs, "Unselected"),
                      (1, day.endUs + 1, "Other day")].map { id, timestamp, text in
            Hit(eventId: id, tsUs: timestamp, appBundleId: "com.apple.Safari", windowTitle: nil, url: nil,
                ocrTextSnippet: text, source: "timeline", score: nil, sourceKind: "screen_ocr")
        }
    }

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
        if let denseRows { return denseRows }
        if briefOnly { return [] }
        if let partialDay {
            return [1, 2].map { TimelineEvent(eventId: $0, tsUs: partialDay.startUs,
                appBundleId: "com.apple.Safari", snippet: "Old sample", sourceKind: "screen_ocr") }
        }
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
        if savedLatestBrief?.dateLocal == dateLocal { return savedLatestBrief }
        if briefOnly || partialDay != nil {
            return Brief(rowId: 1, dateLocal: dateLocal, generatedTsUs: 1_700_000_000_000_000,
                         modelId: "hippocampus-extractive", modelVersion: "2", title: "Today",
                         body: "## Recent activity\n- Synthetic saved draft [event:7]", wordCount: 6, sourceEventCount: 1)
        }
        return nil
    }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        let result = exportHits
        if shouldDelayExport {
            shouldDelayExport = false
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { pending = $0 }
        }
        return result
    }
    func latestBrief() async throws -> Brief? {
        let result = savedLatestBrief
        if shouldDelayLatestBrief {
            shouldDelayLatestBrief = false
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { pending = $0 }
        }
        return result
    }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
