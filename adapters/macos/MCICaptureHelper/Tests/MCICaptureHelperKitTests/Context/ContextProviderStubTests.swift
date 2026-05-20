// SPDX-License-Identifier: TBD-private
//
// ContextProviderStubTests — declares a `StubContextProvider` mirroring
// the `MockSecureEventInput` / `MockAX` / `MockBlackedRegion` pattern
// from SuppressionCascadeTests, and covers the stub's mechanics. The
// stub IS the test-double future PRs use to drive the cascade with
// synthetic context — P2.5 ships the SCStream wiring and the
// cascade-integration assertions; P2.1 only ships the stub
// mechanics so the seam is testable from day one.
//
// We do NOT exercise full cascade-decision matrices here — that lives
// in SuppressionCascadeTests and stays there. This file's job is to
// prove the `ContextProvider` trait is stubbable, sendable, and
// returns the value the test sets.

import XCTest
@testable import MCICaptureHelperKit

/// Stub `ContextProvider` that returns a value the test sets. Thread-
/// safe (the cascade-floor heartbeat in PR #39 + the SCStream
/// callback at P2.5 both touch the snapshot from multiple queues).
struct StubContextProvider: ContextProvider {
    let context: WorkflowContext
    init(_ context: WorkflowContext) {
        self.context = context
    }
    func snapshot() -> WorkflowContext { context }
}

final class ContextProviderStubTests: XCTestCase {
    func testStubReturnsConfiguredContext() {
        let ctx = WorkflowContext(appBundleId: "com.test.stub")
        let stub: any ContextProvider = StubContextProvider(ctx)
        XCTAssertEqual(stub.snapshot(), ctx)
    }

    func testStubAllowsFullyNilContext() {
        let stub: any ContextProvider = StubContextProvider(WorkflowContext())
        let snap = stub.snapshot()
        XCTAssertNil(snap.appBundleId)
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.url)
        XCTAssertNil(snap.pageText)
    }

    func testStubAllowsFullContext() {
        // ADR-0015 §1 — only `appBundleId` is wired in P2.1. P2.2–
        // P2.4 fill in `windowTitle` / `url`; Phase 3 fills
        // `pageText`. The stub MUST accept the full shape so cascade
        // tests landing those fields after P2.5 can use the same
        // stub.
        let ctx = WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: "Inbox — Mail",
            url: "https://mail.apple.com/",
            pageText: "(deferred to Phase 3)"
        )
        let stub: any ContextProvider = StubContextProvider(ctx)
        let snap = stub.snapshot()
        XCTAssertEqual(snap.appBundleId, "com.apple.Safari")
        XCTAssertEqual(snap.windowTitle, "Inbox — Mail")
        XCTAssertEqual(snap.url, "https://mail.apple.com/")
        XCTAssertEqual(snap.pageText, "(deferred to Phase 3)")
    }

    func testStubIsSendableAcrossTaskBoundaries() async {
        // The cascade is invoked from the SCStream `@Sendable`
        // callback; the `ContextProvider` it consumes must cross the
        // sendable boundary cleanly. This compile-time check is
        // load-bearing: a non-Sendable provider would fail to be
        // captured by the Task closure.
        let stub: any ContextProvider = StubContextProvider(
            WorkflowContext(appBundleId: "com.test.sendable")
        )
        let observed: WorkflowContext = await Task.detached {
            stub.snapshot()
        }.value
        XCTAssertEqual(observed.appBundleId, "com.test.sendable")
    }
}
