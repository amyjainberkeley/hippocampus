// SPDX-License-Identifier: Apache-2.0
//
// The app's end of the window's private pipe (SPEC 2.6.4): malformed and
// unknown lines are ignored, Turn On is refused before setup, the app does
// only what the menu bar's same click would do, the window's status follows
// the menu bar's own words, and a distributed notification can't change
// remembering. The pipes here are made for each test: nothing reaches a
// running Hippocampus or its window.

import Darwin
import XCTest
@testable import HippocampusKit

@MainActor
final class WindowChannelServerTests: XCTestCase {
    // MARK: Lines

    private func line(_ text: String) -> Data { Data(text.utf8) }

    func testOnlyRequestsThisVersionKnowsAreTaken() {
        let pause = WindowChannelRequest.parse(line(
            #"{"v":1,"id":"r1","op":"pause","until":"2026-10-12T15:40:00-07:00"}"#))
        XCTAssertEqual(pause, WindowChannelRequest(id: "r1", op: .pause,
                                                   until: Date(timeIntervalSince1970: 1_791_844_800)))
        XCTAssertEqual(WindowChannelRequest.parse(line(#"{"v":1,"id":"r2","op":"resume"}"#))?.op, .resume)
        XCTAssertEqual(WindowChannelRequest.parse(line(
            #"{"v":1,"id":"r3","op":"openSystemSettings","permission":"accessibility"}"#))?.permission, .accessibility)
        for text in [
            "not json", "{}", #"{"v":2,"id":"r","op":"pause"}"#, #"{"v":1,"op":"pause"}"#,
            #"{"v":1,"id":"","op":"pause"}"#, #"{"v":1,"id":"r","op":"wipe"}"#,
            #"{"v":1,"id":"r","op":"status","state":"remembering","title":"Remembering"}"#,
            #"{"v":1,"id":"r","op":"resume","until":"2026-10-12T15:40:00-07:00"}"#,
            #"{"v":1,"id":"r","op":"pause","until":"tomorrow"}"#,
            #"{"v":1,"id":"r","op":"openSystemSettings"}"#,
            #"{"v":1,"id":"r","op":"openSystemSettings","permission":"fullDiskAccess"}"#,
            "{\"v\":1,\"id\":\"\(String(repeating: "x", count: 65))\",\"op\":\"pause\"}",
            "{\"v\":1,\"id\":\"r\",\"op\":\"pause\",\"pad\":\"\(String(repeating: "x", count: 4_100))\"}",
        ] {
            XCTAssertNil(WindowChannelRequest.parse(line(text)), text.prefix(80).description)
        }
    }

    // MARK: The app decides

    private func row(_ action: CaptureStatusAction?) -> StatusRow {
        StatusRow(title: "x", detail: nil, action: action)
    }

    private func request(_ op: WindowChannelRequest.Op, _ permission: TCCRevokedReason? = nil) -> WindowChannelRequest {
        WindowChannelRequest(id: "r", op: op, permission: permission)
    }

    func testTheWindowMayDoOnlyWhatTheMenuBarsSameClickWould() {
        // Turn On only once setup is finished: before it, the row offers
        // Finish Setup…, and Turn On is refused.
        XCTAssertFalse(WindowChannelPolicy.allows(request(.turnOn), row: row(.finishSetup), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.turnOn), row: row(.turnOn), holding: false))
        // Resume only while paused.
        XCTAssertFalse(WindowChannelPolicy.allows(request(.resume), row: row(.pause), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.resume), row: row(.resume), holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.pause), row: row(.resume), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.pause), row: row(.pause), holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.pause), row: row(nil), holding: false),
                       "while a stop is under way nothing is offered")
        XCTAssertFalse(WindowChannelPolicy.allows(request(.tryAgain), row: row(.pause), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.tryAgain), row: row(.tryAgain), holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.quit), row: row(.pause), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.quit), row: row(.quit), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.openSystemSettings, .screenRecording),
                                                 row: row(.openSystemSettings(.screenRecording)), holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.openSystemSettings, .accessibility),
                                                  row: row(.openSystemSettings(.screenRecording)), holding: false))
        // One hold at a time; a release only while holding.
        XCTAssertTrue(WindowChannelPolicy.allows(request(.hold), row: row(.pause), holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.hold), row: row(.pause), holding: true))
        XCTAssertFalse(WindowChannelPolicy.allows(request(.release), row: row(.pause), holding: false))
        XCTAssertTrue(WindowChannelPolicy.allows(request(.release), row: row(nil), holding: true))
    }

    /// Leave Demo Memory is the menu's own item beside the row: the window
    /// may send it whenever Demo Memory is in use, whatever the row offers
    /// (paused by the person, or Off with Turn On), and never otherwise.
    func testLeaveDemoMemoryIsTakenOnlyWhileDemoMemoryIsInUse() {
        XCTAssertEqual(WindowChannelRequest.parse(line(#"{"v":1,"id":"l1","op":"leaveDemo"}"#))?.op, .leaveDemo)
        XCTAssertNil(WindowChannelRequest.parse(line(
            #"{"v":1,"id":"l2","op":"leaveDemo","until":"2026-10-12T15:40:00-07:00"}"#)), "only a pause has an end")
        for action in [CaptureStatusAction.resume, .turnOn, .pause, .tryAgain, nil] {
            XCTAssertTrue(WindowChannelPolicy.allows(request(.leaveDemo), row: row(action), holding: false,
                                                     demoMemory: true), "\(String(describing: action))")
            XCTAssertFalse(WindowChannelPolicy.allows(request(.leaveDemo), row: row(action), holding: false,
                                                      demoMemory: false), "\(String(describing: action))")
        }
        XCTAssertFalse(WindowChannelPolicy.allows(request(.leaveDemo), row: row(.resume), holding: false),
                       "Demo Memory is not in use unless the app says so")
        XCTAssertFalse(WindowChannelPolicy.allows(request(.leaveDemo), row: row(nil), holding: true, demoMemory: true),
                       "never in the middle of a forget")
        // Resume is still only the row's own Resume: the window's Leave is
        // never carried out as one.
        XCTAssertFalse(WindowChannelPolicy.allows(request(.resume), row: row(.turnOn), holding: false,
                                                  demoMemory: true))
    }

    @MainActor
    private final class Performed {
        var actions: [CaptureStatusAction] = []
    }

    /// While a turn-on is under way the row offers Turn Off, and the window
    /// shows it. The window's Turn Off is carried out as the menu's, and is
    /// taken only while the row offers it; a Pause is still only the row's
    /// own Pause.
    func testTurnOffIsTakenOnlyWhileTheRowOffersIt() async {
        XCTAssertEqual(WindowChannelRequest.parse(line(#"{"v":1,"id":"o1","op":"turnOff"}"#))?.op, .turnOff)
        XCTAssertTrue(WindowChannelPolicy.allows(request(.turnOff), row: row(.turnOff), holding: false))
        for action in [CaptureStatusAction.pause, .resume, .turnOn, .tryAgain, nil] {
            XCTAssertFalse(WindowChannelPolicy.allows(request(.turnOff), row: row(action), holding: false),
                           "\(String(describing: action))")
        }
        XCTAssertFalse(WindowChannelPolicy.allows(request(.pause), row: row(.turnOff), holding: false))

        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: FakeKeyStore(), runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: UserPauseController())
        // A turn-on pressed and not landed yet, as the menu shows it.
        supervisor.showForPreview(state: .idle, captureEnabled: false, receipt: nil, startedAt: nil, turningOn: true)
        XCTAssertEqual(supervisor.menuRow(setupFinished: true).action, .turnOff)
        let performed = Performed()
        supervisor.windowStatusAction = { performed.actions.append($0) }

        let paused = await supervisor.handleWindowRequest(request(.pause), setupFinished: true)
        XCTAssertFalse(paused, "the row offers Turn Off, not Pause")
        let off = await supervisor.handleWindowRequest(request(.turnOff), setupFinished: true)
        XCTAssertTrue(off)
        XCTAssertEqual(performed.actions, [.turnOff], "the menu's own Turn Off")
    }

    /// While the window deletes under its hold it renews the hold, so a
    /// long forget isn't cut off at 30 seconds. A renewal is taken only
    /// while the app holds, and carried out as the hold's own.
    func testRenewIsTakenOnlyWhileTheAppHolds() async throws {
        XCTAssertEqual(WindowChannelRequest.parse(line(#"{"v":1,"id":"n1","op":"renew"}"#))?.op, .renew)
        XCTAssertNil(WindowChannelRequest.parse(line(
            #"{"v":1,"id":"n2","op":"renew","until":"2026-10-12T15:40:00-07:00"}"#)), "only a pause has an end")
        XCTAssertTrue(WindowChannelPolicy.allows(request(.renew), row: row(nil), holding: true))
        for action in [CaptureStatusAction.pause, .resume, .turnOn, nil] {
            XCTAssertFalse(WindowChannelPolicy.allows(request(.renew), row: row(action), holding: false),
                           "\(String(describing: action))")
        }

        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: FakeKeyStore(), runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: UserPauseController())
        let early = await supervisor.handleWindowRequest(request(.renew), setupFinished: true)
        XCTAssertFalse(early, "nothing is held yet")
        let held = await supervisor.handleWindowRequest(request(.hold), setupFinished: true)
        XCTAssertTrue(held)
        let renewed = await supervisor.handleWindowRequest(request(.renew), setupFinished: true)
        XCTAssertTrue(renewed)
        XCTAssertTrue(supervisor.forgetHold.isHolding)
        let released = await supervisor.handleWindowRequest(request(.release), setupFinished: true)
        XCTAssertTrue(released)
        let late = await supervisor.handleWindowRequest(request(.renew), setupFinished: true)
        XCTAssertFalse(late, "a released hold isn't renewed")
    }

    // MARK: The pipe

    private var descriptors: [Int32] = []

    override func tearDown() async throws {
        for descriptor in descriptors { Darwin.close(descriptor) }
        descriptors = []
    }

    /// The server on two fresh pipes, and the window's two ends.
    private func wire(_ handle: @escaping @MainActor (WindowChannelRequest) async -> Bool)
        -> (server: WindowChannelServer, windowWrites: Int32, windowReads: Int32) {
        var toApp: [Int32] = [0, 0]
        var toWindow: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toApp), 0)
        XCTAssertEqual(pipe(&toWindow), 0)
        descriptors += toApp + toWindow
        let server = WindowChannelServer(input: FileHandle(fileDescriptor: toApp[0]),
                                         output: FileHandle(fileDescriptor: toWindow[1]), handle: handle)
        server.start()
        return (server, toApp[1], toWindow[0])
    }

    private func send(_ text: String, to descriptor: Int32) {
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Reads one line the app wrote, or nil after `seconds`.
    private func readLine(_ descriptor: Int32, within seconds: Double = 3) async -> [String: Any]? {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var buffer = Data()
        let deadline = Date().addingTimeInterval(seconds)
        var byte: UInt8 = 0
        while Date() < deadline {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any]
                }
                buffer.append(byte)
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return nil
    }

    func testEachRequestIsAnsweredAndMalformedOrUnknownLinesAreIgnored() async throws {
        var handled: [WindowChannelRequest.Op] = []
        let (server, windowWrites, windowReads) = wire { request in
            handled.append(request.op)
            return request.op == .pause
        }
        _ = server
        send("garbage", to: windowWrites)
        send(String(repeating: "x", count: 5_000), to: windowWrites)
        send(#"{"v":1,"id":"u1","op":"unlock"}"#, to: windowWrites)
        send(#"{"v":1,"id":"p1","op":"pause"}"#, to: windowWrites)
        let first = await readLine(windowReads)
        XCTAssertEqual(first?["id"] as? String, "p1", "nothing answers a line it ignored")
        XCTAssertEqual(first?["ok"] as? Bool, true)
        send(#"{"v":1,"id":"t1","op":"turnOn"}"#, to: windowWrites)
        let second = await readLine(windowReads)
        XCTAssertEqual(second?["id"] as? String, "t1")
        XCTAssertEqual(second?["ok"] as? Bool, false)
        XCTAssertEqual(handled, [.pause, .turnOn])
    }

    func testStatusIsPushedWhenItChangesInTheMenuBarsOwnWords() async throws {
        let (server, _, windowReads) = wire { _ in false }
        let paused = WindowStatusMessage(
            row: StatusRow(title: "Paused", detail: "Until 3:40 PM.", action: .resume, isTimedPause: true),
            status: .paused, setupComplete: true, forgetting: false,
            pausedSince: Date(timeIntervalSince1970: 1_791_841_200),
            pausedUntil: Date(timeIntervalSince1970: 1_791_844_800), lowPower: true)
        server.push(paused)
        server.push(paused)
        let pushed = await readLine(windowReads)
        XCTAssertEqual(pushed?["op"] as? String, "status")
        XCTAssertEqual(pushed?["v"] as? Int, 1)
        XCTAssertEqual(pushed?["state"] as? String, "paused")
        XCTAssertEqual(pushed?["title"] as? String, "Paused")
        XCTAssertEqual(pushed?["detail"] as? String, "Until 3:40 PM.")
        XCTAssertEqual(pushed?["action"] as? String, "resume")
        XCTAssertEqual(pushed?["lowPower"] as? Bool, true)
        XCTAssertNotNil(pushed?["pausedUntil"] as? String)
        let again = await readLine(windowReads, within: 0.4)
        XCTAssertNil(again, "the same status isn't pushed twice")
    }

    func testTheWindowsStateFollowsTheMenuBarsStatus() {
        func state(_ status: MenuBarStatus, setup: Bool = true, forgetting: Bool = false) -> WindowStatusMessage.State {
            WindowStatusMessage(row: StatusRow(title: "x", detail: nil, action: .pause), status: status,
                                setupComplete: setup, forgetting: forgetting, pausedSince: nil, pausedUntil: nil,
                                lowPower: false).state
        }
        XCTAssertEqual(state(.recording), .remembering)
        XCTAssertEqual(state(.unchanged), .remembering)
        XCTAssertEqual(state(.starting), .starting)
        XCTAssertEqual(state(.noMemory), .nothingSaved)
        XCTAssertEqual(state(.skipping(reason: "secure_input")), .skipping)
        XCTAssertEqual(state(.paused), .paused)
        XCTAssertEqual(state(.idle), .off)
        XCTAssertEqual(state(.needsPermission(.screenRecording)), .needsPermission)
        XCTAssertEqual(state(.stale(reason: "x")), .notSaving)
        XCTAssertEqual(state(.stopFailed(reason: "x")), .couldNotStop)
        XCTAssertEqual(state(.turnOnFailed(reason: "x")), .couldNotTurnOn)
        XCTAssertEqual(state(.recording, setup: false), .notSetUp)
        let holding = WindowStatusMessage(row: .forgetting, status: .paused, setupComplete: true, forgetting: true,
                                          pausedSince: nil, pausedUntil: nil, lowPower: false)
        XCTAssertEqual(holding.state, .forgetting)
        XCTAssertNil(holding.action)
        XCTAssertEqual(holding.title, "Forgetting\u{2026}")
    }

    // MARK: Distributed notifications can't change remembering

    /// Any process on the Mac can post a distributed notification; none may
    /// pause, resume or turn on remembering. The app's observers of them
    /// only show a pane or answer a read; none calls a change.
    func testNoDistributedNotificationObserverChangesRemembering() throws {
        let app = try String(contentsOf: Self.source("Sources/Hippocampus/HippocampusApp.swift"), encoding: .utf8)
        for observer in ["receivePreferencesRequest", "receiveSetupReadRequest"] {
            let body = try XCTUnwrap(Self.function(observer, in: app), observer)
            for change in ["setPaused(", "pause(until:", "turnOn(", "retryNow(", "applyCaptureEnabled(",
                           "performStatusAction(", "forgetHold"] {
                XCTAssertFalse(body.contains(change), "\(observer) calls \(change)")
            }
        }
        // The window's own distributed command only navigates.
        let tab = try String(contentsOf: Self.source("../recall-ui/Sources/RecallUIKit/Tab.swift"), encoding: .utf8)
        XCTAssertFalse(tab.contains("\"op\""), "the window's command carries no op")
        // Changes come only from the private pipe and the app's own menus.
        let server = try String(contentsOf: Self.source("Sources/HippocampusKit/WindowChannelServer.swift"),
                                encoding: .utf8)
        XCTAssertFalse(server.contains("DistributedNotificationCenter.default"),
                       "the pipe's server never listens anywhere else")
    }

    static func source(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path).standardizedFileURL
    }

    static func function(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let rest = source[start.lowerBound...]
        guard let open = rest.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < rest.endIndex {
            if rest[index] == "{" { depth += 1 }
            if rest[index] == "}" {
                depth -= 1
                if depth == 0 { return String(rest[open...index]) }
            }
            index = rest.index(after: index)
        }
        return nil
    }
}
