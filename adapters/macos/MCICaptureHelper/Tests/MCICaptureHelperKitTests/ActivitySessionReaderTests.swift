import CoreGraphics
import XCTest
@testable import MCICaptureHelperKit

final class ActivitySessionReaderTests: XCTestCase {
    private var session: [String: Any] {
        [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
         kCGSessionUserIDKey as String: 501]
    }

    func testRequiresOnConsoleLoggedInOwnerAndAwakeDisplay() {
        XCTAssertTrue(ActivitySessionReader.permitsMeasurement(session, userID: 501, displayAwake: true))
        XCTAssertFalse(ActivitySessionReader.permitsMeasurement(session, userID: 502, displayAwake: true))
        XCTAssertFalse(ActivitySessionReader.permitsMeasurement(session, userID: 501, displayAwake: false))
        XCTAssertFalse(ActivitySessionReader.permitsMeasurement(nil, userID: 501, displayAwake: true))
        for key in [kCGSessionOnConsoleKey as String, kCGSessionLoginDoneKey as String] {
            for value: Any in [false, "true", 1] {
                var input = session
                input[key] = value
                XCTAssertFalse(ActivitySessionReader.permitsMeasurement(input, userID: 501, displayAwake: true))
            }
            var missing = session
            missing.removeValue(forKey: key)
            XCTAssertFalse(ActivitySessionReader.permitsMeasurement(missing, userID: 501, displayAwake: true))
        }
    }

    func testLockOrMalformedLockSignalWithholdsAttribution() {
        for value: Any in [true, "false", 0, NSNull()] {
            var input = session
            input["CGSSessionScreenIsLocked"] = value
            XCTAssertFalse(ActivitySessionReader.permitsMeasurement(input, userID: 501, displayAwake: true))
        }
        var unlocked = session
        unlocked["CGSSessionScreenIsLocked"] = false
        XCTAssertTrue(ActivitySessionReader.permitsMeasurement(unlocked, userID: 501, displayAwake: true))
    }

    func testUIDMustBeExactlyIntegralAndPresent() {
        for value: Any in [501.9, -1, true, "501", NSNull(), Double.infinity] {
            var input = session
            input[kCGSessionUserIDKey as String] = value
            XCTAssertFalse(ActivitySessionReader.permitsMeasurement(input, userID: 501, displayAwake: true))
        }
        var missing = session
        missing.removeValue(forKey: kCGSessionUserIDKey as String)
        XCTAssertFalse(ActivitySessionReader.permitsMeasurement(missing, userID: 501, displayAwake: true))
    }
}
