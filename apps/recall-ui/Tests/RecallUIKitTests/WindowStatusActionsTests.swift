import XCTest
@testable import RecallUIKit

/// What the window's status controls ask of the app (SPEC 2.6.4): each is
/// the op the app carries out for that click. The app's own enum matches
/// these by the raw string.
final class WindowStatusActionsTests: XCTestCase {
    /// In Demo Memory the footer and the status menu offer one action,
    /// Leave Demo Memory. It is the app's own Leave, which keeps a pause the
    /// person made and works when remembering was off; a Resume would
    /// restart remembering against their pause, or be refused.
    func testLeaveDemoMemoryIsItsOwnOpNeverResume() throws {
        XCTAssertEqual(WindowStatusActions.effect(of: .leaveDemoMemory), .send(.leaveDemo))
        XCTAssertNotEqual(WindowStatusActions.effect(of: .leaveDemoMemory), .send(.resume))
        XCTAssertEqual(WindowChannelProtocol.Op.leaveDemo.rawValue, "leaveDemo")
        let line = try XCTUnwrap(WindowChannelRequest(id: "r1", op: .leaveDemo).line())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "leaveDemo")
    }

    func testEveryOtherControlKeepsItsOp() {
        XCTAssertEqual(WindowStatusActions.effect(of: .pause), .send(.pause))
        XCTAssertEqual(WindowStatusActions.effect(of: .resume), .send(.resume))
        XCTAssertEqual(WindowStatusActions.effect(of: .resumeNow), .send(.resume))
        XCTAssertEqual(WindowStatusActions.effect(of: .turnOn), .send(.turnOn))
        XCTAssertEqual(WindowStatusActions.effect(of: .tryAgain), .send(.tryAgain))
        XCTAssertEqual(WindowStatusActions.effect(of: .quit), .send(.quit))
        XCTAssertEqual(WindowStatusActions.effect(of: .openSystemSettings(.accessibility)),
                       .send(.openSystemSettings, permission: "accessibility"))
        XCTAssertEqual(WindowStatusActions.effect(of: .finishSetup), .finishSetup)
        XCTAssertEqual(WindowStatusActions.effect(of: .openHippocampus), .openHippocampus)
    }

    /// The window sends what the mapping says, and nothing of its own.
    func testTheShellSendsWhatTheMappingSays() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/MemoryWorkspaceView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("switch WindowStatusActions.effect(of: action) {"))
        XCTAssertFalse(source.contains("case .leaveDemoMemory:"), "Leave Demo Memory is never sent as Resume")
    }
}
