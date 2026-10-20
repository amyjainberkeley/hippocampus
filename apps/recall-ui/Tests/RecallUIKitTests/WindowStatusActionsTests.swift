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

    /// While a turn-on is under way the app offers Turn Off, and takes a
    /// pause only when it offers Pause: Turn Off is its own op.
    func testTurnOffIsItsOwnOpNeverPause() {
        XCTAssertEqual(WindowStatusActions.effect(of: .turnOff), .send(.turnOff))
        XCTAssertEqual(WindowChannelProtocol.Op.turnOff.rawValue, "turnOff")
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
        XCTAssertFalse(source.contains("case .turnOff: send(.pause)"))
        XCTAssertFalse(source.contains("case .leaveDemoMemory:"), "Leave Demo Memory is never sent as Resume")
    }

    // MARK: ⌘K's status command

    private let paused = WindowStatus(kind: .paused, title: "Paused", action: .resume)
    private let remembering = WindowStatus(kind: .remembering, title: "Remembering", action: .pause)

    /// ⌘K lists the one action the status offers now, as the menu does.
    func testCommandBarListsTheOneActionTheStatusOffers() {
        XCTAssertEqual(WindowStatusActions.command(for: paused, hasPipe: true), .resume)
        XCTAssertEqual(WindowStatusActions.command(for: remembering, hasPipe: true), .pause)
        XCTAssertEqual(WindowStatusActions.command(for: paused.inDemoMemory, hasPipe: true), .leaveDemoMemory)
        XCTAssertEqual(WindowStatusActions.command(
            for: WindowStatus(kind: .starting, title: "Starting", action: .turnOff), hasPipe: true), .turnOff)
    }

    /// None while a forget holds remembering, and none in a window opened by
    /// hand, which has no pipe: a row there would do nothing.
    func testCommandBarListsNothingTheAppWouldRefuse() {
        XCTAssertNil(WindowStatusActions.command(for: remembering, hasPipe: false))
        XCTAssertNil(WindowStatusActions.command(for: remembering.forgetting(.forgetting), hasPipe: true))
        XCTAssertNil(WindowStatusActions.command(for: WindowStatus(byHand: nil, appRunning: true), hasPipe: true))
        XCTAssertNil(WindowStatusActions.command(for: WindowStatus(byHand: nil, appRunning: false), hasPipe: false))
    }

    /// The window registers that one command with Go To's items, and the
    /// app's fixed Pause and Resume rows, one of which always did nothing,
    /// are gone.
    func testTheWindowRegistersItsOneStatusCommand() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/MemoryWorkspaceView.swift"),
                               encoding: .utf8)
        XCTAssertTrue(shell.contains(".registerActionPanelCommands(goToItems + statusCommands, registry: .shared)"))
        XCTAssertTrue(shell.contains("WindowStatusActions.command(for: shownStatus, hasPipe: channel != nil)"))
        let app = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/MCIRecallApp.swift"),
                             encoding: .utf8)
        XCTAssertFalse(app.contains("id: \"app.pause\""))
        XCTAssertFalse(app.contains("id: \"app.resume\""))
    }
}
