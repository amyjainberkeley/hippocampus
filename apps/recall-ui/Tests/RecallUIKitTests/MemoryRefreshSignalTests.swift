import XCTest
@testable import RecallUIKit

final class MemoryRefreshSignalTests: XCTestCase {
    func testPostPublishesOnlyTheRefreshSignal() {
        let center = NotificationCenter()
        let delivered = expectation(description: "refresh signal delivered")
        delivered.expectedFulfillmentCount = 1
        let token = center.addObserver(
            forName: MemoryRefreshSignal.notification,
            object: nil,
            queue: nil
        ) { _ in
            delivered.fulfill()
        }
        defer { center.removeObserver(token) }

        MemoryRefreshSignal.post(center: center)

        wait(for: [delivered], timeout: 0.1)
    }
}
