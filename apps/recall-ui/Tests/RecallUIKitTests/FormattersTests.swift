// FormattersTests.swift — pin the presentation strings byte-exact.

import XCTest
@testable import RecallUIKit

final class FormattersTests: XCTestCase {
    func testSnippetUnderMaxIsUnchanged() {
        XCTAssertEqual(Formatters.snippet("short text", maxLen: 280), "short text")
    }

    func testSnippetOverMaxTruncatesWithEllipsis() {
        let s = String(repeating: "x", count: 400)
        let out = Formatters.snippet(s, maxLen: 50)
        XCTAssertEqual(out.count, 50)
        XCTAssertTrue(out.hasSuffix("…"))
        // Ellipsis IS one of the 50 chars; the first 49 are 'x'.
        XCTAssertEqual(String(out.prefix(49)), String(repeating: "x", count: 49))
    }

    func testSnippetMaxLenTooSmallDoesNotCrash() {
        // Below 4, the helper just returns the prefix without an ellipsis.
        XCTAssertEqual(Formatters.snippet("hello", maxLen: 3), "hel")
        XCTAssertEqual(Formatters.snippet("hi", maxLen: 0), "")
    }

    func testTsStringIsStableUTC() {
        // 2024-01-01T00:00:00 UTC = 1_704_067_200 s = 1_704_067_200_000_000 us
        let s = Formatters.tsString(usSinceEpoch: 1_704_067_200_000_000)
        XCTAssertEqual(s, "2024-01-01 00:00:00 UTC")
    }

    func testTsStringEpochZero() {
        XCTAssertEqual(
            Formatters.tsString(usSinceEpoch: 0),
            "1970-01-01 00:00:00 UTC"
        )
    }

    func testContextLineWithAppAndTitle() {
        let h = Hit(
            eventId: 1, tsUs: 0,
            appBundleId: "com.apple.Safari",
            windowTitle: "Apple — Privacy",
            url: nil, ocrTextSnippet: "x",
            source: "lexical", score: nil
        )
        XCTAssertEqual(
            Formatters.contextLine(h),
            "com.apple.Safari — Apple — Privacy"
        )
    }

    func testContextLineWithAppAndUrlNoTitle() {
        let h = Hit(
            eventId: 1, tsUs: 0,
            appBundleId: "com.apple.Safari",
            windowTitle: nil,
            url: "https://example.org/",
            ocrTextSnippet: "x",
            source: "lexical", score: nil
        )
        XCTAssertEqual(
            Formatters.contextLine(h),
            "com.apple.Safari — https://example.org/"
        )
    }

    func testContextLineWithAppOnly() {
        let h = Hit(
            eventId: 1, tsUs: 0,
            appBundleId: "com.microsoft.VSCode",
            windowTitle: nil, url: nil,
            ocrTextSnippet: "x",
            source: "lexical", score: nil
        )
        XCTAssertEqual(Formatters.contextLine(h), "com.microsoft.VSCode")
    }

    func testContextLineFallsBackToNoApp() {
        let h = Hit(
            eventId: 1, tsUs: 0,
            appBundleId: nil, windowTitle: nil, url: nil,
            ocrTextSnippet: "x",
            source: "lexical", score: nil
        )
        XCTAssertEqual(Formatters.contextLine(h), "(no app)")
    }

    func testSourceTagMapping() {
        XCTAssertEqual(Formatters.sourceTag("lexical"), "lex")
        XCTAssertEqual(Formatters.sourceTag("hybrid"), "hyb")
        XCTAssertEqual(Formatters.sourceTag("timeline"), "time")
        XCTAssertEqual(Formatters.sourceTag("custom"), "custom")
    }

    func testScoreStringFormatting() {
        XCTAssertEqual(Formatters.scoreString(0.0), "0.0%")
        XCTAssertEqual(Formatters.scoreString(1.0), "100.0%")
        XCTAssertEqual(Formatters.scoreString(0.123), "12.3%")
        XCTAssertEqual(Formatters.scoreString(nil), "")
    }

    func testScoreStringClampsOutOfRange() {
        XCTAssertEqual(Formatters.scoreString(-0.5), "0.0%")
        XCTAssertEqual(Formatters.scoreString(2.0), "100.0%")
    }

    // MARK: - relativeTime

    func testRelativeTimeJustNow() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "just now")
    }

    func testRelativeTimeMinutesAgo() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-180).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "3 min ago")
    }

    func testRelativeTimeOneHourAgo() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-3660).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "1 hour ago")
    }

    func testRelativeTimeMultipleHoursAgo() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-7260).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "2 hours ago")
    }

    func testRelativeTimeYesterday() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-100_000).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "yesterday")
    }

    func testRelativeTimeDaysAgo() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-475_200).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(Formatters.relativeTime(usSinceEpoch: tsUs, now: now), "5 days ago")
    }

    func testRelativeTimeFallsBackToAbsolute() {
        let now = Date()
        let tsUs = UInt64(now.addingTimeInterval(-90 * 86400).timeIntervalSince1970 * 1_000_000)
        let result = Formatters.relativeTime(usSinceEpoch: tsUs, now: now)
        XCTAssertTrue(result.hasSuffix("UTC"))
    }
}
