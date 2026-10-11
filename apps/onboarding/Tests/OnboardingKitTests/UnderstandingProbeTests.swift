import XCTest
@testable import OnboardingKit

final class UnderstandingProbeTests: XCTestCase {
    func testReadyLinesMapToAvailability() {
        XCTAssertEqual(UnderstandingProbe.availability(fromReadyLine: #"{"available":true,"ready":true}"#), .available)
        XCTAssertEqual(UnderstandingProbe.availability(fromReadyLine: #"{"available":false,"ready":true,"reason":"apple_intelligence_off"}"#), .turnedOff)
        XCTAssertEqual(UnderstandingProbe.availability(fromReadyLine: #"{"available":false,"ready":true,"reason":"model_not_ready"}"#), .preparing)
        XCTAssertEqual(UnderstandingProbe.availability(fromReadyLine: #"{"available":false,"ready":true,"reason":"device_not_eligible"}"#), .unsupported)
        XCTAssertEqual(UnderstandingProbe.availability(fromReadyLine: ""), .unsupported)
    }

    func testAMissingBinaryIsUnsupported() async {
        let result = await UnderstandingProbe.check(mind: nil)
        XCTAssertEqual(result, .unsupported)
    }
}
