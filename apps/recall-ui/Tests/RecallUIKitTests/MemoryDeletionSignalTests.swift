import XCTest
import os
@testable import RecallUIKit

final class MemoryDeletionSignalTests: XCTestCase {
    private struct DeleteFailed: Error {}

    func testOnlyACommittedDeleteIsReported() async throws {
        let signal = MemoryDeletionSignal()
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let refreshes = OSAllocatedUnfairLock(initialState: 0)
        let deleted = signal.center.addObserver(forName: MemoryDeletionSignal.notification, object: signal, queue: nil) { _ in
            posts.withLock { $0 += 1 }
        }
        let refreshed = signal.center.addObserver(forName: MemoryRefreshSignal.notification, object: nil, queue: nil) { _ in
            refreshes.withLock { $0 += 1 }
        }
        defer {
            signal.center.removeObserver(deleted)
            signal.center.removeObserver(refreshed)
        }

        let result = try await signal.reporting { DeleteResult(eventsDeleted: 3, vacuumOk: true) }
        XCTAssertEqual(result.eventsDeleted, 3)
        XCTAssertEqual(posts.withLock { $0 }, 1)
        XCTAssertEqual(refreshes.withLock { $0 }, 1, "screens that read memory directly read again")
        XCTAssertEqual(signal.generation, 1)

        do {
            _ = try await signal.reporting { throw DeleteFailed() }
            XCTFail("a failed delete returned")
        } catch is DeleteFailed {}
        _ = try await signal.reporting { DeleteResult(committed: false, eventsDeleted: 0, vacuumOk: false) }
        XCTAssertEqual(posts.withLock { $0 }, 1)
        XCTAssertEqual(signal.generation, 1)
    }

    func testEveryDeleteTheStoreRunsIsReported() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUIKit/FFIBrainReader.swift"),
                                encoding: .utf8)
        let mutator = try XCTUnwrap(source.range(of: "extension FFIBrainReader: PrivacyMutator {"))
        let body = String(source[mutator.upperBound...])
        for function in ["func deleteEvent(", "func deleteEventsInRange(", "func wipeBrain("] {
            let start = try XCTUnwrap(body.range(of: function), function)
            let next = body.range(of: "public func", range: start.upperBound..<body.endIndex)?.lowerBound ?? body.endIndex
            XCTAssertTrue(body[start.upperBound..<next].contains("MemoryDeletionSignal.shared.reporting {"), function)
        }
        let prepare = try XCTUnwrap(body.range(of: "func prepareWipe("))
        let afterPrepare = body.range(of: "public func", range: prepare.upperBound..<body.endIndex)!.lowerBound
        XCTAssertFalse(body[prepare.upperBound..<afterPrepare].contains("reporting"), "preparing deletes nothing")
    }
}
