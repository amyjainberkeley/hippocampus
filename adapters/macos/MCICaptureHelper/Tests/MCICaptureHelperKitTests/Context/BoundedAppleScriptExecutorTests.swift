import Foundation
import os
import XCTest
@testable import MCICaptureHelperKit

final class BoundedAppleScriptExecutorTests: XCTestCase {
    func testBlockedScriptDoesNotAccumulateJobsOrReuseItsLateResult() {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let executor = BoundedAppleScriptExecutor { source in
            calls.withLock { $0 += 1 }
            if source == "blocked" {
                entered.signal()
                release.wait()
            }
            return .success(source)
        }
        defer { release.signal() }
        // Under compiler load the executor may correctly discard a job before
        // its queue even starts. Establish an actual in-flight job first.
        let admissionDeadline = DispatchTime.now() + .seconds(10)
        var didEnter = false
        repeat {
            XCTAssertEqual(executor.run("blocked", timeoutMs: 100), .timeout)
            didEnter = entered.wait(timeout: .now()) == .success
        } while !didEnter && DispatchTime.now() < admissionDeadline
        guard didEnter else { return XCTFail("fixture worker never entered") }
        for _ in 0..<10 { XCTAssertEqual(executor.run("expired", timeoutMs: 10), .timeout) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(executor.run("fresh", timeoutMs: 5_000), .success("fresh"))
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testContendingCallExecutesItsOwnScriptAfterTheSlotBecomesFree() {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let executor = BoundedAppleScriptExecutor { source in
            if source == "first" {
                entered.signal()
                release.wait()
            }
            return .success(source)
        }
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = executor.run("first", timeoutMs: 500)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { release.signal() }
        XCTAssertEqual(executor.run("second", timeoutMs: 500), .success("second"))
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    }
}
