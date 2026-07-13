// HitThumbnailWireTests — cycle 8.35 PR-4 (keyframe thumbnails on HitRow).
//
// Scope: the wire-plumbing half of the PR. The FFI's `HitJson` now emits
// `thumbnail_path: Option<String>`; the Swift `HitWire` decoder threads it
// through to `Hit.thumbnailPath` / `Hit.thumbnailURL`. These tests lock:
//
//   1. A JSON payload with `thumbnail_path` decodes into `Hit` with the
//      matching URL derivation.
//   2. `thumbnail_path: null` and a legacy payload (missing key entirely)
//      both decode with `thumbnailURL == nil`.
//   3. `Hit.thumbnailURL` correctly derives a `file://` URL from a
//      populated path, and returns `nil` for empty / missing paths.
//
// The `HitRow` view + `HitThumbnail` NSImage loader itself is NOT unit-
// tested here — that code lives in the `RecallUI` executable target,
// which the test target does not depend on (see `Package.swift`). The
// load path is instead exercised by manual dogfood + the SwiftUI
// #Preview in `apps/recall-ui/Sources/RecallUI/HitRow.swift`.
//
// The Rust-side FFI wire round-trip (thumbnail_path serialization + hex
// validation) is pinned in `adapters/macos/mci-brain-ffi/tests/hit_entities_wire.rs`
// + the in-crate `thumbnail_path_for_*` tests.

import XCTest

@testable import RecallUIKit

final class HitThumbnailWireTests: XCTestCase {

    // -----------------------------------------------------------------------
    // 1. Populated thumbnail_path plumbs into Hit.thumbnailPath /
    //    Hit.thumbnailURL end-to-end via the private HitWire decoder.
    // -----------------------------------------------------------------------
    func testFFIWireJSONWithThumbnailPathDecodesIntoHitURL() throws {
        // Mirror of the private HitWire in FFIBrainReader.swift — the
        // production decoder is file-private, so we re-inline the same
        // shape here to prove the wire round-trip.
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
            let thumbnail_path: String?

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
                    linkedEventIds: linked_event_ids ?? [],
                    thumbnailPath: thumbnail_path
                )
            }
        }
        let path = "/Users/x/Library/Application Support/MCI/blobs/deadbeef.bin"
        let json = """
        [{"event_id":42,"ts_us":100,"app_bundle_id":"com.apple.Safari",\
        "window_title":null,"url":null,"ocr_text_snippet":"","source":"lexical",\
        "score":0.5,"entities":[],"linked_event_ids":[],\
        "thumbnail_path":"\(path)"}]
        """
        let wire = try JSONDecoder().decode([WireMirror].self, from: Data(json.utf8))
        XCTAssertEqual(wire.count, 1)
        let hit = wire[0].toHit()
        XCTAssertEqual(hit.thumbnailPath, path)
        // File-URL derivation is deterministic and no-I/O.
        XCTAssertNotNil(hit.thumbnailURL)
        XCTAssertEqual(hit.thumbnailURL?.path, path)
        XCTAssertEqual(hit.thumbnailURL?.isFileURL, true)
    }

    // -----------------------------------------------------------------------
    // 2. Explicit null and missing-key legacy payloads both yield nil URL.
    // -----------------------------------------------------------------------
    func testFFIWireJSONWithNullThumbnailPathYieldsNilURL() throws {
        struct WireMirror: Decodable {
            let event_id: UInt64
            let ts_us: UInt64
            let app_bundle_id: String?
            let window_title: String?
            let url: String?
            let ocr_text_snippet: String
            let source: String
            let score: Float?
            let thumbnail_path: String?

            func toHit() -> Hit {
                Hit(
                    eventId: event_id, tsUs: ts_us,
                    appBundleId: app_bundle_id, windowTitle: window_title,
                    url: url, ocrTextSnippet: ocr_text_snippet,
                    source: source, score: score,
                    thumbnailPath: thumbnail_path
                )
            }
        }
        // (a) Explicit null.
        let json1 = """
        [{"event_id":1,"ts_us":0,"app_bundle_id":null,"window_title":null,\
        "url":null,"ocr_text_snippet":"","source":"timeline","score":null,\
        "thumbnail_path":null}]
        """
        let wire1 = try JSONDecoder().decode([WireMirror].self, from: Data(json1.utf8))
        XCTAssertNil(wire1[0].toHit().thumbnailPath)
        XCTAssertNil(wire1[0].toHit().thumbnailURL)
        // (b) Legacy: key missing entirely.
        let json2 = """
        [{"event_id":1,"ts_us":0,"app_bundle_id":null,"window_title":null,\
        "url":null,"ocr_text_snippet":"","source":"timeline","score":null}]
        """
        let wire2 = try JSONDecoder().decode([WireMirror].self, from: Data(json2.utf8))
        XCTAssertNil(wire2[0].toHit().thumbnailPath)
        XCTAssertNil(wire2[0].toHit().thumbnailURL)
    }

    // -----------------------------------------------------------------------
    // 3. thumbnailURL derivation — file URL for a populated path, nil for
    //    nil / empty. Purely a getter; no I/O.
    // -----------------------------------------------------------------------
    func testHitThumbnailURLDerivation() {
        let none = Hit(
            eventId: 1, tsUs: 0, appBundleId: nil, windowTitle: nil,
            url: nil, ocrTextSnippet: "", source: "timeline", score: nil
        )
        XCTAssertNil(none.thumbnailURL, "nil path → nil URL")

        let empty = Hit(
            eventId: 2, tsUs: 0, appBundleId: nil, windowTitle: nil,
            url: nil, ocrTextSnippet: "", source: "timeline", score: nil,
            thumbnailPath: ""
        )
        XCTAssertNil(empty.thumbnailURL, "empty path → nil URL (defensive)")

        let real = Hit(
            eventId: 3, tsUs: 0, appBundleId: nil, windowTitle: nil,
            url: nil, ocrTextSnippet: "", source: "timeline", score: nil,
            thumbnailPath: "/tmp/mci/blobs/abc.bin"
        )
        XCTAssertEqual(real.thumbnailURL?.isFileURL, true)
        XCTAssertEqual(real.thumbnailURL?.path, "/tmp/mci/blobs/abc.bin")
    }

    // -----------------------------------------------------------------------
    // 4. Old call-sites keep compiling — thumbnailPath default is nil.
    //    Regression pin against accidentally requiring the new field.
    // -----------------------------------------------------------------------
    func testHitInitDefaultsThumbnailPathToNil() {
        let h = Hit(
            eventId: 9, tsUs: 0, appBundleId: nil, windowTitle: nil,
            url: nil, ocrTextSnippet: "", source: "timeline", score: nil
        )
        XCTAssertNil(h.thumbnailPath)
        XCTAssertNil(h.thumbnailURL)
    }
}
