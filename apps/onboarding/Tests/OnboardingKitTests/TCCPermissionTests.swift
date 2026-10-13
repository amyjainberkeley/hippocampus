import XCTest
@testable import OnboardingKit

@MainActor
final class TCCPermissionTests: XCTestCase {

    func testStubInitialStatusIsNotRequested() {
        let perm = StubTCCPermission(kind: .screenRecording)
        XCTAssertEqual(perm.status, .notRequested)
        XCTAssertEqual(perm.checkCurrent(), .notRequested)
    }

    func testSimulateGrantTransitions() {
        let perm = StubTCCPermission(kind: .accessibility)
        XCTAssertEqual(perm.status, .notRequested)
        perm.simulateGrant()
        XCTAssertEqual(perm.status, .granted)
        XCTAssertEqual(perm.checkCurrent(), .granted)
    }

    func testSimulateDenyTransitions() {
        let perm = StubTCCPermission(kind: .screenRecording)
        perm.simulateDeny()
        XCTAssertEqual(perm.status, .denied)
    }

    func testRequestOrOpenSettingsIncrements() {
        let perm = StubTCCPermission(kind: .automation)
        XCTAssertEqual(perm.openSettingsCallCount, 0)
        perm.requestOrOpenSettings()
        XCTAssertEqual(perm.openSettingsCallCount, 1)
        perm.requestOrOpenSettings()
        XCTAssertEqual(perm.openSettingsCallCount, 2)
    }

    func testAllKindsRepresented() {
        XCTAssertEqual(TCCPermissionKind.allCases.count, 3)
        XCTAssertTrue(TCCPermissionKind.allCases.contains(.screenRecording))
        XCTAssertTrue(TCCPermissionKind.allCases.contains(.accessibility))
        XCTAssertTrue(TCCPermissionKind.allCases.contains(.automation))
    }

    func testInitWithExplicitStatus() {
        let perm = StubTCCPermission(kind: .screenRecording, status: .granted)
        XCTAssertEqual(perm.status, .granted)
    }
}

/// A permission that only has the request every permission has.
@MainActor
private final class PlainPermission: TCCPermission, @unchecked Sendable {
    let kind: TCCPermissionKind = .automation
    private(set) var status: TCCStatus = .notRequested
    private(set) var requests = 0
    func checkCurrent() -> TCCStatus { status }
    func requestOrOpenSettings() { requests += 1 }
    func resetAndRetry() async -> Bool { false }
    func openPrivacySettings() {}
}

@MainActor
final class TCCPermissionDefaultsTests: XCTestCase {
    func testAPermissionWithoutItsOwnPromptAsksTheWayItAlwaysHas() async {
        let permission = PlainPermission()
        permission.requestPrompt()
        XCTAssertEqual(permission.requests, 1)
        await permission.askAgain()
        XCTAssertEqual(permission.requests, 2, "Ask Again asks the way Allow does")
    }
}
