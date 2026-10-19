import XCTest
@testable import RecallUIKit

/// Opening Hippocampus while the window's process runs sends that process a
/// command. A process quitting after its last window closed, or one whose
/// window was minimized, took the command and showed nothing: the person
/// clicked and nothing appeared. The window now answers only when it will
/// show itself, and the app opens a fresh window when no answer comes.
final class WindowCommandAnswerTests: XCTestCase {
    private let open = RecallWindowState(isVisible: true, isMiniaturized: false)
    private let minimized = RecallWindowState(isVisible: false, isMiniaturized: true)
    private let closed = RecallWindowState(isVisible: false, isMiniaturized: false)

    func testAWindowThatIsOpenOrMinimizedShowsItself() {
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: false, windows: [open]), .show)
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: false, windows: [minimized]), .show)
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: false, windows: [closed, minimized]), .show)
    }

    func testAProcessThatIsQuittingOrHasNoWindowNeverAnswers() {
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: true, windows: [open]), .none)
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: false, windows: [closed]), .none)
        XCTAssertEqual(RecallCommandAnswer.decide(terminating: false, windows: []), .none)
    }

    func testEveryCommandButThePopupAloneBringsTheWindowForward() throws {
        XCTAssertTrue(try XCTUnwrap(RecallLaunchRequest(userInfo: ["open_popup": false])).bringsWindowForward,
                      "Open Hippocampus with no place keeps the place and still comes forward")
        XCTAssertTrue(try XCTUnwrap(RecallLaunchRequest(userInfo: ["tab": "overview"])).bringsWindowForward)
        XCTAssertTrue(RecallLaunchRequest(tab: nil, focusEventId: 42, openPopup: true).bringsWindowForward)
        XCTAssertFalse(try XCTUnwrap(RecallLaunchRequest(userInfo: ["open_popup": true])).bringsWindowForward)
    }

    func testTheAnswerNamesTheRequestAndNothingElse() {
        XCTAssertEqual(
            RecallLaunchRequest.acknowledgement(for: ["tab": "overview", "request_id": "A1B2"]),
            ["request_id": "A1B2"]
        )
        XCTAssertNil(RecallLaunchRequest.acknowledgement(for: ["tab": "overview"]), "an older app asks for no answer")
        XCTAssertNil(RecallLaunchRequest.acknowledgement(for: ["request_id": ""]))
        XCTAssertNotEqual(RecallLaunchRequest.acknowledgementName, RecallLaunchRequest.distributedCommandName)
    }
}
