// BriefViewModelTests.swift — pin the 5-state machine + date selector
// transitions for the Daily Brief tab (`docs/design/brief-viewer-spec.md`).

import XCTest
@testable import RecallUIKit

@MainActor
final class BriefViewModelTests: XCTestCase {

    // MARK: helpers

    private func sampleBrief(date: String, generated: UInt64 = 1, body: String = "## Highlights\n\nx\n") -> Brief {
        Brief(
            rowId: UInt64.random(in: 1...100_000),
            dateLocal: date,
            generatedTsUs: generated,
            modelId: "qwen3-1.7b-fp16",
            modelVersion: "test",
            title: "Test for \(date)",
            body: body,
            wordCount: 3,
            sourceEventCount: 0
        )
    }

    /// Reader that holds a configurable list of briefs and answers the
    /// brief read methods deterministically. Search/timeline/privacy are
    /// hardcoded empty.
    private struct InMemoryBriefReader: BrainReader {
        let briefs: [Brief]
        func search(_ opts: SearchOptions) async throws -> [Hit] { [] }
        func recentEvents(limit: Int) async throws -> [Hit] { [] }
        func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
        func listObservedApps(
            limit: Int, timeFromUs: UInt64?
        ) async throws -> [ObservedApp] { [] }
        func listEpisodes(limit: Int) async throws -> [Episode] { [] }
        func briefForDate(_ dateLocal: String) async throws -> Brief? {
            briefs.first { $0.dateLocal == dateLocal }
        }
        func latestBrief() async throws -> Brief? {
            briefs.max { $0.generatedTsUs < $1.generatedTsUs }
        }
        func briefDates(limit: Int) async throws -> [String] {
            Array(briefs.sorted { $0.dateLocal > $1.dateLocal }
                .prefix(max(0, limit))
                .map(\.dateLocal))
        }
        func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
        func summaryStats() async throws -> SummaryStats {
            SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
        }
    }

    /// Reader that throws on every brief call. Used to pin the `.error`
    /// scene transition.
    private struct ThrowingBriefReader: BrainReader {
        struct Boom: Error {}
        func search(_ opts: SearchOptions) async throws -> [Hit] { [] }
        func recentEvents(limit: Int) async throws -> [Hit] { [] }
        func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
        func listObservedApps(
            limit: Int, timeFromUs: UInt64?
        ) async throws -> [ObservedApp] { [] }
        func listEpisodes(limit: Int) async throws -> [Episode] { [] }
        func briefForDate(_ dateLocal: String) async throws -> Brief? { throw Boom() }
        func latestBrief() async throws -> Brief? { throw Boom() }
        func briefDates(limit: Int) async throws -> [String] { throw Boom() }
        func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
        func summaryStats() async throws -> SummaryStats {
            SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
        }
    }

    // -------------------------------------------------------------------
    // 5-state machine — each spec state has a test pinning the transition.
    // -------------------------------------------------------------------

    func testReloadWhenModelMissingShortCircuitsToModelMissingScene() async {
        let reader = InMemoryBriefReader(briefs: [sampleBrief(date: "2026-05-22")])
        let vm = BriefViewModel(reader: reader, isModelPresent: false)
        await vm.reload()
        XCTAssertEqual(vm.scene, .modelMissing)
    }

    func testReloadWhenBriefsEmptyAndNoFullDayLandsOnAwaitingFirstFullDay() async {
        let reader = InMemoryBriefReader(briefs: [])
        let vm = BriefViewModel(
            reader: reader,
            isModelPresent: true,
            hasFullDayCapture: false,
            captureHoursSoFar: 4.5
        )
        await vm.reload()
        XCTAssertEqual(vm.scene, .awaitingFirstFullDay(captureHoursSoFar: 4.5))
    }

    func testReloadWithBriefsLoadsLatestBrief() async {
        let early = sampleBrief(date: "2026-05-20", generated: 1)
        let late = sampleBrief(date: "2026-05-22", generated: 3)
        let mid = sampleBrief(date: "2026-05-21", generated: 2)
        let reader = InMemoryBriefReader(briefs: [early, late, mid])
        let vm = BriefViewModel(reader: reader)
        await vm.reload()
        guard case .brief(let b) = vm.scene else {
            return XCTFail("expected .brief scene, got \(vm.scene)")
        }
        XCTAssertEqual(b.dateLocal, "2026-05-22")
        XCTAssertEqual(vm.selectedDate, "2026-05-22")
    }

    func testReloadWithEmptyStoreButFullDayCaptureLandsOnMissingForToday() async {
        let reader = InMemoryBriefReader(briefs: [])
        let vm = BriefViewModel(
            reader: reader,
            isModelPresent: true,
            hasFullDayCapture: true
        )
        await vm.reload()
        if case .missingForDate(let d) = vm.scene {
            XCTAssertEqual(d, BriefViewModel.todayISO())
        } else {
            XCTFail("expected .missingForDate, got \(vm.scene)")
        }
    }

    func testLoadForUnknownDateRendersMissingForDate() async {
        let reader = InMemoryBriefReader(briefs: [sampleBrief(date: "2026-05-22")])
        let vm = BriefViewModel(reader: reader)
        await vm.reload()
        await vm.loadFor("1999-01-01")
        XCTAssertEqual(vm.scene, .missingForDate(dateLocal: "1999-01-01"))
        XCTAssertEqual(vm.selectedDate, "1999-01-01")
    }

    func testReaderErrorPutsVMIntoErrorScene() async {
        let vm = BriefViewModel(reader: ThrowingBriefReader())
        await vm.reload()
        if case .error = vm.scene {
            // ok
        } else {
            XCTFail("expected .error scene, got \(vm.scene)")
        }
    }

    // -------------------------------------------------------------------
    // Date selector — pickPrevious / pickNext walk knownDates.
    // -------------------------------------------------------------------

    func testKnownDatesReflectsBriefsOrderedDescending() async {
        let reader = InMemoryBriefReader(briefs: [
            sampleBrief(date: "2026-05-20"),
            sampleBrief(date: "2026-05-22"),
            sampleBrief(date: "2026-05-21"),
        ])
        let vm = BriefViewModel(reader: reader)
        await vm.reload()
        XCTAssertEqual(vm.knownDates, ["2026-05-22", "2026-05-21", "2026-05-20"])
    }

    func testPickPreviousWalksBackInTime() async {
        let reader = InMemoryBriefReader(briefs: [
            sampleBrief(date: "2026-05-20", generated: 1),
            sampleBrief(date: "2026-05-21", generated: 2),
            sampleBrief(date: "2026-05-22", generated: 3),
        ])
        let vm = BriefViewModel(reader: reader)
        await vm.reload()
        XCTAssertEqual(vm.selectedDate, "2026-05-22")
        await vm.pickPrevious()
        XCTAssertEqual(vm.selectedDate, "2026-05-21")
        await vm.pickPrevious()
        XCTAssertEqual(vm.selectedDate, "2026-05-20")
        // At the oldest known — should be no-op.
        await vm.pickPrevious()
        XCTAssertEqual(vm.selectedDate, "2026-05-20")
        XCTAssertFalse(vm.canPickPrevious)
    }

    func testPickNextWalksForwardInTime() async {
        let reader = InMemoryBriefReader(briefs: [
            sampleBrief(date: "2026-05-20", generated: 1),
            sampleBrief(date: "2026-05-21", generated: 2),
            sampleBrief(date: "2026-05-22", generated: 3),
        ])
        let vm = BriefViewModel(reader: reader)
        await vm.reload()
        await vm.pickPrevious() // -> 21
        await vm.pickPrevious() // -> 20
        XCTAssertEqual(vm.selectedDate, "2026-05-20")
        await vm.pickNext() // -> 21
        XCTAssertEqual(vm.selectedDate, "2026-05-21")
        await vm.pickNext() // -> 22
        XCTAssertEqual(vm.selectedDate, "2026-05-22")
        // At the newest — should be no-op.
        await vm.pickNext()
        XCTAssertEqual(vm.selectedDate, "2026-05-22")
        XCTAssertFalse(vm.canPickNext)
    }

    func testCanPickFalseWhenKnownDatesEmpty() async {
        let vm = BriefViewModel(reader: InMemoryBriefReader(briefs: []))
        // Without reload, knownDates is empty and selectedDate is nil.
        XCTAssertFalse(vm.canPickNext)
        XCTAssertFalse(vm.canPickPrevious)
    }

    // -------------------------------------------------------------------
    // forceDate override
    // -------------------------------------------------------------------

    func testReloadWithForceDateRoutesToThatDate() async {
        let reader = InMemoryBriefReader(briefs: [
            sampleBrief(date: "2026-05-20", generated: 1),
            sampleBrief(date: "2026-05-22", generated: 3),
        ])
        let vm = BriefViewModel(reader: reader)
        await vm.reload(forceDate: "2026-05-20")
        XCTAssertEqual(vm.selectedDate, "2026-05-20")
        if case .brief(let b) = vm.scene {
            XCTAssertEqual(b.dateLocal, "2026-05-20")
        } else {
            XCTFail("expected .brief, got \(vm.scene)")
        }
    }
}
