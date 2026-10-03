import XCTest
import UserNotifications
@testable import HippocampusKit

private final class DelayedAuthorizationCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var requests: [UNNotificationRequest] = []
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var addedCount: Int { lock.withLock { requests.count } }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { next in lock.withLock { continuation = next } }
    }
    func grant() { lock.withLock { continuation?.resume(returning: true); continuation = nil } }
    func add(_ request: UNNotificationRequest) async throws { lock.withLock { requests.append(request) } }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {}
    func removeDeliveredNotifications(withIdentifiers ids: [String]) {}
}

final class TCCDelayedAuthorizationTests: XCTestCase {
    private func waitForAuthorization(_ center: DelayedAuthorizationCenter) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !center.isWaiting && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(center.isWaiting, "authorization request must start within the deadline")
    }

    func testRestoredPermissionDoesNotPostLateRevocation() async throws {
        let center = DelayedAuthorizationCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let task = Task { await notifier.notifyRevoked(.screenRecording) }
        try await waitForAuthorization(center)
        await notifier.notifyRestored(.screenRecording)
        center.grant()
        await task.value
        XCTAssertEqual(center.addedCount, 0)
    }

    func testStoppedObservationDoesNotPostLateRevocation() async throws {
        let center = DelayedAuthorizationCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let task = Task { await notifier.notifyRevoked(.screenRecording) }
        try await waitForAuthorization(center)
        task.cancel()
        center.grant()
        await task.value
        XCTAssertEqual(center.addedCount, 0)
    }

    func testRestartedObservationRetainsItsNotificationAfterOldTaskIsCancelled() async throws {
        let center = DelayedAuthorizationCenter()
        let notifier = TCCRevokedNotifier(center: center)
        let oldTask = Task { await notifier.notifyRevoked(.screenRecording) }
        try await waitForAuthorization(center)
        oldTask.cancel()
        let newTask = Task { await notifier.notifyRevoked(.screenRecording) }
        try await Task.sleep(for: .milliseconds(100))
        center.grant()
        await oldTask.value
        await newTask.value
        XCTAssertEqual(center.addedCount, 1)
        let outstanding = await notifier.outstandingForTest()
        XCTAssertEqual(outstanding, [.screenRecording])
    }
}
