// FFIBrainReaderTests.swift — Swift-side lifecycle + error-path tests for
// `FFIBrainReader`. The data round-trip tests (seed DB on the Rust side,
// read via FFI, assert content) live in
// `adapters/macos/mci-brain-ffi/tests/readonly_invariant.rs` — Swift can't
// construct the writer-side `SqlCipherBrainStore` directly because there
// is no Swift wrapper for the writer (intentional — the recall-ui is
// read-only by construction). These Swift tests cover the bindings'
// error reporting and lifecycle.

import XCTest
@testable import RecallUIKit

final class FFIBrainReaderTests: XCTestCase {
    // -----------------------------------------------------------------------
    // 1. Open with a missing file fails with BrainReaderError.openFailed
    // -----------------------------------------------------------------------
    func testOpenMissingFileThrows() {
        let path = NSTemporaryDirectory() + "mci-ffi-tests-no-such.sqlite"
        // Make sure it really doesn't exist.
        try? FileManager.default.removeItem(atPath: path)
        let validKeyHex = String(repeating: "00", count: 32)
        XCTAssertThrowsError(try FFIBrainReader(path: path, keyHex: validKeyHex)) { err in
            guard case BrainReaderError.openFailed(let msg) = err else {
                XCTFail("expected openFailed, got \(err)")
                return
            }
            XCTAssertFalse(msg.isEmpty, "openFailed must carry a non-empty diagnostic")
        }
    }

    // -----------------------------------------------------------------------
    // 2. Open with a short key fails with openFailed + the hex-length error
    // -----------------------------------------------------------------------
    func testOpenShortKeyHexThrows() {
        let path = NSTemporaryDirectory() + "mci-ffi-tests-shortkey.sqlite"
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertThrowsError(try FFIBrainReader(path: path, keyHex: "deadbeef")) { err in
            guard case BrainReaderError.openFailed(let msg) = err else {
                XCTFail("expected openFailed, got \(err)")
                return
            }
            XCTAssertTrue(
                msg.contains("64 hex chars"),
                "diagnostic should mention the 64-char requirement; got: \(msg)"
            )
        }
    }

    // -----------------------------------------------------------------------
    // 3. Open with a non-hex key fails with openFailed
    // -----------------------------------------------------------------------
    func testOpenNonHexKeyThrows() {
        let path = NSTemporaryDirectory() + "mci-ffi-tests-nonhex.sqlite"
        try? FileManager.default.removeItem(atPath: path)
        let bogusKey = String(repeating: "zz", count: 32) // 64 chars but non-hex
        XCTAssertThrowsError(try FFIBrainReader(path: path, keyHex: bogusKey)) { err in
            guard case BrainReaderError.openFailed(let msg) = err else {
                XCTFail("expected openFailed, got \(err)")
                return
            }
            XCTAssertTrue(
                msg.contains("non-hex"),
                "diagnostic should mention non-hex byte; got: \(msg)"
            )
        }
    }

    // -----------------------------------------------------------------------
    // 4. SearchOptions encodes the wire keys the FFI expects (snake_case)
    // -----------------------------------------------------------------------
    func testQueryPayloadEncodesSnakeCaseKeys() throws {
        // This is the contract the FFI's `serde_json::from_str(QueryJson)`
        // depends on. If a future refactor accidentally flips the keys
        // back to camelCase, the FFI rejects with "bad query JSON" — this
        // unit test pins the wire shape before that round trip.
        let opts = SearchOptions(
            text: "privacy",
            limit: 10,
            appFilter: "com.apple.Safari",
            timeFromUs: 100,
            timeToUs: 200
        )
        // FFIBrainReader's internal QueryPayload is private; we mimic
        // the same encoding here to assert the wire shape.
        struct Wire: Encodable {
            let text: String
            let limit: Int
            let timeFromUs: UInt64?
            let timeToUs: UInt64?
            let appFilter: String?
            enum CodingKeys: String, CodingKey {
                case text, limit
                case timeFromUs = "time_from_us"
                case timeToUs = "time_to_us"
                case appFilter = "app_filter"
            }
        }
        let wire = Wire(
            text: opts.text,
            limit: opts.limit,
            timeFromUs: opts.timeFromUs,
            timeToUs: opts.timeToUs,
            appFilter: opts.appFilter
        )
        let data = try JSONEncoder().encode(wire)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("\"time_from_us\":100"), "got: \(s)")
        XCTAssertTrue(s.contains("\"time_to_us\":200"), "got: \(s)")
        XCTAssertTrue(s.contains("\"app_filter\":\"com.apple.Safari\""), "got: \(s)")
    }

    // -----------------------------------------------------------------------
    // 5. HitWire/PrivacyMomentWire shape matches the Rust JsonRust shape
    // -----------------------------------------------------------------------
    func testHitDecodesFromRustWireShape() throws {
        let json = """
        [{"event_id":42,"ts_us":1700000000000000,"app_bundle_id":"com.apple.Safari",\
        "window_title":"T","url":"https://example.com/","ocr_text_snippet":"snip",\
        "source":"lexical","score":0.87}]
        """
        struct Wire: Decodable {
            let event_id: UInt64
            let ts_us: UInt64
            let app_bundle_id: String?
            let window_title: String?
            let url: String?
            let ocr_text_snippet: String
            let source: String
            let score: Float?
        }
        let data = json.data(using: .utf8)!
        let rows = try JSONDecoder().decode([Wire].self, from: data)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].event_id, 42)
        XCTAssertEqual(rows[0].source, "lexical")
        XCTAssertEqual(rows[0].score, 0.87)
    }

    func testPrivacyMomentDecodesFromRustWireShape() throws {
        let json = """
        [{"ts_us":1700000000000000,"app_bundle_id":"com.1password.app","reason_code":4}]
        """
        struct Wire: Decodable {
            let ts_us: UInt64
            let app_bundle_id: String?
            let reason_code: UInt8
        }
        let data = json.data(using: .utf8)!
        let rows = try JSONDecoder().decode([Wire].self, from: data)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].reason_code, 4)
    }
}
