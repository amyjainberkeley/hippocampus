// MCIEmptyStateTests.swift — pin the polished empty-state copy.
//
// Cycle 8.49 (audit-gap fix — "Missing empty states" in
// `docs/research/2026-07-13-product-readiness-audit.md`). The
// canonical named factories on `MCIEmptyState` are the source of truth
// for user-facing empty copy across the recall UI. These tests pin the
// icon + heading + body + action so a stray copy edit shows up in CI
// review, and so a factory change ripples explicitly.

import SwiftUI
import XCTest

@testable import RecallUIKit

final class MCIEmptyStateTests: XCTestCase {

    // MARK: - Structural invariants

    func testFullInitializerRoundTrip() {
        let called = XCTestExpectation(description: "action invoked")
        let state = MCIEmptyState(
            icon: "bolt",
            title: "T",
            message: "M",
            actionTitle: "Go",
            action: { called.fulfill() }
        )
        XCTAssertEqual(state.icon, "bolt")
        XCTAssertEqual(state.title, "T")
        XCTAssertEqual(state.message, "M")
        XCTAssertEqual(state.actionTitle, "Go")
        state.action?()
        wait(for: [called], timeout: 1.0)
    }

    func testActionOptionalByDefault() {
        let state = MCIEmptyState(icon: "x", title: "t", message: "m")
        XCTAssertNil(state.action)
        XCTAssertNil(state.actionTitle)
    }

    // MARK: - Canonical factories — copy pins

    func testFreshBrainCopy() {
        let s = MCIEmptyState.freshBrain()
        XCTAssertEqual(s.icon, "brain.head.profile")
        XCTAssertEqual(s.title, "Hippocampus is warming up")
        XCTAssertTrue(s.message.contains("Keep using your Mac normally"))
        XCTAssertNil(s.action)
    }

    func testNoSearchHitsEmbedsQueryVerbatim() {
        let s = MCIEmptyState.noSearchHits(query: "vector databases")
        XCTAssertEqual(s.icon, "sparkle.magnifyingglass")
        XCTAssertTrue(
            s.title.contains("vector databases"),
            "query must be echoed in heading — got \(s.title)"
        )
        XCTAssertTrue(s.message.contains("broader"))
        XCTAssertTrue(s.message.contains("custom names"))
        XCTAssertNil(s.action)
    }

    func testFilterTooNarrowExposesClearAction() {
        var cleared = false
        let s = MCIEmptyState.filterTooNarrow { cleared = true }
        XCTAssertEqual(s.icon, "line.3.horizontal.decrease.circle")
        XCTAssertEqual(s.title, "No memories match these filters")
        XCTAssertEqual(s.actionTitle, "Clear filters")
        XCTAssertNotNil(s.action)
        s.action?()
        XCTAssertTrue(cleared, "clear callback must fire")
    }

    func testStaleEventExposesBackAction() {
        var went = false
        let s = MCIEmptyState.staleEvent { went = true }
        XCTAssertEqual(s.icon, "tray")
        XCTAssertTrue(s.title.contains("no longer available"))
        XCTAssertEqual(s.actionTitle, "Back to search")
        s.action?()
        XCTAssertTrue(went)
    }

    func testNoPrivacyEventsFreshVariant() {
        let s = MCIEmptyState.noPrivacyEvents(hasActiveFilter: false)
        XCTAssertEqual(s.icon, "lock.shield")
        // Cycle 8.54 copy audit — "brain" → "memory" (see the copy
        // style guide §3, product-noun ruling).
        XCTAssertEqual(s.title, "Your memory is empty")
        XCTAssertTrue(s.message.contains("encrypted"))
        XCTAssertNil(s.action)
    }

    func testNoPrivacyEventsFilterVariant() {
        let s = MCIEmptyState.noPrivacyEvents(hasActiveFilter: true)
        XCTAssertEqual(s.icon, "line.3.horizontal.decrease.circle")
        XCTAssertTrue(s.title.contains("current filter"))
        XCTAssertTrue(s.message.contains("Widen"))
    }

    func testNoRelatedHitsCopy() {
        let s = MCIEmptyState.noRelatedHits()
        XCTAssertEqual(s.icon, "link")
        XCTAssertTrue(s.title.contains("cross-app connections"))
        XCTAssertNil(s.action)
    }

    func testNoPrivacyMomentsCopy() {
        let s = MCIEmptyState.noPrivacyMoments()
        XCTAssertEqual(s.icon, "eye.slash")
        XCTAssertTrue(s.title.contains("privacy moments"))
        XCTAssertTrue(s.message.contains("redact"))
    }

    func testNoEpisodesCopy() {
        let s = MCIEmptyState.noEpisodes()
        XCTAssertEqual(s.icon, "rectangle.stack")
        XCTAssertTrue(s.title.contains("episodes"))
    }

    func testNoTimelineEventsCopy() {
        let s = MCIEmptyState.noTimelineEvents()
        XCTAssertEqual(s.icon, "clock")
        XCTAssertTrue(s.title.contains("No events yet"))
        XCTAssertTrue(s.message.contains("background"))
    }

    // MARK: - Tone discipline

    func testNoCopyIsApologetic() {
        // Empty states must be reassuring/action-oriented, NEVER
        // apologetic. If a future edit adds "sorry" or "unfortunately",
        // CI catches it.
        let all: [MCIEmptyState] = [
            .freshBrain(),
            .noSearchHits(query: "x"),
            .filterTooNarrow(onClear: {}),
            .staleEvent(onBack: {}),
            .noPrivacyEvents(hasActiveFilter: false),
            .noPrivacyEvents(hasActiveFilter: true),
            .noRelatedHits(),
            .noPrivacyMoments(),
            .noEpisodes(),
            .noTimelineEvents(),
        ]
        let banned = ["sorry", "unfortunately", "oops", "failed"]
        for s in all {
            let combined = (s.title + " " + s.message).lowercased()
            for word in banned {
                XCTAssertFalse(
                    combined.contains(word),
                    "banned apologetic word \"\(word)\" in \(s.title)"
                )
            }
        }
    }

    func testActionableFactoriesActuallyExposeAction() {
        // The two factories that ship a button MUST have both a title
        // and a callback. A future refactor that drops the button but
        // forgets to remove the parameter would silently regress UX.
        let cleared = MCIEmptyState.filterTooNarrow(onClear: {})
        XCTAssertNotNil(cleared.action)
        XCTAssertNotNil(cleared.actionTitle)

        let back = MCIEmptyState.staleEvent(onBack: {})
        XCTAssertNotNil(back.action)
        XCTAssertNotNil(back.actionTitle)
    }

    // MARK: - View smoke test

    func testViewBuildsWithoutCrash() {
        // Instantiate the SwiftUI body accessor so a bad token
        // reference (e.g. a removed `MCI.Spacing` value) fails at
        // compile-time via the type-checker, not at runtime. This is a
        // headless smoke check; visual snapshot testing happens via
        // `#Preview` in Xcode.
        let states: [MCIEmptyState] = [
            .freshBrain(),
            .noSearchHits(query: "hello world"),
            .filterTooNarrow(onClear: {}),
        ]
        for s in states {
            _ = s.body
        }
    }
}
