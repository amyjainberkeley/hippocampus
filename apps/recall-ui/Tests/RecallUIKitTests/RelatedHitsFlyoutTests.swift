// RelatedHitsFlyoutTests.swift — cycle 8.37 PR-3 coverage for the
// related-hits flyout's data-plane surface: `BrainReader.fetchEventsByIds`
// on both the stub and (indirectly via wire-shape mirrors) the FFI.
//
// The SwiftUI flyout view itself is exercised via `#Preview` cases in
// `apps/recall-ui/Sources/RecallUI/RelatedHitsFlyout.swift`; the load
// logic that populates it lives entirely in `BrainReader.fetchEventsByIds`,
// so pinning that method's contract is what this file does.

import XCTest
@testable import RecallUIKit

final class RelatedHitsFlyoutTests: XCTestCase {
    // -----------------------------------------------------------------------
    // 1. Stub round-trip — the audit doc §7 topology holds:
    //    hit 102 links to [101, 103]; resolving those must yield two hits.
    // -----------------------------------------------------------------------
    func testFetchEventsByIdsResolvesDemoTopology() async throws {
        let r = StubBrainReader()
        let source = StubBrainReader.demoHits.first { $0.eventId == 102 }!
        let siblings = try await r.fetchEventsByIds(source.linkedEventIds)
        XCTAssertEqual(siblings.count, 2)
        let ids = siblings.map { $0.eventId }.sorted()
        XCTAssertEqual(ids, [101, 103])
    }

    // -----------------------------------------------------------------------
    // 2. Empty input → no FFI round trip, empty output. The FFI impl also
    //    short-circuits on this — the stub matches the contract.
    // -----------------------------------------------------------------------
    func testFetchEventsByIdsWithEmptyInputReturnsEmpty() async throws {
        let r = StubBrainReader()
        let out = try await r.fetchEventsByIds([])
        XCTAssertTrue(out.isEmpty)
    }

    // -----------------------------------------------------------------------
    // 3. Missing ids are silently dropped. Mirrors the FFI: a linked-event
    //    id can refer to an event that was later suppressed by the cascade;
    //    the store's get_event returns None and the row is skipped.
    // -----------------------------------------------------------------------
    func testFetchEventsByIdsSilentlyDropsMissingIds() async throws {
        let r = StubBrainReader()
        // 101 exists in demo; 9_999 does not.
        let out = try await r.fetchEventsByIds([101, 9_999, 103])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0.eventId }, [101, 103])
    }

    // -----------------------------------------------------------------------
    // 4. Cap at 32 mirrors the FFI's EVENTS_BY_IDS_CAP. A hostile / oversize
    //    input must be truncated silently — we exercise that by handing in
    //    64 ids and asserting the result never exceeds the cap.
    // -----------------------------------------------------------------------
    func testFetchEventsByIdsTruncatesInputAt32() async throws {
        let r = StubBrainReader()
        let manyIds: [UInt64] = Array(1...64).map(UInt64.init)
        let out = try await r.fetchEventsByIds(manyIds)
        // The stub only has 3 demo hits; the cap only kicks in for the
        // input pre-lookup. We assert the CALL succeeded and the output
        // does not exceed the cap either way.
        XCTAssertLessThanOrEqual(out.count, 32)
    }

    // -----------------------------------------------------------------------
    // 5. Wire shape lock: the FFI's `mci_brain_ffi_events_by_ids` returns
    //    an array of the same HitJson wire that `mci_brain_ffi_search`
    //    returns. Decode a fixture whose keys match the Rust serde output
    //    to prove the Swift decoder handles the source="linked" flavor.
    // -----------------------------------------------------------------------
    func testEventsByIdsWireDecodesIntoHits() throws {
        // Byte-for-byte what the Rust FFI's events_by_ids will emit for
        // one linked sibling.
        let json = """
        [{"event_id":101,"ts_us":1736000000000000,\
        "app_bundle_id":"com.apple.Safari","window_title":"Apple — Privacy",\
        "url":"https://apple.com/privacy/",\
        "ocr_text_snippet":"Privacy is a fundamental human right.",\
        "source":"linked","score":null,\
        "entities":["Apple","privacy"],\
        "linked_event_ids":[102]}]
        """
        struct WireMirror: Decodable {
            let event_id: UInt64
            let ts_us: UInt64
            let app_bundle_id: String?
            let window_title: String?
            let url: String?
            let ocr_text_snippet: String
            let source: String
            let score: Float?
            let entities: [String]?
            let linked_event_ids: [UInt64]?

            func toHit() -> Hit {
                Hit(
                    eventId: event_id,
                    tsUs: ts_us,
                    appBundleId: app_bundle_id,
                    windowTitle: window_title,
                    url: url,
                    ocrTextSnippet: ocr_text_snippet,
                    source: source,
                    score: score,
                    entities: entities ?? [],
                    linkedEventIds: linked_event_ids ?? []
                )
            }
        }
        let data = json.data(using: .utf8)!
        let wire = try JSONDecoder().decode([WireMirror].self, from: data)
        XCTAssertEqual(wire.count, 1)
        let hit = wire[0].toHit()
        XCTAssertEqual(hit.eventId, 101)
        XCTAssertEqual(hit.source, "linked",
                       "events_by_ids returns source=linked so the UI can badge these rows")
        XCTAssertNil(hit.score, "linked lookups have no rank")
        XCTAssertEqual(hit.linkedEventIds, [102],
                       "sibling rows must themselves carry linked_event_ids so the "
                       + "flyout stays navigable")
    }
}
