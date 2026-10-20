import XCTest
@testable import RecallUIKit

/// The window shows its Demo tag only when the app opened it on Demo Memory
/// (SPEC-DELTA 6), and its words pass the copy rules.
final class DemoMemoryModeTests: XCTestCase {
    func testOnlyTheAppsOwnFlagTurnsItOn() {
        XCTAssertTrue(DemoMemoryMode.isOn(environment: ["MCI_DEMO_MEMORY": "1"]))
        for environment in [[:], ["MCI_DEMO_MEMORY": "0"], ["MCI_DEMO_MEMORY": "true"], ["MCI_DEMO_MEMORY": ""],
                            ["MCI_DB_PATH": "/tmp/demo/mci.sqlite"]] {
            XCTAssertFalse(DemoMemoryMode.isOn(environment: environment), "\(environment)")
        }
        XCTAssertEqual(DemoMemoryMode.environmentKey, "MCI_DEMO_MEMORY",
                       "the app's DemoMemory sets this exact name")
    }

    func testTheTagsWordsAreCalm() {
        for word in [DemoCopy.tag, DemoCopy.tagLabel] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
    }
}
