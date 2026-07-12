// HitWireEntitiesTests.swift — cycle-8.35 PR-1 Codable coverage.
//
// The Rust FFI's `HitJson` now carries `entities: Vec<String>` and
// `linked_event_ids: Vec<u64>` (see `adapters/macos/mci-brain-ffi/src/lib.rs`
// and its `tests/hit_entities_wire.rs` companion). This file locks the
// Swift-side Codable contract that consumes that wire:
//
// 1. `Hit` itself round-trips through `JSONEncoder` / `JSONDecoder` with
//    the new `entities` + `linkedEventIds` fields populated.
// 2. Decoding the exact snake_case JSON emitted by the Rust FFI produces
//    a `Hit` with the entity chip / linked-event data intact.
// 3. Decoding a **legacy** JSON payload (omits both keys — matches an
//    older Rust build, or the MCP `mci_recall` wire before PR #307)
//    still yields a valid `Hit` with empty entities / linkedEventIds.
//    This is the forward/backward-compat contract the FFI's
//    `#[serde(default)]` promises.
// 4. `StubBrainReader.demoHits` now carries sample entities / linked ids
//    so headless tests can exercise the entity-chip surface (cycle 8.35
//    PR-2) against the stub without wiring the FFI.

import XCTest
@testable import RecallUIKit

final class HitWireEntitiesTests: XCTestCase {
    // -----------------------------------------------------------------------
    // 1. Hit is Codable — the new fields survive a round trip
    // -----------------------------------------------------------------------
    func testHitCodableRoundTripPreservesEntitiesAndLinkedIds() throws {
        let original = Hit(
            eventId: 42,
            tsUs: 1_700_000_000_000_000,
            appBundleId: "com.apple.Safari",
            windowTitle: "Vector databases at scale",
            url: "https://arxiv.org/abs/2312.06827",
            ocrTextSnippet: "Vector databases at scale ...",
            source: "hybrid",
            score: 0.87,
            entities: ["Anthropic", "vector databases", "MCP"],
            linkedEventIds: [101, 202, 303]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hit.self, from: data)
        XCTAssertEqual(decoded, original, "Hit Codable round trip must be lossless")
        XCTAssertEqual(decoded.entities, ["Anthropic", "vector databases", "MCP"])
        XCTAssertEqual(decoded.linkedEventIds, [101, 202, 303])
    }

    // -----------------------------------------------------------------------
    // 2. The exact snake_case wire the Rust FFI emits must decode via the
    //    same wire mirror the FFIBrainReader uses internally.
    //
    //    We cannot reach the private `HitWire` type inside FFIBrainReader
    //    directly; the wire contract is that a snake_case JSON payload
    //    with `entities` + `linked_event_ids` keys yields a Hit with the
    //    corresponding camelCase Swift fields populated. That contract is
    //    what this test pins — a local mirror struct that matches the
    //    private HitWire, plus a call to a `toHit()` shape that matches
    //    the one in FFIBrainReader.swift.
    // -----------------------------------------------------------------------
    func testFFIWireJSONWithEntitiesDecodesIntoHit() throws {
        // This JSON is byte-for-byte what
        // `adapters/macos/mci-brain-ffi/src/lib.rs::mci_brain_ffi_search`
        // will emit for a hit with two entities and one linked event.
        let json = """
        [{"event_id":7,"ts_us":1700000000000000,"app_bundle_id":"com.apple.Safari",\
        "window_title":"Apple — Privacy","url":"https://apple.com/privacy/",\
        "ocr_text_snippet":"Privacy is a fundamental human right.",\
        "source":"hybrid","score":0.91,\
        "entities":["Apple","privacy"],\
        "linked_event_ids":[102,103]}]
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
        XCTAssertEqual(hit.eventId, 7)
        XCTAssertEqual(hit.entities, ["Apple", "privacy"])
        XCTAssertEqual(hit.linkedEventIds, [102, 103])
        XCTAssertEqual(hit.source, "hybrid")
    }

    // -----------------------------------------------------------------------
    // 3. Legacy JSON (pre-PR-1 FFI, or an older mixed-version deployment)
    //    omits both keys — must still decode with empty defaults.
    // -----------------------------------------------------------------------
    func testFFIWireJSONMissingEntitiesFieldsStillDecodes() throws {
        // Same JSON shape as the FFI emitted BEFORE cycle 8.35 PR-1.
        // Neither `entities` nor `linked_event_ids` is present.
        let legacy = """
        [{"event_id":1,"ts_us":100,"app_bundle_id":null,"window_title":null,\
        "url":null,"ocr_text_snippet":"","source":"timeline","score":null}]
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
        let data = legacy.data(using: .utf8)!
        let wire = try JSONDecoder().decode([WireMirror].self, from: data)
        XCTAssertEqual(wire.count, 1)
        let hit = wire[0].toHit()
        XCTAssertTrue(hit.entities.isEmpty, "missing key must default to []")
        XCTAssertTrue(hit.linkedEventIds.isEmpty, "missing key must default to []")
    }

    // -----------------------------------------------------------------------
    // 4. StubBrainReader.demoHits carries realistic entity + link data so
    //    the entity-chip surface (PR-2) has something to render in
    //    headless tests without wiring the real FFI.
    // -----------------------------------------------------------------------
    func testStubDemoHitsCarryEntitiesAndLinkedIds() {
        let byId = Dictionary(uniqueKeysWithValues: StubBrainReader.demoHits.map { ($0.eventId, $0) })
        // Every demo hit has at least one entity now — sanity check the
        // fixture wasn't left as a stub.
        for hit in StubBrainReader.demoHits {
            XCTAssertFalse(
                hit.entities.isEmpty,
                "demoHits[\(hit.eventId)] must carry sample entities for PR-2 to render"
            )
        }
        // Cross-hit topology matches the audit doc §7 example (Safari ↔ VSCode
        // ↔ Slack, all touching "MCI"). The specific linked-id shape is stable
        // so downstream tests can rely on it.
        XCTAssertEqual(byId[102]?.linkedEventIds, [101, 103],
                       "middle hit must link to both siblings")
        XCTAssertEqual(byId[101]?.linkedEventIds, [102])
        XCTAssertEqual(byId[103]?.linkedEventIds, [102])
    }

    // -----------------------------------------------------------------------
    // 5. Default init parameters keep old call-sites compiling.
    //    (Regression pin against accidentally requiring the new fields.)
    // -----------------------------------------------------------------------
    func testHitInitAcceptsCallersThatOmitTheNewFields() {
        // Every existing test / VM in RecallUIKit constructs Hit without
        // entities / linkedEventIds. This must keep working — the new
        // params carry `= []` defaults on the initializer.
        let h = Hit(
            eventId: 9,
            tsUs: 0,
            appBundleId: nil,
            windowTitle: nil,
            url: nil,
            ocrTextSnippet: "",
            source: "timeline",
            score: nil
        )
        XCTAssertTrue(h.entities.isEmpty)
        XCTAssertTrue(h.linkedEventIds.isEmpty)
    }
}
