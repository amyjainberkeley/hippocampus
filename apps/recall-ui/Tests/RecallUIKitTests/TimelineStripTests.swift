// TimelineStripTests.swift — V2-P13 (Phase D scaffold).
//
// Pin the wire shape + default protocol behavior for the ⌘8 Rewind-style
// timeline strip. Full end-to-end FFI tests live in `mci-brain-ffi`.

import XCTest
@testable import RecallUIKit

final class TimelineStripTests: XCTestCase {
    func testTimelineEventRoundTripsThroughJson() throws {
        let e = TimelineEvent(
            eventId: 42,
            tsUs: 1_700_000_000_000_000,
            appBundleId: "com.apple.Safari",
            snippet: "hello",
            thumbnailPath: "/tmp/blobs/abc.bin"
        )
        let encoded = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(TimelineEvent.self, from: encoded)
        XCTAssertEqual(e, back)
    }

    func testTimelineEventThumbnailUrlIsNilWhenPathIsNil() {
        let e = TimelineEvent(
            eventId: 1, tsUs: 0, appBundleId: nil, snippet: "",
            thumbnailPath: nil
        )
        XCTAssertNil(e.thumbnailURL)
    }

    func testTimelineEventThumbnailUrlIsFileUrlWhenPathIsSet() {
        let e = TimelineEvent(
            eventId: 1, tsUs: 0, appBundleId: nil, snippet: "",
            thumbnailPath: "/tmp/blob.bin"
        )
        XCTAssertEqual(e.thumbnailURL?.path, "/tmp/blob.bin")
    }

    func testResolutionDefaultWindowSpansAreOrdered() {
        XCTAssertLessThan(
            TimelineResolution.minute.defaultWindowUs,
            TimelineResolution.hour.defaultWindowUs
        )
        XCTAssertLessThan(
            TimelineResolution.hour.defaultWindowUs,
            TimelineResolution.day.defaultWindowUs
        )
    }

    func testResolutionDisplayLabelsAreDayWeekMonth() {
        XCTAssertEqual(TimelineResolution.minute.displayLabel, "Day")
        XCTAssertEqual(TimelineResolution.hour.displayLabel, "Week")
        XCTAssertEqual(TimelineResolution.day.displayLabel, "Month")
    }

    // Default protocol impl — projects `recentEvents` into
    // `TimelineEvent`s filtered by the window.

    func testDefaultTimelineEventsFiltersByWindow() async throws {
        let reader = StubBrainReader()
        let mid = StubBrainReader.demoHits[1].tsUs
        let out = try await reader.timelineEvents(
            startTsUs: mid, endTsUs: mid, resolution: .minute
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.eventId, StubBrainReader.demoHits[1].eventId)
    }

    func testDefaultTimelineEventsReturnsAscendingOrder() async throws {
        let reader = StubBrainReader()
        let out = try await reader.timelineEvents(
            startTsUs: 0, endTsUs: UInt64.max / 2, resolution: .minute
        )
        XCTAssertEqual(out.count, StubBrainReader.demoHits.count)
        for i in 1..<out.count {
            XCTAssertLessThanOrEqual(out[i - 1].tsUs, out[i].tsUs)
        }
    }

    func testDefaultTimelineEventsIsEmptyOutsideWindow() async throws {
        let reader = StubBrainReader()
        let out = try await reader.timelineEvents(
            startTsUs: 0, endTsUs: 1, resolution: .minute
        )
        XCTAssertTrue(out.isEmpty)
    }

    // View-model state machine.

    @MainActor
    func testViewModelReloadPopulatesEventsWithinDefaultWindow() async throws {
        // Anchor to the newest demo hit so the default 24 h window
        // includes at least one row.
        let newest = StubBrainReader.demoHits.map(\.tsUs).max()!
        let vm = TimelineStripViewModel(
            reader: StubBrainReader(),
            anchorTsUs: newest
        )
        await vm.reload()
        // Only rows whose ts is within the last 24 h of `newest` should
        // land in the view — for the canned corpus that's just the
        // anchor row itself (the others are >24 h older).
        XCTAssertGreaterThanOrEqual(vm.events.count, 1)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testViewModelZoomInAndOutCycleThroughResolutions() {
        let vm = TimelineStripViewModel(
            reader: StubBrainReader(),
            anchorTsUs: 0
        )
        XCTAssertEqual(vm.resolution, .minute)
        vm.zoomOut()
        XCTAssertEqual(vm.resolution, .hour)
        vm.zoomOut()
        XCTAssertEqual(vm.resolution, .day)
        // Coarsest step is idempotent.
        vm.zoomOut()
        XCTAssertEqual(vm.resolution, .day)
        vm.zoomIn()
        XCTAssertEqual(vm.resolution, .hour)
        vm.zoomIn()
        XCTAssertEqual(vm.resolution, .minute)
        // Finest step is idempotent.
        vm.zoomIn()
        XCTAssertEqual(vm.resolution, .minute)
    }

    @MainActor
    func testTimelineEventCardTimeLabelIsHhmm() {
        // 2025-05-31 00:00:00 UTC = 1748649600 seconds.
        let tsUs: UInt64 = 1_748_649_600 * 1_000_000
        let label = TimelineEventCard.timeLabel(for: tsUs)
        // HH:mm shape.
        XCTAssertEqual(label.count, 5)
        XCTAssertEqual(label.dropFirst(2).first, ":")
    }

    @MainActor
    func testTimelineEventCardShortAppNameStripsReverseDns() {
        XCTAssertEqual(
            TimelineEventCard.shortAppName("com.apple.Safari"),
            "Safari"
        )
        XCTAssertEqual(TimelineEventCard.shortAppName("Firefox"), "Firefox")
    }
}
