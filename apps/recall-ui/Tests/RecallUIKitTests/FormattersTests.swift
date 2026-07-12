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

    // MARK: - matchReason (cycle 8.36 PR-2, audit §5 G6)

    func testMatchReasonMapsLexicalToPlainEnglish() {
        XCTAssertEqual(Formatters.matchReason("lexical"), "Matched: text")
    }

    func testMatchReasonMapsHybridToPlainEnglish() {
        XCTAssertEqual(Formatters.matchReason("hybrid"), "Matched: meaning")
    }

    func testMatchReasonTimelineIsNil() {
        // Chronological rows have no match reason worth showing —
        // caller must render nothing (not the raw tag).
        XCTAssertNil(Formatters.matchReason("timeline"))
    }

    func testMatchReasonUnknownSourceIsNil() {
        // Forward-compat: a future retrieval mode shouldn't leak raw
        // jargon into the UI. Callers hide the label until the mapping
        // is extended.
        XCTAssertNil(Formatters.matchReason("custom"))
        XCTAssertNil(Formatters.matchReason(""))
    }

    // MARK: - entityChipDisplay

    func testEntityChipDisplayUnderCapShowsAll() {
        let d = Formatters.entityChipDisplay(["a", "b", "c"])
        XCTAssertEqual(d.visible, ["a", "b", "c"])
        XCTAssertEqual(d.overflow, 0)
    }

    func testEntityChipDisplayAtCapShowsAllNoOverflow() {
        // Cap defaults to 5 — the boundary case must not report overflow.
        let d = Formatters.entityChipDisplay(["a", "b", "c", "d", "e"])
        XCTAssertEqual(d.visible.count, 5)
        XCTAssertEqual(d.overflow, 0)
    }

    func testEntityChipDisplayOverCapTruncates() {
        let d = Formatters.entityChipDisplay(
            ["a", "b", "c", "d", "e", "f", "g"]
        )
        XCTAssertEqual(d.visible, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(d.overflow, 2)
    }

    func testEntityChipDisplayPreservesOriginalOrder() {
        let d = Formatters.entityChipDisplay(
            ["MCP", "Anthropic", "vector-db", "sqlite-vec", "embedding", "MCI"]
        )
        XCTAssertEqual(
            d.visible,
            ["MCP", "Anthropic", "vector-db", "sqlite-vec", "embedding"]
        )
        XCTAssertEqual(d.overflow, 1)
    }

    func testEntityChipDisplayEmptyList() {
        let d = Formatters.entityChipDisplay([])
        XCTAssertEqual(d.visible, [])
        XCTAssertEqual(d.overflow, 0)
    }

    func testEntityChipDisplayCustomCap() {
        let d = Formatters.entityChipDisplay(["a", "b", "c", "d"], cap: 2)
        XCTAssertEqual(d.visible, ["a", "b"])
        XCTAssertEqual(d.overflow, 2)
    }

    func testEntityChipDisplayZeroCapReportsAllAsOverflow() {
        // Defensive: cap == 0 shouldn't crash; reports everything hidden.
        let d = Formatters.entityChipDisplay(["a", "b"], cap: 0)
        XCTAssertEqual(d.visible, [])
        XCTAssertEqual(d.overflow, 2)
    }

    // MARK: - linkedBadge

    func testLinkedBadgeEmptyIsNil() {
        XCTAssertNil(Formatters.linkedBadge([]))
    }

    func testLinkedBadgeSingularOne() {
        XCTAssertEqual(Formatters.linkedBadge([42]), "1 related")
    }

    func testLinkedBadgePluralMany() {
        XCTAssertEqual(Formatters.linkedBadge([1, 2, 3, 4, 5]), "5 related")
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

    // MARK: - stripContextHeader

    func testStripContextHeaderRemovesFullPrefix() {
        let raw =
            "[app=com.apple.Safari | title=spur | url=https://spur.example/dashboard | ts=2026-05-29T00:00:00.000Z]\nhello world"
        XCTAssertEqual(Formatters.stripContextHeader(raw), "hello world")
    }

    func testStripContextHeaderRemovesPrefixWithQuestionMarkPlaceholders() {
        // brain_ingest::compose_context_header emits `?` for missing fields.
        let raw = "[app=? | title=? | url=? | ts=2026-05-29T00:00:00.000Z]\nbody"
        XCTAssertEqual(Formatters.stripContextHeader(raw), "body")
    }

    func testStripContextHeaderPreservesEmptyBody() {
        // Browser-URL events produce a snippet that is just the prefix.
        let raw = "[app=com.apple.Safari | title=? | url=https://x | ts=2026-05-29T00:00:00.000Z]\n"
        XCTAssertEqual(Formatters.stripContextHeader(raw), "")
    }

    func testStripContextHeaderPreservesMultilineBody() {
        let raw =
            "[app=com.apple.Safari | title=spur | url=https://x | ts=2026-05-29T00:00:00.000Z]\nline 1\nline 2\nline 3"
        XCTAssertEqual(
            Formatters.stripContextHeader(raw),
            "line 1\nline 2\nline 3"
        )
    }

    func testStripContextHeaderLeavesNonPrefixInputUnchanged() {
        XCTAssertEqual(Formatters.stripContextHeader("hello"), "hello")
        XCTAssertEqual(Formatters.stripContextHeader(""), "")
    }

    func testStripContextHeaderLeavesPartialPrefixUnchanged() {
        // Missing `| url=` token — must not consume.
        let raw = "[app=com.apple.Safari | title=spur | ts=...]\nbody"
        XCTAssertEqual(Formatters.stripContextHeader(raw), raw)
    }

    func testStripContextHeaderDoesNotMatchBodyResemblingPrefix() {
        // No leading `[app=` — anchored at start, so unchanged.
        let raw =
            "preamble\n[app=com.apple.Safari | title=t | url=u | ts=ts]\nbody"
        XCTAssertEqual(Formatters.stripContextHeader(raw), raw)
    }

    // MARK: - sourceLabel

    func testSourceLabelPageContentWhenUrlAndTextPresent() {
        let snippet =
            "[app=com.apple.Safari | title=spur | url=https://x | ts=2026-05-29T00:00:00.000Z]\nactual body"
        XCTAssertEqual(
            Formatters.sourceLabel(url: "https://x", textSnippet: snippet),
            "Page Content"
        )
    }

    func testSourceLabelOCRTextWhenNoUrlButTextPresent() {
        let snippet =
            "[app=com.apple.dt.Xcode | title=ViewModel.swift | url=? | ts=2026-05-29T00:00:00.000Z]\nfunc foo()"
        XCTAssertEqual(
            Formatters.sourceLabel(url: nil, textSnippet: snippet),
            "OCR Text"
        )
        XCTAssertEqual(
            Formatters.sourceLabel(url: "", textSnippet: snippet),
            "OCR Text"
        )
    }

    func testSourceLabelBrowserURLWhenUrlPresentButTextEmpty() {
        let snippet =
            "[app=com.apple.Safari | title=? | url=https://x | ts=2026-05-29T00:00:00.000Z]\n"
        XCTAssertEqual(
            Formatters.sourceLabel(url: "https://x", textSnippet: snippet),
            "Browser URL"
        )
    }

    func testSourceLabelEventWhenAllEmpty() {
        let snippet = "[app=? | title=? | url=? | ts=2026-05-29T00:00:00.000Z]\n"
        XCTAssertEqual(
            Formatters.sourceLabel(url: nil, textSnippet: snippet),
            "Event"
        )
    }
}
