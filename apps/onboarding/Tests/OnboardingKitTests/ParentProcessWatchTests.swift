import XCTest
@testable import OnboardingKit

final class ParentProcessWatchTests: XCTestCase {
    private func start(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        return process
    }

    func testItCallsBackOnceWhenTheWatchedProcessExits() throws {
        let parent = try start("0.3")
        let exited = expectation(description: "exit seen")
        exited.assertForOverFulfill = true
        let watch = ParentProcessWatch(pid: parent.processIdentifier, queue: .global()) {
            exited.fulfill()
        }
        XCTAssertNotNil(watch)
        wait(for: [exited], timeout: 5)
        withExtendedLifetime(watch) {}
    }

    func testAParentAlreadyGoneIsSeenAtOnce() throws {
        let parent = try start("0")
        parent.waitUntilExit()
        let exited = expectation(description: "exit seen")
        let watch = ParentProcessWatch(pid: parent.processIdentifier, queue: .global()) {
            exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        withExtendedLifetime(watch) {}
    }

    func testLaunchdIsNoParentToWatch() {
        XCTAssertNil(ParentProcessWatch(pid: 1) {})
        XCTAssertNil(ParentProcessWatch(pid: 0) {})
    }
}
