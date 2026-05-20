// SPDX-License-Identifier: TBD-private
//
// WorkflowContextSnapshotTests — pins the storage cell's contract per
// ADR-0015 §3 (bounded staleness, non-blocking hot-path read).
//
// Three properties:
//   1. Initial state is the all-nil `WorkflowContext()`.
//   2. `store(_:)` followed by `currentSync()` returns the stored value.
//   3. Concurrent writes serialize: after N parallel stores the final
//      `currentSync()` returns one of the N inputs (no torn-write,
//      no crash). The actor + lock provide this even when writers race.

import XCTest
@testable import MCICaptureHelperKit

final class WorkflowContextSnapshotTests: XCTestCase {
    func testInitialStateIsAllNil() {
        let snap = WorkflowContextSnapshot()
        let ctx = snap.currentSync()
        XCTAssertNil(ctx.appBundleId)
        XCTAssertNil(ctx.windowTitle)
        XCTAssertNil(ctx.url)
        XCTAssertNil(ctx.pageText)
    }

    func testStoreThenReadReturnsStoredValue() async {
        let snap = WorkflowContextSnapshot()
        let stored = WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: nil,
            url: nil,
            pageText: nil
        )
        await snap.store(stored)
        let observed = snap.currentSync()
        XCTAssertEqual(observed, stored)
    }

    func testStoreOverwritesPriorValue() async {
        let snap = WorkflowContextSnapshot()
        await snap.store(WorkflowContext(appBundleId: "com.apple.Safari"))
        await snap.store(WorkflowContext(appBundleId: "com.openai.chat"))
        XCTAssertEqual(snap.currentSync().appBundleId, "com.openai.chat")
    }

    func testConcurrentWritesSerializeWithoutCorruption() async {
        let snap = WorkflowContextSnapshot()
        // 64 concurrent writers, each writing a distinct bundle id.
        // After the task-group joins, the snapshot must hold exactly
        // one of the 64 inputs — any other state means a torn write
        // or a lost update.
        let ids = (0..<64).map { "com.test.app\($0)" }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await snap.store(WorkflowContext(appBundleId: id))
                }
            }
        }
        let final = snap.currentSync().appBundleId
        XCTAssertNotNil(final)
        XCTAssertTrue(
            ids.contains(final!),
            "final bundle id \(String(describing: final)) is not any of the writers' inputs — torn write?"
        )
        // Every other field stayed nil — writers only set
        // `appBundleId`.
        XCTAssertNil(snap.currentSync().windowTitle)
        XCTAssertNil(snap.currentSync().url)
        XCTAssertNil(snap.currentSync().pageText)
    }

    func testCurrentSyncIsNonBlockingHotPathSafe() {
        // Smoke test of the §3 hot-path contract: the SCStream
        // callback will call this synchronously from a `@Sendable`
        // closure. The test runs N synchronous reads on the calling
        // thread and asserts they all return the same all-nil value
        // (no `await`, no thread-hop, no actor enqueue).
        let snap = WorkflowContextSnapshot()
        for _ in 0..<1000 {
            let ctx = snap.currentSync()
            XCTAssertNil(ctx.appBundleId)
        }
    }
}
