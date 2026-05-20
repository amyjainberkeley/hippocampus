// SPDX-License-Identifier: TBD-private
//
// URLProviderStubTests — pin the `URLProvider` trait contract via a
// stub impl. Mirrors the `StubSecureEventInputProbe` / stub-pattern
// established by the §7-corpus probes (PRs #36/#37/#38) — OS-free,
// headless, fast. ADR-0015 §6 P2.3 + §7.
//
// Scope: the per-bundle dispatch logic lives in the composite (ADR-
// 0015 §1.3, lands at P2.4). This test pins the *trait* invariant:
// each per-browser impl gets to choose which bundle ids it answers
// for, and returns `nil` for everything else.

import XCTest

@testable import MCICaptureHelperKit

/// Stub `URLProvider` that answers for one configured bundle id and
/// returns a configured value for it; `nil` for any other bundle id.
private struct StubURLProvider: URLProvider {
    let answersFor: String
    let value: String?
    func activeTabURL(forFrontmost bundleId: String) -> String? {
        bundleId == answersFor ? value : nil
    }
}

final class URLProviderStubTests: XCTestCase {
    /// Stub returns its configured value for the matching bundle id.
    func testStubReturnsConfiguredValueForMatchingBundleId() {
        let p = StubURLProvider(
            answersFor: "com.example.Browser",
            value: "https://example.com/page"
        )
        XCTAssertEqual(
            p.activeTabURL(forFrontmost: "com.example.Browser"),
            "https://example.com/page"
        )
    }

    /// Stub returns nil for a non-matching bundle id even when a
    /// value is configured. Pins the "this provider does not handle
    /// that browser" leg of the trait contract.
    func testStubReturnsNilForNonMatchingBundleId() {
        let p = StubURLProvider(
            answersFor: "com.example.Browser",
            value: "https://example.com/page"
        )
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.other.Browser"))
    }

    /// Stub returns nil for its own bundle id when the configured
    /// value is nil. Pins the "browser is the right one but no URL
    /// available right now" leg (e.g. browser running but no front
    /// document).
    func testStubReturnsNilWhenConfiguredValueIsNil() {
        let p = StubURLProvider(
            answersFor: "com.example.Browser",
            value: nil
        )
        XCTAssertNil(p.activeTabURL(forFrontmost: "com.example.Browser"))
    }

    /// Empty bundle id resolves to nil for a stub that answers for a
    /// specific id. Documents the "frontmost-app-unknown" call site
    /// (the snapshot actor passes "" / nil-collapsed-to-"" when
    /// NSWorkspace returns no frontmost application).
    func testStubReturnsNilForEmptyBundleId() {
        let p = StubURLProvider(
            answersFor: "com.example.Browser",
            value: "https://example.com/"
        )
        XCTAssertNil(p.activeTabURL(forFrontmost: ""))
    }
}
