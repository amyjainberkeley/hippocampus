#if canImport(AppKit)
import XCTest
@testable import OnboardingKit

@MainActor
final class RealTCCPermissionTests: XCTestCase {

    // Smoke tests: exercise API surface without asserting OS-level outcomes.
    // Real TCC state depends on the host Mac's permission database.

    func testScreenRecordingInitDoesNotCrash() {
        let perm = RealScreenRecordingPermission()
        XCTAssertEqual(perm.kind, .screenRecording)
        let _ = perm.status
    }

    func testScreenRecordingCheckCurrentReturnsValidStatus() {
        let perm = RealScreenRecordingPermission()
        let status = perm.checkCurrent()
        XCTAssertTrue([TCCStatus.granted, .denied].contains(status))
    }

    func testAccessibilityInitDoesNotCrash() {
        let perm = RealAccessibilityPermission()
        XCTAssertEqual(perm.kind, .accessibility)
        let _ = perm.status
    }

    func testAccessibilityCheckCurrentReturnsValidStatus() {
        let perm = RealAccessibilityPermission()
        let status = perm.checkCurrent()
        XCTAssertTrue([TCCStatus.granted, .denied].contains(status))
    }

    func testAutomationInitDoesNotCrash() {
        let perm = RealAutomationPermission()
        XCTAssertEqual(perm.kind, .automation)
        XCTAssertEqual(perm.status, .notRequested)
    }

    func testAllRealPermissionsConformToProtocol() {
        let perms: [any TCCPermission] = [
            RealScreenRecordingPermission(),
            RealAccessibilityPermission(),
            RealAutomationPermission(),
        ]
        XCTAssertEqual(perms.count, 3)
        for perm in perms {
            XCTAssertFalse(perm.kind.rawValue.isEmpty)
        }
    }
}
#endif
