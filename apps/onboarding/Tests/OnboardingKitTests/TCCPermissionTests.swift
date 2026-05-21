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
