import Foundation
import os
import XCTest
@testable import MCICaptureHelperKit

final class AXFocusedApplicationSourceTests: XCTestCase {
    func testEveryReadUsesTheCurrentFocusedProcess() {
        let pid = OSAllocatedUnfairLock<pid_t>(initialState: 10)
        let source = AXFocusedApplicationSource(
            focusedPID: { pid.withLock { $0 } },
            bundleID: { "test.app.\($0)" }
        )
        XCTAssertEqual(source.frontmostPidAndBundle()?.0, 10)
        pid.withLock { $0 = 20 }
        XCTAssertEqual(source.frontmostPidAndBundle()?.0, 20)
        XCTAssertEqual(source.currentBundleId(), "test.app.20")
    }

    func testFocusChangeDuringBundleResolutionFailsClosed() {
        let pid = OSAllocatedUnfairLock<pid_t>(initialState: 10)
        let source = AXFocusedApplicationSource(
            focusedPID: { pid.withLock { $0 } },
            bundleID: { _ in pid.withLock { $0 = 20 }; return "test.old" }
        )
        XCTAssertNil(source.frontmostPidAndBundle())
    }

    func testMissingOrInvalidPIDNeverResolvesAnApplication() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        for pid: pid_t? in [nil, 0, -1] {
            let source = AXFocusedApplicationSource(
                focusedPID: { pid },
                bundleID: { _ in calls.withLock { $0 += 1 }; return "test.app" }
            )
            XCTAssertNil(source.frontmostPidAndBundle())
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testMissingOrEmptyBundleFailsClosed() {
        for bundle: String? in [nil, "", "   "] {
            let source = AXFocusedApplicationSource(focusedPID: { 10 }, bundleID: { _ in bundle })
            XCTAssertNil(source.frontmostPidAndBundle())
        }
    }

    func testTimedOutQueryDoesNotQueueMoreWorkOrReuseALatePID() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let query = BoundedFocusedPIDQuery {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                entered.signal()
                release.wait()
                return 10
            }
            return 20
        }
        defer { release.signal() }
        XCTAssertNil(query.read(timeoutMs: 10))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 0..<20 { XCTAssertNil(query.read(timeoutMs: 10)) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        release.signal()

        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var next: pid_t?
        repeat {
            next = query.read()
            if next == nil { Thread.sleep(forTimeInterval: 0.001) }
        } while next == nil && ProcessInfo.processInfo.systemUptime < deadline
        XCTAssertEqual(next, 20, "The late answer from the timed-out request must never be reused")
    }

    func testContendingReaderWaitsWithinItsBudgetThenMakesAFreshQuery() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let query = BoundedFocusedPIDQuery {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                entered.signal()
                release.wait()
            }
            return pid_t(call)
        }
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = query.read(timeoutMs: 500)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
            release.signal()
        }
        XCTAssertEqual(query.read(timeoutMs: 500), 2,
                       "An ordinary overlapping query must not invalidate stable focus or reuse the first answer")
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
}
