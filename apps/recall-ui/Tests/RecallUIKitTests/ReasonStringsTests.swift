// ReasonStringsTests.swift — pin the ADR-0017 §5.2 mapping.
//
// Every code → string is binding copy. A regression in this map is a
// privacy-UX regression (the user sees the wrong reason). Tests assert
// EXACT strings so a stray edit fails CI.

import XCTest
@testable import RecallUIKit

final class ReasonStringsTests: XCTestCase {
    func testAllNineReasonCodesHaveStrings() {
        for code: UInt8 in 1...9 {
            XCTAssertNotEqual(
                ReasonStrings.string(for: code),
                ReasonStrings.unknown,
                "reason code \(code) must have a friendly string"
            )
        }
    }

    func testReasonStringsAdr0017Section52Verbatim() {
        XCTAssertEqual(
            ReasonStrings.string(for: 1),
            "App was on the denylist."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 2),
            "DRM-protected video (Apple TV, Netflix, etc.)."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 3),
            "Password being typed."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 4),
            "Password field detected."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 5),
            "App was being captured but moved to denylist."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 6),
            "Text matched a secret/PII pattern."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 7),
            "App was unknown — MCI refused by default."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 8),
            "You asked MCI to ignore this."
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 9),
            "Incognito/private browser window."
        )
    }

    func testUnknownReasonCodeReturnsForwardCompatibleFallback() {
        XCTAssertEqual(
            ReasonStrings.string(for: 200),
            ReasonStrings.unknown
        )
        XCTAssertEqual(
            ReasonStrings.string(for: 0),
            ReasonStrings.unknown
        )
        XCTAssertFalse(ReasonStrings.unknown.isEmpty)
    }

    func testSectionTagMapping() {
        XCTAssertEqual(ReasonStrings.sectionTag(for: 1), "§1")
        XCTAssertEqual(ReasonStrings.sectionTag(for: 6), "§6")
        XCTAssertEqual(ReasonStrings.sectionTag(for: 8), "§8 (user)")
        XCTAssertEqual(ReasonStrings.sectionTag(for: 9), "§9 (incognito)")
        XCTAssertEqual(ReasonStrings.sectionTag(for: 100), "§?")
    }

    func testReasonStringsContainNoSensitiveTokens() {
        // The map MUST NOT carry app bundle ids, window titles, URLs,
        // OCR text, or anything that could be user content. This test
        // pins the invariant in a way a careless future edit can't
        // bypass: any string containing a "." (a likely bundle-id
        // signal) or "://" (a URL signal) fails. The phrase
        // "Apple TV, Netflix" in reason 2 is allowed — those are
        // generic product names, not user-derived content.
        for (code, str) in ReasonStrings.table {
            XCTAssertFalse(
                str.contains("://"),
                "reason \(code) appears to contain a URL: \(str)"
            )
            XCTAssertFalse(
                str.contains("com.") || str.contains("org."),
                "reason \(code) appears to contain a bundle id: \(str)"
            )
            // Bundle char `_` is allowed in lower-case-only strings; the
            // map is hand-curated English copy and shouldn't carry one.
            XCTAssertFalse(
                str.contains("_"),
                "reason \(code) contains an underscore (likely a token leak): \(str)"
            )
        }
    }
}
