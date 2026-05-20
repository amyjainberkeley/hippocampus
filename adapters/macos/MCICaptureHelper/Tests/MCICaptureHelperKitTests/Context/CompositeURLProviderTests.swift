// SPDX-License-Identifier: TBD-private
//
// CompositeURLProviderTests — pin the per-call walk semantics for
// `CompositeURLProvider`. ADR-0015 §6 P2.4 + §7.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Stub-driven, OS-free; the
// underlying single-browser providers are replaced by
// `StubURLProvider`s that record their invocations so the test can
// assert (a) first-non-nil-wins semantics, (b) all-nil → nil,
// (c) order-independence on the disjoint bundle-id set the
// production composition uses.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: – Test doubles

/// Stub `URLProvider`: answers for one bundle id, returns a fixed
/// value, records invocations.
private final class StubURLProvider: URLProvider, @unchecked Sendable {
    let answersFor: String
    let value: String?
    private let lock = NSLock()
    private var _calls: [String] = []

    init(answersFor: String, value: String?) {
        self.answersFor = answersFor
        self.value = value
    }

    func activeTabURL(forFrontmost bundleId: String) -> String? {
        lock.lock(); _calls.append(bundleId); lock.unlock()
        return bundleId == answersFor ? value : nil
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }; return _calls
    }
}

final class CompositeURLProviderTests: XCTestCase {
    // MARK: – first non-nil wins

    /// Walk returns the first non-nil result. Subsequent providers
    /// are still consulted only if the earlier one returned nil.
    func testReturnsFirstNonNilResult() {
        let p1 = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://safari.example/"
        )
        let p2 = StubURLProvider(
            answersFor: "com.google.Chrome",
            value: "https://chrome.example/"
        )
        let composite = CompositeURLProvider(providers: [p1, p2])

        XCTAssertEqual(
            composite.activeTabURL(forFrontmost: "com.apple.Safari"),
            "https://safari.example/"
        )
        XCTAssertEqual(p1.calls, ["com.apple.Safari"])
        XCTAssertEqual(
            p2.calls, [],
            "Walk must stop at the first non-nil result"
        )
    }

    /// First provider returns nil; walk continues to the second,
    /// which returns the value.
    func testContinuesPastNilProviders() {
        let p1 = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://safari.example/"
        )
        let p2 = StubURLProvider(
            answersFor: "com.google.Chrome",
            value: "https://chrome.example/"
        )
        let composite = CompositeURLProvider(providers: [p1, p2])

        XCTAssertEqual(
            composite.activeTabURL(forFrontmost: "com.google.Chrome"),
            "https://chrome.example/"
        )
        XCTAssertEqual(
            p1.calls, ["com.google.Chrome"],
            "P1 must still be consulted (returns nil) before P2"
        )
        XCTAssertEqual(p2.calls, ["com.google.Chrome"])
    }

    // MARK: – all-nil walk

    /// All providers return nil → composite returns nil; every
    /// provider was consulted exactly once.
    func testReturnsNilWhenAllProvidersReturnNil() {
        let p1 = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://safari/"
        )
        let p2 = StubURLProvider(
            answersFor: "com.google.Chrome",
            value: "https://chrome/"
        )
        let p3 = StubURLProvider(
            answersFor: "org.mozilla.firefox",
            value: "https://firefox/"
        )
        let composite = CompositeURLProvider(providers: [p1, p2, p3])

        XCTAssertNil(
            composite.activeTabURL(forFrontmost: "com.unrelated.app")
        )
        XCTAssertEqual(p1.calls, ["com.unrelated.app"])
        XCTAssertEqual(p2.calls, ["com.unrelated.app"])
        XCTAssertEqual(p3.calls, ["com.unrelated.app"])
    }

    /// Empty composite → always nil. Documents the degenerate case.
    func testEmptyCompositeReturnsNil() {
        let composite = CompositeURLProvider(providers: [])
        XCTAssertNil(composite.activeTabURL(forFrontmost: "com.apple.Safari"))
        XCTAssertNil(composite.activeTabURL(forFrontmost: ""))
    }

    // MARK: – order independence on disjoint bundle ids

    /// With providers that answer for DISJOINT bundle ids (the
    /// production composition shape — Safari / Chromium-family /
    /// Firefox-family / Arc), the per-call walk result is invariant
    /// under provider reordering. Pins the ADR-0015 §1.3 design note
    /// that ordering matters only when impls overlap (and they
    /// shouldn't, by construction).
    func testReorderingIsSemanticallyEquivalentOnDisjointBundleIds() {
        let safari = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://safari/"
        )
        let chrome = StubURLProvider(
            answersFor: "com.google.Chrome",
            value: "https://chrome/"
        )
        let firefox = StubURLProvider(
            answersFor: "org.mozilla.firefox",
            value: "https://firefox/"
        )
        let arc = StubURLProvider(
            answersFor: "company.thebrowser.Browser",
            value: "https://arc/"
        )

        let aOrder = CompositeURLProvider(
            providers: [safari, chrome, firefox, arc]
        )
        let bOrder = CompositeURLProvider(
            providers: [arc, firefox, chrome, safari]
        )

        let bundles = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "company.thebrowser.Browser",
            "com.unrelated.app",
            "",
        ]
        for b in bundles {
            XCTAssertEqual(
                aOrder.activeTabURL(forFrontmost: b),
                bOrder.activeTabURL(forFrontmost: b),
                "Result must be order-independent on disjoint bundle"
                + " ids — failed for bundle: \(b)"
            )
        }
    }

    /// When two providers both answer for the SAME bundle id
    /// (deliberately violating the ADR-0015 §1.3 disjointness rule),
    /// the FIRST in construction order wins and the second is never
    /// consulted. Pins the documented "first match wins" behaviour
    /// so a future maintainer adding an overlapping provider
    /// understands the determinism.
    func testFirstMatchWinsOnOverlap() {
        let earlier = StubURLProvider(
            answersFor: "com.example.Both",
            value: "https://earlier/"
        )
        let later = StubURLProvider(
            answersFor: "com.example.Both",
            value: "https://later/"
        )
        let composite = CompositeURLProvider(
            providers: [earlier, later]
        )

        XCTAssertEqual(
            composite.activeTabURL(forFrontmost: "com.example.Both"),
            "https://earlier/"
        )
        XCTAssertEqual(later.calls, [])
    }
}
